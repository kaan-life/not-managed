#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Usage:
#   bash init.sh              # Fresh install: Packer snapshot + multi-phase apply
#   bash init.sh --apply-only # Day-2 changes: skip Packer + phased apply, run one full apply
set -euo pipefail

APPLY_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --apply-only) APPLY_ONLY=true ;;
    *) echo "Usage: bash init.sh [--apply-only]"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

# ── Which cluster are you about to modify? ───────────────────────────────────
# TWO files decide that: backend.hcl says which STATE, secrets.auto.tfvars says which
# CREDENTIALS. Both are resolved from the SCRIPT's directory, never from $PWD, and they
# have to agree — resolving them by different rules is how you end up applying one
# cluster's configuration against another cluster's state.
#
# Until 2026-08-14 only backend.hcl was resolved this way. The comment below it already
# explained the hazard ("invoking this script by a relative path from a neighbouring
# checkout would otherwise pick up that checkout's backend.hcl") — and the file holding
# the CREDENTIALS was still read from $PWD, six times. So:
#
#   cd ~/prod-checkout && bash ~/test-checkout/variants/solo/init.sh
#
# took the state from the test checkout and the token from production, and the reverse
# took production's state with a test token — followed by four `terraform apply
# -auto-approve` with no diff shown to anybody. destroy.sh already did this correctly
# (GUARD_DIR); init.sh is the one that did not.
#
# Override deliberately with TFVARS=/path/to/secrets.auto.tfvars, the same shape as
# TF_BACKEND_CONFIG below. An override you typed is a decision; a $PWD you forgot is not.
TFVARS="${TFVARS:-${SCRIPT_DIR}/secrets.auto.tfvars}"
if [ ! -f "${TFVARS}" ]; then
  echo "Error: ${TFVARS} not found." >&2
  echo "       Copy secrets.auto.example.tfvars to secrets.auto.tfvars and fill it in," >&2
  echo "       or point elsewhere with TFVARS=/path/to/secrets.auto.tfvars." >&2
  exit 1
fi

# Extract hcloud_token
HCLOUD_TOKEN=$(sed -n 's/^[[:space:]]*hcloud_token[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}")

# Extract Terraform state backend credentials (exported as standard AWS env vars
# so the S3 backend picks them up — backend blocks cannot reference var.*)
TF_STATE_ACCESS_KEY=$(sed -n 's/^[[:space:]]*tf_state_access_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}")
TF_STATE_SECRET_KEY=$(sed -n 's/^[[:space:]]*tf_state_secret_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}")

# ── Remote state backend ─────────────────────────────────────────────────────
# providers.tf declares a PARTIAL backend: it names no bucket. Which state store to
# use is decided here, by a gitignored file, and this script must never guess. A guess
# is exactly how a fork ends up initialising against the original author's state.
#
# Resolved from the script's own directory, not $PWD: invoking this script by a relative
# path from a neighbouring checkout would otherwise pick up that checkout's backend.hcl.
TF_BACKEND_CONFIG="${TF_BACKEND_CONFIG:-${SCRIPT_DIR}/backend.hcl}"
if [ ! -f "${TF_BACKEND_CONFIG}" ]; then
  echo "Error: backend configuration not found at ${TF_BACKEND_CONFIG}" >&2
  echo "       providers.tf declares a partial backend, so terraform init has to be told" >&2
  echo "       which state store to use:" >&2
  echo "         cp ${SCRIPT_DIR}/backend.hcl.example ${SCRIPT_DIR}/backend.hcl" >&2
  echo "         \$EDITOR ${SCRIPT_DIR}/backend.hcl" >&2
  echo "       Point elsewhere with TF_BACKEND_CONFIG=/path/to/backend.hcl." >&2
  exit 1
fi

# ── GitOps companion repository (see docs/adr/0008) ──────────────────────────
# This repository builds the cluster; the companion GitOps repository describes what
# runs on it. The Tekton CRD bootstrap below needs one manifest from it.
#
# It is resolved, never assumed to be at a path: explicit override, then a conventional
# sibling checkout, then a shallow clone. The URL is derived from the SAME inputs ArgoCD
# is configured with, so the bootstrap and ArgoCD cannot end up pointed at different
# repositories.
#
# Overrides, all optional:
#   SKIP_TEKTON_BOOTSTRAP=1   skip entirely (a cluster without Tekton is a fine choice)
#   GITOPS_LOCAL_PATH=/path   use this checkout instead of cloning
#   GITOPS_REPO_URL=<url>     clone this instead of the derived URL
#   GITOPS_REF=<ref>          branch or tag to clone (default: main; pin it in a fork)
#   GITOPS_CRD_PATH=<path>    manifest to apply, relative to the GitOps repo root
#   GITOPS_CRD_TIMEOUT=<sec>  how long to wait for the CRDs (default: 600)
GITHUB_ORG_URL=$(sed -n 's/^[[:space:]]*github_org_url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}")
GITOPS_REPO_NAME=$(sed -n 's/^[[:space:]]*github_repo_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}")
GITOPS_REPO_URL="${GITOPS_REPO_URL:-${GITHUB_ORG_URL%/}/${GITOPS_REPO_NAME}.git}"
GITOPS_REF="${GITOPS_REF:-main}"
GITOPS_CRD_PATH="${GITOPS_CRD_PATH:-tekton/crds/crds-app.yaml}"
GITOPS_CRD_TIMEOUT="${GITOPS_CRD_TIMEOUT:-600}"

# Kubeconfig is written to a private temp file and cleaned up on any exit. The GitOps
# clone, if we make one, is cleaned up by the same trap — a second `trap ... EXIT` would
# silently replace this one rather than add to it.
KUBECONFIG_FILE=""
GITOPS_TMPDIR=""
cleanup() {
  [ -n "${KUBECONFIG_FILE}" ] && rm -f "${KUBECONFIG_FILE}"
  [ -n "${GITOPS_TMPDIR}" ] && rm -rf "${GITOPS_TMPDIR}"
  return 0
}
trap cleanup EXIT

# Sets the global GITOPS_DIR to a directory holding a GitOps checkout, cloning one if
# necessary. Deliberately assigns a global rather than printing a path for the caller to
# capture: `DIR="$(resolve_gitops_checkout)"` would run this in a SUBSHELL, so the
# GITOPS_TMPDIR it sets would never reach the EXIT trap in the parent — and every clone
# would leak a full checkout of a possibly-private repository into /tmp.
GITOPS_DIR=""
resolve_gitops_checkout() {
  local sibling
  if [ -n "${GITOPS_LOCAL_PATH:-}" ]; then
    [ -d "${GITOPS_LOCAL_PATH}" ] || { echo "Error: GITOPS_LOCAL_PATH=${GITOPS_LOCAL_PATH} is not a directory" >&2; return 1; }
    GITOPS_DIR="${GITOPS_LOCAL_PATH}"; return 0
  fi
  sibling="${SCRIPT_DIR}/../${GITOPS_REPO_NAME}"
  if [ -d "${sibling}/.git" ]; then
    GITOPS_DIR="${sibling}"; return 0
  fi
  [ -n "${GITHUB_ORG_URL}" ] && [ -n "${GITOPS_REPO_NAME}" ] || {
    echo "Error: cannot derive the GitOps repository URL — github_org_url and github_repo_name" >&2
    echo "       must be set in secrets.auto.tfvars, or set GITOPS_REPO_URL explicitly." >&2
    return 1
  }
  GITOPS_TMPDIR=$(mktemp -d)
  echo "==> Cloning GitOps repo ${GITOPS_REPO_URL} (ref ${GITOPS_REF})..."
  git clone --depth 1 --branch "${GITOPS_REF}" --quiet "${GITOPS_REPO_URL}" "${GITOPS_TMPDIR}" || {
    echo "Error: could not clone ${GITOPS_REPO_URL} at ref ${GITOPS_REF}." >&2
    echo "       If it is private, ensure git has credentials. To skip Tekton entirely:" >&2
    echo "         SKIP_TEKTON_BOOTSTRAP=1 bash init.sh" >&2
    return 1
  }
  GITOPS_DIR="${GITOPS_TMPDIR}"
}

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Error: hcloud_token not found in secrets.auto.tfvars"
  exit 1
fi

if [ -z "$TF_STATE_ACCESS_KEY" ] || [ -z "$TF_STATE_SECRET_KEY" ]; then
  echo "Error: tf_state_access_key or tf_state_secret_key not found in secrets.auto.tfvars"
  exit 1
fi

export HCLOUD_TOKEN
export AWS_ACCESS_KEY_ID="$TF_STATE_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$TF_STATE_SECRET_KEY"

# Init terraform (required in both modes to configure the backend).
# -input=false so a missing backend argument fails loudly instead of opening a prompt
# that nothing is watching.
terraform init -input=false -backend-config="${TF_BACKEND_CONFIG}"

if [ "$APPLY_ONLY" = true ]; then
  # ─────────────────────────────────────────────────────────────────────────
  # Day-2 mode: cluster already exists, skip Packer and phased apply.
  # ─────────────────────────────────────────────────────────────────────────
  echo "==> Day-2 apply: skipping Packer build and phased apply."

  # The module names this file after the cluster, not after "k3s" — see the note in
  # github.tf. Hardcoding "k3s_kubeconfig.yaml" worked only because THIS cluster happens
  # to be called k3s; a fork with any other cluster_name got a file it never looked at.
  KUBECONFIG_NAME="$(sed -n 's/^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}" | head -1)_kubeconfig.yaml"
  if [ -f "${KUBECONFIG_NAME}" ]; then
    echo "==> Using existing ${KUBECONFIG_NAME}"
    export KUBECONFIG="${KUBECONFIG_NAME}"
  else
    echo "==> Fetching kubeconfig from terraform output..."
    KUBECONFIG_FILE=$(mktemp --suffix=.yaml)
    chmod 600 "${KUBECONFIG_FILE}"
    terraform output -raw kubeconfig > "${KUBECONFIG_FILE}"
    export KUBECONFIG="${KUBECONFIG_FILE}"
  fi

  echo "==> Verifying cluster connectivity..."
  kubectl get nodes

  echo "==> Applying all resources..."
  terraform apply -auto-approve
else
  # ─────────────────────────────────────────────────────────────────────────
  # Fresh install: Packer snapshot + multi-phase apply.
  # ─────────────────────────────────────────────────────────────────────────

  # Build MicroOS snapshot if needed
  SNAPSHOT_COUNT=$(hcloud image list --selector 'microos-snapshot=yes' --output json | grep -c '"id"' || true)
  if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
    packer init packer/hcloud-microos-snapshots.pkr.hcl
    packer build packer/hcloud-microos-snapshots.pkr.hcl
  fi

  # ───────────────────────────────────────────────────────────────────────────
  # Phase 1: Provision the cluster and Helm releases only.
  # kubernetes_manifest resources are excluded because the Kubernetes API server
  # doesn't exist yet and the provider cannot construct a REST client at plan time.
  # ───────────────────────────────────────────────────────────────────────────
  echo "==> Phase 1: Provisioning cluster infrastructure and Helm releases..."
  terraform apply \
    -target=module.kube-hetzner \
    -target=helm_release.argocd \
    -target=time_sleep.wait_for_argocd \
    -auto-approve

  # Export kubeconfig to a private temp file (not world-readable /tmp/*)
  echo "==> Exporting kubeconfig..."
  KUBECONFIG_FILE=$(mktemp --suffix=.yaml)
  chmod 600 "${KUBECONFIG_FILE}"
  terraform output -raw kubeconfig > "${KUBECONFIG_FILE}"
  export KUBECONFIG="${KUBECONFIG_FILE}"

  # Verify cluster connectivity
  echo "==> Verifying cluster connectivity..."
  kubectl get nodes

  # ───────────────────────────────────────────────────────────────────────────
  # Phase 2a: Everything EXCEPT kubernetes_manifest resources.
  # cert-manager is installed by kube-hetzner (enable_cert_manager = true),
  # but we apply namespaces/secrets here before waiting for CRDs.
  # ───────────────────────────────────────────────────────────────────────────
  echo "==> Phase 2a: Namespaces, secrets..."
  terraform apply \
    -target=kubernetes_namespace_v1.app_namespaces \
    -target=terraform_data.github_secrets \
    -auto-approve

  # Wait for cert-manager CRDs to be fully registered before planning manifests
  echo "==> Waiting for cert-manager CRDs..."
  kubectl wait --for=condition=established --timeout=120s crd/clusterissuers.cert-manager.io

  # ───────────────────────────────────────────────────────────────────────────
  # Phase 2c: Bootstrap Tekton CRDs before the root ApplicationSet is deployed.
  # The manifest below is an ArgoCD Application (sync-wave -1) that downloads Tekton
  # Pipelines and Triggers from upstream release YAML. We apply it explicitly here so
  # that when Phase 2b deploys the root ApplicationSet and ArgoCD immediately syncs the
  # Tekton application, the CRDs already exist — otherwise first boot reports a
  # "CRD not found" SyncError that resolves itself only on a later retry.
  # The manifest comes from the companion GitOps repository, resolved rather than
  # assumed to sit at a sibling path — see docs/adr/0008 and the overrides at the top.
  # ───────────────────────────────────────────────────────────────────────────
  if [ "${SKIP_TEKTON_BOOTSTRAP:-0}" = "1" ]; then
    echo "==> Phase 2c: SKIPPED (SKIP_TEKTON_BOOTSTRAP=1). Tekton CRDs will not be"
    echo "    bootstrapped; any Application depending on them will report SyncError"
    echo "    until they exist by some other means."
  else
    echo "==> Phase 2c: Bootstrap Tekton CRDs from the GitOps repo..."
    resolve_gitops_checkout || exit 1
    GITOPS_MANIFEST="${GITOPS_DIR}/${GITOPS_CRD_PATH}"
    if [ ! -f "${GITOPS_MANIFEST}" ]; then
      echo "Error: ${GITOPS_CRD_PATH} not found in the GitOps checkout at ${GITOPS_DIR}." >&2
      echo "       The GitOps repository must provide this manifest (an ArgoCD Application" >&2
      echo "       that installs the Tekton Pipelines and Triggers CRDs). Override the path" >&2
      echo "       with GITOPS_CRD_PATH, or skip with SKIP_TEKTON_BOOTSTRAP=1." >&2
      exit 1
    fi
    kubectl apply -f "${GITOPS_MANIFEST}"

    # Bounded wait. This loop used to be `until ...; do sleep 10; done` with no exit
    # condition: if the Application never synced, init.sh waited forever while holding
    # the S3 state lock, and the only symptom was silence.
    echo "==> Waiting up to ${GITOPS_CRD_TIMEOUT}s for Tekton CRDs to install (~3-5 min typical)..."
    _deadline=$((SECONDS + GITOPS_CRD_TIMEOUT))
    until kubectl get crd pipelines.tekton.dev tasks.tekton.dev \
        eventlisteners.triggers.tekton.dev &>/dev/null; do
      if [ "${SECONDS}" -ge "${_deadline}" ]; then
        echo "Error: Tekton CRDs did not appear within ${GITOPS_CRD_TIMEOUT}s." >&2
        echo "       Waiting for: pipelines.tekton.dev, tasks.tekton.dev," >&2
        echo "                    eventlisteners.triggers.tekton.dev" >&2
        echo "       The Application applied above pulls them from upstream release YAML;" >&2
        echo "       check it with:  kubectl -n argocd get applications" >&2
        echo "       Raise the budget with GITOPS_CRD_TIMEOUT=<seconds> if the cluster is slow." >&2
        exit 1
      fi
      sleep 10
    done
    kubectl wait --for=condition=established --timeout=300s \
      crd/pipelines.tekton.dev \
      crd/tasks.tekton.dev \
      crd/eventlisteners.triggers.tekton.dev
    echo "==> Tekton CRDs ready."
  fi

  # ───────────────────────────────────────────────────────────────────────────
  # Phase 2b: Apply remaining resources (kubernetes_manifest, etc.).
  # CRDs are now registered so the provider can plan ClusterIssuer safely.
  # ───────────────────────────────────────────────────────────────────────────
  echo "==> Phase 2b: Kubernetes manifests and remaining resources..."
  terraform apply -auto-approve
fi
