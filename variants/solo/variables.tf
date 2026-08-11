# SPDX-License-Identifier: Apache-2.0

variable "hcloud_token" {
  sensitive = true
}

# k3s cluster-join token. Leave it null and the module generates one (random_password);
# it is set explicitly here because it was rotated on 2026-06-10 after the previous value
# was pasted into a diagnostic session.
#
# ROTATION ORDER IS NOT OPTIONAL — rotate on the server first, push config second:
#   1. put the new value in secrets.auto.tfvars;
#   2. on the control plane: `k3s token rotate --new-token <new>`;
#   3. terraform apply — the module pushes config.yaml to every node and restarts
#      k3s / k3s-agent.
# Do step 3 before step 2 and the agents restart holding a token the server has not
# accepted yet, so they fail to rejoin.
variable "k3s_token" {
  type      = string
  sensitive = true
  default   = null
}

variable "robot_user" {
  sensitive = true
  default   = ""
}

variable "robot_password" {
  sensitive = true
  default   = ""
}

variable "github_app_id" {
  type        = string
  description = "GitHub App ID for ArgoCD repo access"
}

variable "github_app_installation_id" {
  type        = string
  description = "GitHub App Installation ID"
}

variable "github_app_private_key_path" {
  description = "Path to the GitHub App private key PEM file"
  type        = string
}

variable "github_org_url" {
  description = "GitHub organisation URL, e.g. https://github.com/your-org"
  type        = string
}

variable "github_repo_name" {
  description = "Name of the companion GitOps repository holding the cluster's manifests, e.g. your-gitops-repo. Combined with github_org_url to form the ArgoCD repoURL — see docs/adr/0008."
  type        = string
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt ACME registration"
  type        = string
}

variable "acme_server" {
  description = <<-EOT
    ACME directory URL for the ClusterIssuer.

    Production:  https://acme-v02.api.letsencrypt.org/directory
    Staging:     https://acme-staging-v02.api.letsencrypt.org/directory

    DELIBERATELY NO DEFAULT, and this is the one place where "no default" is about safety
    rather than identity. Either default is wrong in a way that is hard to see:

      - defaulting to PRODUCTION means every experiment, every green-field test build and
        every fork burns Let's Encrypt's real rate limits. They are per registered domain
        and per week; exhausting them takes out certificate issuance for the domain, and
        waiting is the only remedy.
      - defaulting to STAGING means a forgotten line in a tfvars file silently gives a
        production cluster untrusted certificates. Every browser and every client rejects
        them, and the configuration looks entirely correct.

    An unset variable is an error, which is neither of those.

    Changing this value on a live cluster makes cert-manager register a new ACME account
    and reissue every certificate. Expect a burst of issuance, and do not do it casually
    on production.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+/", var.acme_server))
    error_message = "acme_server must be an https ACME directory URL, e.g. https://acme-staging-v02.api.letsencrypt.org/directory"
  }
}

variable "cluster_name" {
  description = <<-EOT
    Name of the cluster. Every server, load balancer, network, placement group and
    firewall is named after it, so it is what you see in the cloud console.

    The default matches the upstream module's, which keeps existing clusters unchanged.
    Set it to something distinct for any cluster that is not your only one: two clusters
    both called "k3s", in two projects, produce two identical sets of resource names — and
    the only thing that then tells a human (or a script) which console they are looking at
    is the project selector.
  EOT
  type        = string
  default     = "k3s"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric characters and dashes only — it becomes part of every resource name."
  }
}

variable "argocd_domain" {
  description = <<-EOT
    Hostname the ArgoCD web UI and API are served on, e.g. "gitops.example.com".

    Deliberately has no default. It is used three ways at once — the Helm chart's
    global.domain and ingress hostname, the URL in configs.cm, and the target of the
    GitHub push webhook — and if any of those disagree, GitHub deliveries 404 and
    deploys silently fall back to 180-second polling with no error anywhere. A default
    would let a fork inherit someone else's hostname and produce exactly that silence.

    A DNS record for this name must resolve to the cluster's ingress load balancer, and
    cert-manager must be able to complete an HTTP-01 challenge on it.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.argocd_domain))
    error_message = "argocd_domain must be a bare DNS hostname with at least one dot and no scheme, port or path (e.g. \"gitops.example.com\")."
  }
}

variable "argocd_admin_team" {
  description = <<-EOT
    Slug of the GitHub team inside github_org_url whose members get ArgoCD role:admin.

    Used twice and the two must agree: the Dex GitHub connector only admits members of
    this team, and the RBAC policy grants "<org>:<team>" the admin role. Everyone else
    who can authenticate lands on policy.default = role:readonly.

    No default on purpose. A default here is a standing authorisation grant to a team
    name someone else chose; if that team happens to exist in the fork's organisation,
    its members silently become cluster administrators.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.argocd_admin_team))
    error_message = "argocd_admin_team must be a GitHub team slug (letters, digits, hyphen, underscore) — not a display name and not \"org/team\"."
  }
}

variable "ssh_public_key_path" {
  description = <<-EOT
    Path to the SSH PUBLIC key registered with the cloud provider and installed on every
    node. Tilde is expanded, so a path under "~/.ssh/" works as written.

    Only the public half is ever read here. The matching private key is deliberately NOT
    given to the module (ssh_private_key = null in main.tf) — passing it puts it in the
    Terraform state in cleartext. Provisioners therefore need it in a running ssh-agent
    instead; see the comment at that setting.

    No default: this is a path into someone's home directory, and picking one for a fork
    is how you end up publishing which key an operator uses.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(file(pathexpand(var.ssh_public_key_path)))
    error_message = "ssh_public_key_path must point at a readable file."
  }

  validation {
    condition     = can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-|sk-)", trimspace(file(pathexpand(var.ssh_public_key_path)))))
    error_message = "ssh_public_key_path must point at an OpenSSH PUBLIC key (a line starting with ssh-ed25519, ssh-rsa, ecdsa-sha2-* or sk-*). It looks like a private key or something else — never pass the private half here."
  }
}

variable "cluster_timezone" {
  description = <<-EOT
    IANA timezone the maintenance windows are expressed in: kured's reboot window and
    the k3s auto-upgrade window (see the locals in main.tf).

    Unlike the identifiers above this one has a safe default, because getting it wrong
    costs you a badly timed reboot rather than a security or ownership problem. UTC is
    the default precisely because it is unambiguous; set it to your own zone if you want
    "03:00" to mean 03:00 where the people who would notice an outage are asleep.
  EOT
  type        = string
  default     = "UTC"
  nullable    = false

  validation {
    condition     = can(regex("^(UTC|[A-Za-z]+/[A-Za-z_+-]+(/[A-Za-z_+-]+)?)$", var.cluster_timezone))
    error_message = "cluster_timezone must be \"UTC\" or an IANA zone name such as \"Europe/Berlin\" or \"America/New_York\"."
  }
}

variable "extra_firewall_rules" {
  description = <<-EOT
    Extra cloud-firewall rules, passed straight through to the module.

    This exists because main.tf sets restrict_outbound_traffic = true, which allows only
    DNS, HTTP, HTTPS and NTP outbound. Anything else a workload needs to reach — an
    authenticated SMTP submission on 587 was the case that found this — has to be named
    here or it fails as a connection timeout minutes later, with the sending pod
    reporting a queue that never drains and no firewall log to look at.

    Defaults to [] rather than to a working example: which destinations you open is a
    security decision that belongs to whoever runs the cluster, and a leftover default
    would open them without anyone deciding anything. Scope every rule to the narrowest
    destination that works, not to 0.0.0.0/0.
  EOT
  type = list(object({
    description     = string
    direction       = string
    protocol        = string
    port            = string
    source_ips      = list(string)
    destination_ips = list(string)
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for r in var.extra_firewall_rules : contains(["in", "out"], r.direction)])
    error_message = "Every extra_firewall_rules entry needs direction \"in\" or \"out\"."
  }

  validation {
    condition = alltrue([
      for r in var.extra_firewall_rules :
      !contains(r.destination_ips, "0.0.0.0/0") && !contains(r.destination_ips, "::/0")
    ])
    error_message = "An extra_firewall_rules entry opens 0.0.0.0/0 or ::/0 outbound, which undoes restrict_outbound_traffic for the whole cluster. Name the destination network instead."
  }
}

variable "utility_namespaces" {
  type        = list(string)
  description = "List of Kubernetes namespaces to create"
}

variable "app_namespaces" {
  type        = list(string)
  description = "Namespaces that need the GitHub App credentials secret"
}

variable "etcd_s3_endpoint" {
  description = "S3 endpoint for etcd backups"
  type        = string
}

variable "etcd_s3_access_key" {
  description = "S3 access key for etcd backups"
  type        = string
  sensitive   = true
}

variable "etcd_s3_secret_key" {
  description = "S3 secret key for etcd backups"
  type        = string
  sensitive   = true
}

variable "etcd_s3_bucket" {
  description = <<-EOT
    S3 bucket holding etcd snapshots. No default: the previous one ("k3s-etcd-snapshots")
    was the same name for everybody, and a shared name is one misconfigured endpoint away
    from two clusters writing snapshots over each other. Naming your own is one line and
    removes the class of accident entirely.
  EOT
  type        = string
  nullable    = false
}

variable "etcd_s3_region" {
  description = "S3 region for etcd backups"
  type        = string
}

# Firewall source CIDRs.
#
# These two validations used to be a blocklist of exactly two strings: "0.0.0.0/0" and
# "::/0". That is not a control, it is a spelling check. Every one of these passed it
# while opening the cluster to the entire internet:
#
#   ["0.0.0.0/1", "128.0.0.0/1"]   the whole IPv4 internet, in two halves
#   ["::/1", "8000::/1"]           the whole IPv6 internet, in two halves
#   ["0.0.0.0/8"]                  16.7 million hosts
#   null                           no firewall restriction at all — and this is what
#                                  secrets.auto.example.tfvars actually shipped
#   []                             same
#
# The rule below is positive instead: an entry is acceptable only if it is either one of
# the non-routable supernets listed inline, or a prefix specific enough that covering the
# internet with it is not something you can do by accident. /24 needs 2^16 entries to
# cover IPv4; /48 needs 2^47 to cover the IPv6 unicast space.
#
# The supernet list is inlined rather than pulled from a local, because a variable
# validation may only reference variables — not locals.

variable "firewall_kube_api_source" {
  description = "CIDRs allowed to reach the Kubernetes API. No default and not nullable — must be set explicitly. Recommended: the Tailscale CGNAT range 100.64.0.0/10, or a /32 of your egress IP. Public prefixes must be /24 or narrower (IPv6: /48 or narrower)."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.firewall_kube_api_source) > 0
    error_message = "firewall_kube_api_source must not be empty: an empty list applies no restriction at all."
  }

  validation {
    condition = alltrue([
      for c in var.firewall_kube_api_source : can(cidrhost(c, 0))
    ])
    error_message = "Every entry in firewall_kube_api_source must be a valid CIDR in address/prefix form (e.g. \"100.64.0.0/10\")."
  }

  validation {
    condition = alltrue([
      for c in var.firewall_kube_api_source : (
        contains(["100.64.0.0/10", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7", "fd00::/8"], c)
        || (can(cidrhost(c, 0)) && (
          strcontains(c, ":")
          ? tonumber(split("/", c)[1]) >= 48
          : tonumber(split("/", c)[1]) >= 24
        ))
      )
    ])
    error_message = "firewall_kube_api_source must not be open to the internet. Allowed: the non-routable supernets 100.64.0.0/10, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7, fd00::/8; or any IPv4 prefix of /24 or narrower, or IPv6 prefix of /48 or narrower. A blocklist of \"0.0.0.0/0\" is trivially walked around with [\"0.0.0.0/1\", \"128.0.0.0/1\"], which is why this is an allowlist."
  }
}

variable "firewall_ssh_source" {
  description = "CIDRs allowed to SSH into nodes. No default and not nullable — must be set explicitly. Recommended: the Tailscale CGNAT range 100.64.0.0/10, or a /32 of your egress IP. Public prefixes must be /24 or narrower (IPv6: /48 or narrower)."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.firewall_ssh_source) > 0
    error_message = "firewall_ssh_source must not be empty: an empty list applies no restriction at all."
  }

  validation {
    condition = alltrue([
      for c in var.firewall_ssh_source : can(cidrhost(c, 0))
    ])
    error_message = "Every entry in firewall_ssh_source must be a valid CIDR in address/prefix form (e.g. \"203.0.113.7/32\")."
  }

  validation {
    condition = alltrue([
      for c in var.firewall_ssh_source : (
        contains(["100.64.0.0/10", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7", "fd00::/8"], c)
        || (can(cidrhost(c, 0)) && (
          strcontains(c, ":")
          ? tonumber(split("/", c)[1]) >= 48
          : tonumber(split("/", c)[1]) >= 24
        ))
      )
    ])
    error_message = "firewall_ssh_source must not be open to the internet. Allowed: the non-routable supernets 100.64.0.0/10, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7, fd00::/8; or any IPv4 prefix of /24 or narrower, or IPv6 prefix of /48 or narrower."
  }
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for node registration"
  type        = string
  sensitive   = true
}

variable "tailscale_advertise_routes" {
  description = <<-EOT
    Private subnets this cluster's nodes advertise as Tailscale subnet routes, so the
    Hetzner private network is reachable from the tailnet. Empty means advertise nothing.

    THIS HAS TO DIFFER PER CLUSTER, and the default cannot do that for you. Every node runs
    the advertisement (it is in preinstall_exec, not something only the NAT router does), so
    two clusters built from this repository onto the SAME tailnet advertise the SAME prefix
    and Tailscale picks one of them as the primary router for it. Measured on 2026-08-11
    while green-field testing:

      tailscale status --json  ->  peer k3s-agent-small-pkb PrimaryRoutes ['10.0.0.0/16']

    Several production nodes advertise that prefix and one had been elected primary, which
    only happens where routes for the tag are auto-approved. A second cluster joining that
    tailnet is therefore one election away from taking over the FIRST cluster's subnet
    route — traffic for the wrong cluster's private network, with nothing logged anywhere.

    So: give a second cluster its own range (set network_ipv4_cidr to match), or set this to
    [] and reach it by node address only. The default is what this cluster has always
    advertised, so leaving it alone changes nothing.
  EOT
  type        = list(string)
  default     = ["10.0.0.0/16"]
  nullable    = false

  validation {
    condition = alltrue([
      for r in var.tailscale_advertise_routes :
      can(cidrhost(r, 0)) && (
        can(regex("^10\\.", cidrhost(r, 0))) ||
        can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", cidrhost(r, 0))) ||
        can(regex("^192\\.168\\.", cidrhost(r, 0)))
      )
    ])
    error_message = "Every entry must be an RFC1918 IPv4 CIDR. Advertising a public range over the tailnet blackholes it for every device on the tailnet, not just this cluster."
  }

  validation {
    condition     = !contains([for r in var.tailscale_advertise_routes : trimspace(r)], "0.0.0.0/0")
    error_message = "0.0.0.0/0 would make these nodes the default route for the whole tailnet."
  }
}

variable "bootstrap_phase" {
  description = <<-EOT
    Pass 1 of a green-field build. Set true for the FIRST apply of a cluster that does not
    exist yet, then false for every apply after it.

    Why it exists: the Kubernetes API is served only over the VPN, at an address Tailscale
    assigns when the control plane first joins the tailnet. That address therefore cannot
    be known before the cluster exists, yet it is needed as a certificate SAN and as the
    address kubeconfig dials. The chicken-and-egg is resolved by building in two passes:

      pass 1  terraform apply -var bootstrap_phase=true
              no tailnet SAN, and the control-plane load balancer keeps its public
              interface so the apply can reach the API at all
      pass 2  read the assigned address, set kube_api_tailnet_address, apply again
              the certificate is reissued with the SAN and the public interface closes

    ONE FLAG RATHER THAN TWO KNOBS, deliberately. Pass 1 needs three settings to move
    together; as separate inputs, setting some and not others fails deep inside the apply
    with an error that names none of them.

    Leaving this true is a real exposure, not a cosmetic one: it keeps the control-plane
    API reachable from the public internet, gated only by firewall_kube_api_source. The
    default is false so that the safe state is the one you get by not thinking about it.
  EOT
  type        = bool
  default     = false
}

variable "kube_api_tailnet_address" {
  description = <<-EOT
    The control-plane node's address on your VPN. The Kubernetes API is served only over
    the VPN, so this address is used twice and must be identical in both places: as a
    certificate SAN (additional_tls_sans) and as the address kubeconfig and the
    kubernetes/helm providers dial (kubeconfig_server_address).

    Tailscale assigns this when the control plane first joins the tailnet, so on a brand
    new cluster you cannot know it in advance — build in two passes, see main.tf and
    docs/RUNBOOK.md. This was previously hardcoded, which made a green-field build
    impossible.

    Must be a VPN address, not a public one: Tailscale CGNAT (100.64.0.0/10) or RFC 1918.
    A public address here would be published in the API server's certificate.
  EOT
  type        = string
  nullable    = false

  # EMPTY IS THE BOOTSTRAP VALUE, not an oversight. On pass 1 of a green-field build this
  # address does not exist yet — the control plane has not joined the tailnet — so
  # var.bootstrap_phase runs the cluster up without it. Both validations below therefore
  # admit "" and stay strict about everything else.
  #
  # Until 2026-08-10 this variable had no default, which made the two-pass build in main.tf
  # literally impossible: Terraform refuses to plan when a required variable is unset, so
  # "apply with it unset" could never be executed by anybody. The first green-field run
  # found it at plan time, before a single resource existed.
  default = ""

  validation {
    condition     = var.kube_api_tailnet_address == "" || can(cidrhost("${var.kube_api_tailnet_address}/32", 0))
    error_message = "kube_api_tailnet_address must be a bare IPv4 address without a prefix (e.g. \"100.64.0.1\"), or empty during bootstrap_phase."
  }

  validation {
    condition     = var.kube_api_tailnet_address == "" || can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.", var.kube_api_tailnet_address)) || can(regex("^10\\.", var.kube_api_tailnet_address)) || can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", var.kube_api_tailnet_address)) || can(regex("^192\\.168\\.", var.kube_api_tailnet_address))
    error_message = "kube_api_tailnet_address must be a private or CGNAT address — 100.64.0.0/10 (Tailscale), 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16. A public address here ends up in the API server's TLS certificate and defeats the VPN-only design."
  }
}

variable "github_oauth_client_id" {
  description = "GitHub OAuth App client ID for ArgoCD Dex SSO"
  type        = string
}

variable "github_oauth_client_secret" {
  description = "GitHub OAuth App client secret for ArgoCD Dex SSO"
  type        = string
  sensitive   = true
}

variable "argocd_webhook_secret" {
  description = <<-EOT
    Shared secret for the GitHub push webhook on the GitOps repository, validated
    by ArgoCD as webhook.github.secret. Without a webhook ArgoCD only discovers
    gitops commits on its next reconciliation poll (timeout.reconciliation=180s),
    which measured a mean 159.1s deploy lag over 10 samples (2026-07-28..30).
    Generate with: openssl rand -hex 32
  EOT
  type        = string
  sensitive   = true
}

# ─── Terraform Remote State Backend ──────────────────────────────────────────
# Only the CREDENTIALS live here. Which bucket, key, region and endpoint to use is set
# in backend.hcl and passed to `terraform init -backend-config=` — see providers.tf.
#
# There used to be tf_state_bucket / tf_state_endpoint / tf_state_region variables here
# as well, described as "must match the backend block in providers.tf". Nothing read
# them and nothing enforced the match: they were three values that looked authoritative,
# were consumed by no code path, and could drift from the real backend without any
# signal. With a partial backend there is exactly one place the state store is named,
# and it is not a Terraform variable.
#
# These two are still variables because init.sh and destroy.sh read them out of
# secrets.auto.tfvars and export them as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY,
# which is where the S3 backend looks for credentials. Declaring them also keeps
# Terraform from warning about undeclared variables in an .auto.tfvars file.

variable "tf_state_access_key" {
  description = "S3 access key for Terraform state backend — exported as AWS_ACCESS_KEY_ID by init.sh"
  type        = string
  sensitive   = true
}

variable "tf_state_secret_key" {
  description = "S3 secret key for Terraform state backend — exported as AWS_SECRET_ACCESS_KEY by init.sh"
  type        = string
  sensitive   = true
}