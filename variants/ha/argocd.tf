# SPDX-License-Identifier: Apache-2.0

locals {
  # Single source of truth for the ArgoCD hostname. Used by the Helm values below
  # (global.domain, configs.cm.url, server.ingress.hostname) AND by the GitHub
  # webhook URL in github_repository_webhook.argocd_gitops. Keeping these in one
  # place matters: if the ingress hostname and the webhook URL ever diverge, GitHub
  # deliveries 404 and deploys silently revert to 180s polling with no error.
  #
  # The value itself is an input with no default (see variable "argocd_domain"): it is
  # a DNS name someone owns, and inheriting one from an upstream repository points a
  # fork's webhook at a host it does not control.
  argocd_domain = var.argocd_domain
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "8.2.5"

  namespace        = "argocd"
  create_namespace = true

  values = [<<-EOT
global:
  domain: ${local.argocd_domain}

configs:
  params:
    server.insecure: "true"

  cm:
    url: https://${local.argocd_domain}
    kustomize.buildOptions: "--enable-helm"
    accounts.admin: disabled
    dex.config: |
      connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: ${var.github_oauth_client_id}
          clientSecret: $dex.github.clientSecret
          orgs:
          - name: ${trimsuffix(trimprefix(var.github_org_url, "https://github.com/"), "/")}
            teams:
            - ${var.argocd_admin_team}

  rbac:
    policy.default: role:readonly
    policy.csv: |
      g, ${trimsuffix(trimprefix(var.github_org_url, "https://github.com/"), "/")}:${var.argocd_admin_team}, role:admin

# Metrics Service for Prometheus. Creates
# argocd-application-controller-metrics.argocd.svc:8082 (port name http-metrics;
# verified against `helm template` for this chart version). The controller serves the
# metrics endpoint regardless — this only adds the Service, so it costs no extra memory.
# argocd_app_info, i.e. sync and health state per application, comes from here.
# Resource requests so the scheduler accounts for ArgoCD (was all best-effort, ~700Mi
# total across components) and balances it across the platform nodes (C2, 2026-06-13).
controller:
  metrics:
    enabled: true
  # Memory raised on 2026-06-24 from 256Mi/512Mi to 512Mi request / 1Gi limit. Splitting
  # one ApplicationSet into per-application ones took the Application count from ~6 to
  # ~16, and the simultaneous initial sync — each one rendering kustomize over a remote
  # base — OOMKilled the controller at 512Mi (exit 137), leaving sync operations wedged.
  # Controller memory scales with how many Applications sync at once, not cluster size.
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 1Gi

server:
  ingress:
    enabled: true
    ingressClassName: traefik
    hostname: ${local.argocd_domain}
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
      traefik.ingress.kubernetes.io/router.tls: "true"
      cert-manager.io/cluster-issuer: "letsencrypt"
    tls: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      memory: 128Mi

repoServer:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi

applicationSet:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi

notifications:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi

dex:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi

redis:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 128Mi
EOT
  ]

  depends_on = [module.kube-hetzner]
}

resource "terraform_data" "argocd_root_appset" {
  triggers_replace = {
    namespaces       = join(",", concat(var.utility_namespaces, var.app_namespaces))
    github_org       = var.github_org_url
    github_repo_name = var.github_repo_name

    # The provisioner below runs a script. Without the script's own content in the
    # trigger set, editing that script changes nothing Terraform can see, so the
    # provisioner never re-runs and the edit is silently never deployed. github.tf
    # already hashed the PEM this way; it did not hash the script that consumes it.
    script_hash = filesha256("${path.module}/scripts/apply-argocd-appset.py")
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG       = "${abspath(path.root)}/k3s_kubeconfig.yaml"
      NAMESPACES       = join(",", concat(var.utility_namespaces, var.app_namespaces))
      GITHUB_ORG       = var.github_org_url
      GITHUB_REPO_NAME = var.github_repo_name
    }
    command = "python3 ${abspath(path.root)}/scripts/apply-argocd-appset.py"
  }

  depends_on = [time_sleep.wait_for_argocd]
}

resource "time_sleep" "wait_for_argocd" {
  depends_on      = [helm_release.argocd]
  create_duration = "90s"
}

data "kubernetes_secret_v1" "argocd_admin_password" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = helm_release.argocd.namespace
  }
}

# Patches argocd-secret with the GitHub webhook shared secret, so ArgoCD validates
# the HMAC signature on incoming push webhooks from the GitOps repository.
#
# WHY: the CI pipeline ends by pushing a new image tag to the GitOps repository.
# Nothing then told ArgoCD, so it only noticed on its next poll
# (configs.cm has no timeout.reconciliation override -> 180s default). Measured
# commit->deployed lag across 10 ArgoCD history entries (2026-07-28..30):
# min 49s / p50 165s / mean 159.1s / max 250s -- i.e. roughly 40% of the total
# 411s commit-to-testable time was ArgoCD waiting to find out.
#
# This changes only WHEN ArgoCD is notified, never WHAT it does: same manifests,
# same automated prune/selfHeal, same upstream test gates. No quality trade-off.
#
# The GitHub half of this is github_repository_webhook.argocd_gitops below; the two
# must carry the same secret or ArgoCD rejects every delivery.
#
# Verify with: gh api repos/<org>/<gitops-repo>/hooks/<id>/deliveries
# ArgoCD v3 HMAC-verifies the ping event too, so a 200 on the ping delivery proves
# the secret matches. A mismatch returns 400 ("Webhook processing failed: HMAC
# verification failed") -- not 401/403, which ArgoCD's webhook handler never emits.
resource "terraform_data" "argocd_webhook_secret" {
  triggers_replace = {
    webhook_secret_hash = sha256(var.argocd_webhook_secret)
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG     = "${abspath(path.root)}/k3s_kubeconfig.yaml"
      WEBHOOK_SECRET = var.argocd_webhook_secret
    }
    command = <<-EOT
      python3 -c "
import json, os, subprocess, sys
secret = os.environ['WEBHOOK_SECRET']
patch = json.dumps({'stringData': {'webhook.github.secret': secret}})
r = subprocess.run(
  ['kubectl', 'patch', 'secret', 'argocd-secret', '-n', 'argocd', '--type=merge', '-p', patch],
  capture_output=True)
if r.returncode != 0:
  print(r.stderr.decode(), file=sys.stderr)
  sys.exit(1)
print('Patched argocd-secret with GitHub webhook secret')
"
    EOT
  }

  depends_on = [helm_release.argocd]

  # Re-patch whenever the ArgoCD release changes. Helm's 3-way merge normally
  # preserves keys it does not manage, but a chart bump that starts templating
  # webhook.github.secret (or a --force upgrade) would silently drop it -- and the
  # failure mode is invisible: webhook deliveries start returning 400 and deploys
  # quietly revert to 180s polling. Re-running the patch is idempotent and cheap.
  lifecycle {
    replace_triggered_by = [helm_release.argocd]
  }
}

# The GitHub half of the ArgoCD notification path: a push webhook on the gitops repo
# pointing at ArgoCD's /api/webhook. Declared here (rather than as a one-off gh api
# call) so `terraform plan` detects drift -- if the hook is deleted or edited in the
# GitHub UI, deploys silently fall back to 180s polling with no error anywhere, which
# is exactly the failure this resource is meant to make visible.
#
# ADOPTING THE EXISTING HOOK: one was created manually on 2026-07-30 before this was
# codified. Import it once, instead of letting Terraform create a duplicate:
#   terraform import github_repository_webhook.argocd_gitops <gitops-repo>/<hook-id>
# List hook ids with: gh api repos/<org>/<gitops-repo>/hooks --jq '.[].id'
#
# Expect ONE secret diff on the first plan after import: the GitHub API returns a
# populated secret as "********", so Terraform sees state != config and re-sets the
# real value. That update is idempotent and harmless. If the same diff reappears on
# every subsequent plan, the provider is not persisting the secret -- add
# `lifecycle { ignore_changes = [configuration[0].secret] }`, accepting that secret
# rotation then needs a manual taint.
resource "github_repository_webhook" "argocd_gitops" {
  repository = var.github_repo_name
  active     = true

  # Only `push` -- ArgoCD's webhook handler parses push (and ping) and ignores the
  # rest, so subscribing to more just burns deliveries.
  events = ["push"]

  configuration {
    url          = "https://${local.argocd_domain}/api/webhook"
    content_type = "json"
    insecure_ssl = false

    # WARNING: this value IS stored in Terraform state, in cleartext.
    #
    # It is a real resource attribute, so Terraform must persist it to compare against
    # next time — unlike the terraform_data patches elsewhere in this file, which keep
    # only a SHA-256 hash and pass the value through the environment. `sensitive = true`
    # on the variable redacts it from CLI output; it does nothing to the state file.
    #
    # Consequences, and they are the reason the state bucket is the crown jewel here:
    #   - anyone who can read the state bucket can forge a valid push webhook to ArgoCD;
    #   - rotating this variable is not enough on its own — every historical state
    #     version in the bucket still holds the old value until the 90-day noncurrent
    #     retention (set 2026-08-05) expires.
    #
    # Not fixable while the webhook is managed by Terraform: the provider has nowhere
    # else to put it. The mitigation is bucket-side — versioning, SSE and tight
    # credentials — not code-side.
    secret = var.argocd_webhook_secret
  }
}

# Patches argocd-secret with the Dex GitHub OAuth client secret at apply time.
# Only a SHA256 hash of the secret is stored in Terraform state; the value itself is
# passed via environment variable and never written to the state file.
#
# This claim is true for THIS resource, because terraform_data persists only what is in
# triggers_replace. It is NOT a property of the configuration as a whole: the webhook
# secret a few lines above is a genuine resource attribute and does sit in state in
# cleartext. Read the two together — the pattern here is the exception, not the rule.
resource "terraform_data" "argocd_dex_secret" {
  triggers_replace = {
    client_secret_hash = sha256(var.github_oauth_client_secret)
    client_id          = var.github_oauth_client_id
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG          = "${abspath(path.root)}/k3s_kubeconfig.yaml"
      OAUTH_CLIENT_SECRET = var.github_oauth_client_secret
    }
    command = <<-EOT
      python3 -c "
import json, os, subprocess, sys
secret = os.environ['OAUTH_CLIENT_SECRET']
patch = json.dumps({'stringData': {'dex.github.clientSecret': secret}})
r = subprocess.run(
  ['kubectl', 'patch', 'secret', 'argocd-secret', '-n', 'argocd', '--type=merge', '-p', patch],
  capture_output=True)
if r.returncode != 0:
  print(r.stderr.decode(), file=sys.stderr)
  sys.exit(1)
print('Patched argocd-secret with Dex client secret')
"
    EOT
  }

  depends_on = [helm_release.argocd]

  # Same rationale as argocd_webhook_secret above, and a worse failure mode here:
  # configs.cm sets accounts.admin: disabled, so Dex SSO is the ONLY login path.
  # If a chart bump or --force upgrade drops dex.github.clientSecret, nobody can
  # log in to the UI at all. Re-patch on every release change.
  lifecycle {
    replace_triggered_by = [helm_release.argocd]
  }
}
