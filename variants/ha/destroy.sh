#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Tear the cluster down, in the order the providers require.
#
# ONLY run this against a throwaway project.
#
# Two things were wrong with the previous version and are fixed here:
#   1. It read the API token and the state credentials from ./secrets.auto.tfvars —
#      relative to the *current working directory*. Run from the wrong directory, it
#      destroyed the wrong cluster. Credentials now load from the directory this script
#      lives in, and the target project must be named explicitly and proven (see
#      scripts/hcloud-guard.sh).
#   2. It ran four `terraform destroy -auto-approve` calls with no confirmation of any
#      kind. There is now a destroy-plan preview and a typed confirmation naming the
#      project and the resource count.
#
#   ./destroy.sh --project test            # dry run: shows what would be destroyed
#   ./destroy.sh --project test --apply    # actually destroys, after typed confirmation
#
# Note: main.tf sets enable_delete_protection on floating IPs, load balancers and
# volumes, so a destroy fails on those until you run:
#   ./remove-protection.sh --project test --apply

set -euo pipefail
GUARD_DESTRUCTIVE=1   # this script destroys or weakens resources
# shellcheck source=scripts/hcloud-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/hcloud-guard.sh"

guard_parse_args "$@"
guard_load_token
[ "$GUARD_REGISTER" -eq 1 ] && guard_register
[ "$GUARD_PROTECT" -eq 1 ] && guard_protect
guard_assert_project

# Which state store to destroy from. providers.tf declares a partial backend, so this
# is not optional and must not be guessed — see the comment in providers.tf. Resolved
# from the script's own directory, like the credentials below.
TF_BACKEND_CONFIG="${TF_BACKEND_CONFIG:-${GUARD_DIR}/backend.hcl}"
[ -f "${TF_BACKEND_CONFIG}" ] \
  || guard_die "backend configuration not found at ${TF_BACKEND_CONFIG} (cp backend.hcl.example backend.hcl, or set TF_BACKEND_CONFIG)"

# State backend credentials, from the script's own directory — not from $PWD.
# (Backend blocks cannot reference var.*, so the S3 backend reads these env vars.)
TFVARS="${GUARD_DIR}/secrets.auto.tfvars"
AWS_ACCESS_KEY_ID=$(sed -n 's/^[[:space:]]*tf_state_access_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TFVARS")
AWS_SECRET_ACCESS_KEY=$(sed -n 's/^[[:space:]]*tf_state_secret_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TFVARS")
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] \
  || guard_die "tf_state_access_key / tf_state_secret_key not found in ${TFVARS}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

cd "$GUARD_DIR"
terraform init -input=false -backend-config="${TF_BACKEND_CONFIG}"

echo
echo "==> Destroy preview"
DESTROY_COUNT=$(terraform plan -destroy -no-color -input=false 2>/dev/null \
  | sed -n 's/^Plan: .* to add, .* to change, \([0-9][0-9]*\) to destroy\./\1/p' | tail -1)
DESTROY_COUNT=${DESTROY_COUNT:-unknown}
echo "Terraform reports ${DESTROY_COUNT} resource(s) to destroy in project '${GUARD_PROJECT}'."

if guard_is_dry_run; then
  guard_dry_run_notice
  exit 0
fi

guard_confirm "destroy" "$DESTROY_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Kubernetes manifests and remaining non-cluster resources first.
# The cluster must still be alive for the Kubernetes provider to connect.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Phase 1: Destroying Kubernetes manifests and remaining resources..."
terraform destroy -target=kubernetes_manifest.argocd_app -auto-approve 2>/dev/null || true

# Destroy all non-cluster resources in a single call (handles for_each instances).
# Builds -target= flags from state list, excluding cluster/helm resources and data sources.
NON_CLUSTER_TARGETS=$(terraform state list \
  | grep -v '^module\.kube-hetzner' \
  | grep -v '^helm_release\.argocd$' \
  | grep -v '^time_sleep\.wait_for_argocd$' \
  | grep -v '^data\.' \
  | sed 's/^/-target=/' \
  | tr '\n' ' ')

if [ -n "${NON_CLUSTER_TARGETS}" ]; then
  # shellcheck disable=SC2086  # intentional word-splitting for multiple -target= flags
  terraform destroy ${NON_CLUSTER_TARGETS} -auto-approve
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Helm releases, then the cluster infrastructure.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Phase 2: Destroying Helm releases..."
terraform destroy -target=time_sleep.wait_for_argocd -target=helm_release.argocd -auto-approve

echo "==> Phase 3: Destroying cluster infrastructure..."
terraform destroy -target=module.kube-hetzner -auto-approve

echo "==> All resources destroyed in project '${GUARD_PROJECT}'."
