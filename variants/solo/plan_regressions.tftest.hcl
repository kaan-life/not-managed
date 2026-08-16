# Native `terraform test` regressions on top of firewall_validations.tftest.hcl's nine
# runs. Same design for the same reasons: every run is negative (`expect_failures`), and
# all five declared providers are mocked — see that file's header for why both of those
# are measured requirements rather than choices.
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

mock_provider "hcloud" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "github" {}
mock_provider "time" {}

variables {
  hcloud_token                = "not-a-token"
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
