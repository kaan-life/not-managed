# Native `terraform test` regressions on top of firewall_validations.tftest.hcl's nine
# runs. Same design for the same reasons: every run is negative (`expect_failures`), and
# all five declared providers are mocked — see that file's header for why both of those
# are measured requirements rather than choices.
#
# This file is the solo variant's, with one run added: `ha` hardcodes
# nat_router.enable_redundancy, so the nat_router_hcloud_token validation is a real gate
# here and gets its own regression run. ADR-0007 keeps the variants as independent copies
# rather than a shared module, so the duplication is the point — and
# tools/gen-variant-delta.sh plus the drift-guard job are what stop the two copies from
# quietly diverging.
#
# WHY THERE IS STILL NO POSITIVE PLAN RUN, MEASURED RATHER THAN ASSUMED (2026-08-16). A
# positive `command = plan` run with this exact mock set was tried in a throwaway copy of
# this variant, immediately after the nine negative runs passed there. The plan fails
# inside upstream kube-hetzner before reaching any assert: the mocked `hcloud_images`
# data sources return empty snapshot lists, `os_snapshot_id` becomes "", and the hcloud
# provider rejects `image = ""` on every hcloud_server. Enriching the mock does not fix
# it — the lookup wants full `images` object lists, and past it the network data sources
# feed cidrhost() — so a passing positive plan would assert the mock, not the
# configuration. The suite therefore stays in expect_failures form.
#
# WHAT THESE RUNS PIN THAT THE ORIGINAL NINE DO NOT:
#
#   ssh + 203.0.113.0/23   the nine pin the /23-wider-than-/24 mistake against the kube
#                          API allowlist only. ssh carries the same validation, and a
#                          regression that loosened only the ssh copy would have passed
#                          all nine.
#   2001:db8::/47          the IPv6 twin of the /23 case. The nine cover ::/0, so an
#                          IPv6 check that only catches the default route would still
#                          pass them; /47 is one step wider than the /48 boundary the
#                          error message states.
#   a bare IP, no "/"      the only coverage of the middle validation (every entry must
#                          parse as address/prefix). Pasting a bare IP is the realistic
#                          way to get this wrong.
#   an empty NAT token     the cross-variable class `terraform validate` cannot see:
#                          main.tf hardcodes enable_redundancy, the keepalived pair
#                          cannot fail over without an API token, and only this
#                          validation stands between an empty value and a NAT router
#                          that silently cannot move the floating IP.

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

  # Valid by default; each run below overrides exactly one variable.
  firewall_kube_api_source = ["100.64.0.0/10"]
  firewall_ssh_source      = ["100.64.0.0/10"]
}

# ── ssh: the wide-but-not-total public prefix ────────────────────────────────
# The mirror of kube_api_rejects_public_prefix_wider_than_24: same boundary, same
# realistic mistake (an ISP block pasted instead of an address), other variable.

run "ssh_rejects_public_prefix_wider_than_24" {
  command = plan
  variables { firewall_ssh_source = ["203.0.113.0/23"] }
  expect_failures = [var.firewall_ssh_source]
}

# ── IPv6: wide but not the default route ─────────────────────────────────────
# Uses the IPv6 documentation prefix (2001:db8::/32), one bit wider than the stated /48
# boundary. Both variables, because the ssh gap above is exactly how a one-sided
# regression slips through.

run "kube_api_rejects_ipv6_public_prefix_wider_than_48" {
  command = plan
  variables { firewall_kube_api_source = ["2001:db8::/47"] }
  expect_failures = [var.firewall_kube_api_source]
}

run "ssh_rejects_ipv6_public_prefix_wider_than_48" {
  command = plan
  variables { firewall_ssh_source = ["2001:db8::/47"] }
  expect_failures = [var.firewall_ssh_source]
}

# ── Not a CIDR at all ────────────────────────────────────────────────────────
# A bare IP has no prefix, so it must fail the every-entry-is-a-CIDR validation. This
# relies on && short-circuiting in the allowlist validation's prefix arithmetic, which
# holds from Terraform 1.12 — the same 1.12 floor the CI matrix already exercises, and
# the reason required_version says "~> 1.12" in the first place.

run "kube_api_rejects_entry_without_prefix" {
  command = plan
  variables { firewall_kube_api_source = ["100.64.0.1"] }
  expect_failures = [var.firewall_kube_api_source]
}

# ── The NAT router token, without which there is no failover ─────────────────
# ha-only. main.tf hardcodes nat_router.enable_redundancy = true, and the keepalived
# pair moves the floating IP by calling the Hetzner API — an empty token builds a NAT
# router that cannot fail over. `terraform validate` alone never sees this coupling
# (the M3 lesson); the variable validation catches it at plan time, and this run pins
# that validation.

run "redundancy_rejects_empty_nat_router_token" {
  command = plan
  variables { nat_router_hcloud_token = "" }
  expect_failures = [var.nat_router_hcloud_token]
}
