# Native `terraform test` for the firewall allowlists.
#
# This file is the solo variant's, with one line added: `ha` requires
# nat_router_hcloud_token as well, because enable_redundancy gives the NAT routers their
# own token. ADR-0007 keeps the variants as independent copies rather than a shared module,
# so the duplication is the point — and tools/gen-variant-delta.sh plus the drift-guard job
# are what stop the two copies from quietly diverging.
#
# WHY EVERY RUN IS A NEGATIVE ONE. These runs assert that bad input is REJECTED. That is
# not laziness about the happy path: a positive run would have to complete a `plan`, and a
# plan of this configuration reaches Hetzner, GitHub and a live Kubernetes API. CI for a
# reference architecture must pass with no credentials of any kind — a test suite that
# needs secrets is one nobody who forks this can run.
#
# WHY mock_provider, MEASURED RATHER THAN ASSUMED. The first version of this file assumed
# variable validation short-circuits before providers are configured. It does not:
# `terraform test` builds the whole graph, so `provider "github"` evaluated
# `file(var.github_app_private_key_path)` and the run failed on a missing file instead of
# on the validation under test — an expected-failure test that fails for an unrelated
# reason is a test that proves nothing. Mocking every declared provider removes that
# entire class of interference, and it is also what keeps the suite offline.
#
# THE FIVE INPUTS ARE NOT ARBITRARY. Both firewall variables are an ALLOWLIST rather than a
# blocklist, and these are the ways a blocklist gets walked around:
#
#   0.0.0.0/1 + 128.0.0.0/1   two halves that together are 0.0.0.0/0 — the case that
#                             decided the allowlist design, since neither half IS 0.0.0.0/0
#   ::/0                      the same hole in IPv6, which a v4-only check misses while
#                             the nodes still hold public IPv6 addresses
#   []                        an empty list applies no restriction at all
#   0.0.0.0/0                 the obvious one, kept by name so a regression in the case
#                             everybody thinks of is caught here rather than in review
#   203.0.113.0/23            one step wider than the /24 boundary the error message
#                             states — the realistic mistake of pasting an ISP block
#
# The `variables` block exists only so each run reaches validation: every required variable
# needs *a* value, or the run fails for the wrong reason and `expect_failures` would pass
# for something that has nothing to do with firewalls. No value here is used for anything.

mock_provider "hcloud" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "github" {}
mock_provider "time" {}

variables {
  hcloud_token = "not-a-token"
  # 64 characters, because ha validates the length at plan time. Deliberately not
  # hex: a random-looking 64-char hex string is exactly what a secret scanner should
  # flag, and a fixture that trips gitleaks on every run is a fixture nobody keeps.
  nat_router_hcloud_token     = "not-a-real-token-this-is-a-terraform-test-placeholder-value-0000"
  github_app_id               = "0"
  github_app_installation_id  = "0"
  github_app_private_key_path = "secrets/your-github-app.pem.example"
  github_org_url              = "https://github.com/example-org"
  github_repo_name            = "example-gitops"
  letsencrypt_email           = "nobody@example.com"
  acme_server                 = "https://acme-staging-v02.api.letsencrypt.org/directory"
  argocd_domain               = "gitops.example.com"
  argocd_admin_team           = "example-admins"
  ssh_public_key_path         = "tests/example-ssh-key.pub"
  utility_namespaces          = ["tooling"]
  app_namespaces              = ["prod"]
  etcd_s3_endpoint            = "example.invalid"
  etcd_s3_access_key          = "unused"
  etcd_s3_secret_key          = "unused"
  etcd_s3_bucket              = "unused"
  etcd_s3_region              = "unused"
  tailscale_auth_key          = "unused"
  github_oauth_client_id      = "unused"
  github_oauth_client_secret  = "unused"
  argocd_webhook_secret       = "unused"
  tf_state_access_key         = "unused"
  tf_state_secret_key         = "unused"

  bootstrap_phase = true

  # Valid by default; each run below overrides exactly one of the two.
  firewall_kube_api_source = ["100.64.0.0/10"]
  firewall_ssh_source      = ["100.64.0.0/10"]
}

# ── The bisected default route ───────────────────────────────────────────────
# This is the case that decided the allowlist design. Neither half is 0.0.0.0/0, both are
# /1, and together they are the entire internet.

run "kube_api_rejects_bisected_default_route" {
  command = plan
  variables { firewall_kube_api_source = ["0.0.0.0/1", "128.0.0.0/1"] }
  expect_failures = [var.firewall_kube_api_source]
}

run "ssh_rejects_bisected_default_route" {
  command = plan
  variables { firewall_ssh_source = ["0.0.0.0/1", "128.0.0.0/1"] }
  expect_failures = [var.firewall_ssh_source]
}

# ── IPv6 ─────────────────────────────────────────────────────────────────────
# A check written only against IPv4 prefixes lets ::/0 through, and the node has a public
# IPv6 address.

run "kube_api_rejects_ipv6_default_route" {
  command = plan
  variables { firewall_kube_api_source = ["::/0"] }
  expect_failures = [var.firewall_kube_api_source]
}

run "ssh_rejects_ipv6_default_route" {
  command = plan
  variables { firewall_ssh_source = ["::/0"] }
  expect_failures = [var.firewall_ssh_source]
}

# ── Empty ────────────────────────────────────────────────────────────────────
# An empty list is not "deny everything"; it is "apply no restriction".

run "kube_api_rejects_empty_list" {
  command = plan
  variables { firewall_kube_api_source = [] }
  expect_failures = [var.firewall_kube_api_source]
}

run "ssh_rejects_empty_list" {
  command = plan
  variables { firewall_ssh_source = [] }
  expect_failures = [var.firewall_ssh_source]
}

# ── The obvious one ──────────────────────────────────────────────────────────
# Kept by name so that a regression in the case everyone thinks of is caught here rather
# than in review.

run "kube_api_rejects_default_route" {
  command = plan
  variables { firewall_kube_api_source = ["0.0.0.0/0"] }
  expect_failures = [var.firewall_kube_api_source]
}

run "ssh_rejects_default_route" {
  command = plan
  variables { firewall_ssh_source = ["0.0.0.0/0"] }
  expect_failures = [var.firewall_ssh_source]
}

# ── A wide-but-not-total public prefix ───────────────────────────────────────
# /24 is the boundary the error message states. /23 is one step over it, and it is the
# realistic mistake: somebody pastes their ISP's block instead of their own address.

run "kube_api_rejects_public_prefix_wider_than_24" {
  command = plan
  variables { firewall_kube_api_source = ["203.0.113.0/23"] }
  expect_failures = [var.firewall_kube_api_source]
}
