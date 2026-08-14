# Your Hetzner token can be found in your Project > Security > API Token (Read & Write is required).
hcloud_token   = ""
robot_user     = ""
robot_password = ""

# k3s cluster-join token. OPTIONAL, and commented out on purpose: leave the line alone and
# the module generates one for you, which is what you want unless you are restoring a
# cluster. Rotation procedure: see variable "k3s_token" in variables.tf — rotate on the
# server BEFORE pushing config, never the other way round.
#
# COMMENTED RATHER THAN GIVEN A PLACEHOLDER, because a placeholder here is not inert:
# whatever string is on this line becomes the cluster join secret. Until 2026-08-12 the
# line read `k3s_token = "<48-tekens-alfanumeriek>"`, so a forker who did not replace it
# shipped a cluster whose join token is published in this repository.
#
# And not `= ""` either: the module validates `cluster_token must be null or a non-empty
# token string`, so an empty string fails the plan. Absent means null, which means
# generated.
# k3s_token = "your-own-48-character-token-if-you-are-restoring-a-cluster"

github_org_url              = "https://github.com/your-org"
github_repo_name            = "your-gitops-repo"
github_app_id               = "123456"
github_app_installation_id  = "78901234"
github_app_private_key_path = "secrets/your-github-app.pem" # NEED TO ADD THIS TO SECRETS folder

github_oauth_client_id     = "<github-oauth-app-client-id>"
github_oauth_client_secret = "<github-oauth-app-client-secret>"

# Tekton EventListener webhook signing secret — generate with: openssl rand -hex 32
# Use this same value when registering the webhook on each GitHub *application*
# repository (the one whose push should start a build).
#
# THERE IS NO TERRAFORM VARIABLE FOR THIS, and that is not an omission on this line: the
# secret belongs to the companion GitOps repository, where the EventListener lives, and it
# is applied there as a SealedSecret. Nothing in this file consumes it. It is written here
# because this is where you are already generating secrets, and because a reader who meets
# the EventListener first has no way back to this instruction.

# ArgoCD webhook shared secret — separate from the Tekton one above. Register it as
# the secret on a push webhook on your *gitops* repo, pointing at
# https://<argocd-domain>/api/webhook. Without it ArgoCD never learns that the
# pipeline pushed a new image tag and only notices on its next reconciliation poll
# (180s default; measured ~159s mean deploy lag). See argocd.tf >
# terraform_data.argocd_webhook_secret. Generate with: openssl rand -hex 32
argocd_webhook_secret = "<openssl-rand-hex-32>"

letsencrypt_email = "your@email.here"

# ACME directory. NO DEFAULT — you must choose, because both defaults are wrong in ways
# you find out late. Start on STAGING: certificates will be untrusted, but issuance is
# rate-limit-free, so you can iterate. Switch to production only once issuance works.
#   staging:    https://acme-staging-v02.api.letsencrypt.org/directory
#   production: https://acme-v02.api.letsencrypt.org/directory
acme_server = "https://acme-staging-v02.api.letsencrypt.org/directory"

# Every resource is named after this. Make it distinct if this is not your only cluster.
# cluster_name = "k3s"


# Hostname for the ArgoCD UI/API. A DNS record for it must point at the cluster's
# ingress load balancer, and it is also the target of the GitHub push webhook — if the
# two ever disagree, deliveries 404 and deploys silently fall back to 180s polling.
argocd_domain = "gitops.example.com"

# GitHub team (inside github_org_url) whose members get ArgoCD role:admin. Everyone else
# who can authenticate gets role:readonly.
# A PLACEHOLDER, like every other value in this file. Until 2026-08-14 this line carried the
# maintainer's REAL team name while its neighbours were all placeholders — so a reader had
# every reason to think it was one too, and publishing it announced which GitHub accounts
# are worth phishing to reach a production ArgoCD.
#
# The first replacement kept the real team name as a substring, wrapped in "your-...-team",
# and the gate rejected it on the spot. A placeholder that embeds the string you are
# removing is not a placeholder — and the failed attempt is described here rather than
# quoted, for the same reason docs/RUNBOOK.md describes the PKCS#1 header instead of
# reproducing it.
argocd_admin_team = "your-admins-team"

# SSH PUBLIC key installed on every node. The matching PRIVATE key is never given to
# Terraform (it would land in the state); load it into an ssh-agent before applying.
ssh_public_key_path = "~/.ssh/id_ed25519.pub"

# IANA timezone for the kured reboot window and the k3s auto-upgrade window. Defaults to
# UTC if you leave it out.
cluster_timezone = "Europe/Berlin"

# restrict_outbound_traffic is on, so only DNS/HTTP/HTTPS/NTP leave the cluster. Anything
# else has to be named here or it fails as a silent timeout. Empty by default; scope each
# rule to the narrowest destination that works. 0.0.0.0/0 is refused.
extra_firewall_rules = [
  # {
  #   description     = "SMTP submission out: relay -> mail provider"
  #   direction       = "out"
  #   protocol        = "tcp"
  #   port            = "587"
  #   source_ips      = []
  #   destination_ips = ["198.51.100.0/24"]
  # },
]

# These are the only values in this file WITHOUT a `your-` prefix, and that is deliberate:
# they are not free-form names. Each one must EQUAL a top-level directory in the companion
# GitOps repository, because the root ApplicationSet is generated with
# `path: {{environment}}`. The three below are the directories the published companion
# actually ships, so this file works against it unedited.
#
# Rename them only together with those directories. A namespace with no matching directory
# produces an Application that reports `Healthy` — one with zero resources trivially is —
# while sync sits at `Unknown` with `app path does not exist`.
utility_namespaces = ["tooling", "tekton"]
app_namespaces     = ["prod"]

etcd_s3_endpoint   = "xxxx.r2.cloudflarestorage.com"
etcd_s3_access_key = "<access-key>"
etcd_s3_secret_key = "<secret-key>"
etcd_s3_bucket     = "k3s-etcd-snapshots"
etcd_s3_region     = "<your-s3-bucket-region>"

# ─── Locations (this variant only) ───────────────────────────────────────────
# Both have defaults, so you can leave them out. Read the descriptions in variables.tf
# before you change secondary_location: it is where the third etcd member lives, and the
# distance between the two locations is paid on writes.
#
# primary_location   = "nbg1"   # two control planes, all agents, both LBs, active NAT
# secondary_location = "fsn1"   # third control plane, standby NAT router

# Firewall sources. Both are required and neither may be null — null used to be the
# value shipped here, and it disabled the restriction entirely while still passing the
# old validation. The values below are a working, safe default: the Kubernetes API is
# reachable only over Tailscale, and SSH only from one address you replace.
#
# Accepted: the non-routable supernets 100.64.0.0/10, 10.0.0.0/8, 172.16.0.0/12,
# 192.168.0.0/16, fc00::/7, fd00::/8 — or any IPv4 prefix of /24 or narrower (IPv6: /48 or
# narrower). Anything broader is refused, including "0.0.0.0/1" + "128.0.0.0/1".
firewall_kube_api_source = ["100.64.0.0/10"]  # Tailscale CGNAT range
firewall_ssh_source      = ["203.0.113.7/32"] # REPLACE: your egress IP (this is TEST-NET-3, reserved for docs)

# Required by this variant because the NAT routers are redundant: the keepalived pair
# calls the Hetzner API to move the floating IP on failover, so this token is written onto
# machines with a public interface. Use a SEPARATE token from hcloud_token above — not
# because it is less powerful (Hetzner tokens cannot be scoped) but so it can be revoked
# without taking the rest of the cluster's automation with it.
nat_router_hcloud_token = "<a second 64-character Hetzner API token>"

tailscale_auth_key = "<your-tailscale-auth-key>"

# Private subnets this cluster's nodes advertise as Tailscale subnet routes. Leave it out
# and you get ["10.0.0.0/16"], which is correct for ONE cluster on a tailnet.
#
# IT HAS TO DIFFER PER CLUSTER, and the default cannot do that for you. Every node runs the
# advertisement — it is in preinstall_exec, not something only the NAT router does — so two
# clusters built from this repository onto the SAME tailnet advertise the same prefix and
# Tailscale elects one of them primary for it. The second cluster to join is one election
# away from owning the first one's private-network route, and nothing logs that.
#
# Give a second cluster its own range (set network_ipv4_cidr to match), or set this to []
# and reach it by node address only. Listed here because the warning lives in variables.tf,
# which you do not have to open to build — so until 2026-08-14 a reader who filled in only
# this file never saw it.
# tailscale_advertise_routes = ["10.0.0.0/16"]

# The control-plane node's tailnet address. Serves double duty: certificate SAN and the
# address kubeconfig dials. Tailscale assigns it when the control plane first joins, so
# on a NEW cluster you cannot know it up front. Build in two passes — see docs/RUNBOOK.md §2.
#
# LEAVE IT EMPTY FOR PASS 1, and set bootstrap_phase = true below. Empty is the bootstrap
# value; both of the variable's validations admit "" on purpose. This line used to ship a
# plausible-looking 100.64.0.1, which passes validation while belonging to no node — and
# pass 2 cannot tell that apart from a real address you forgot to update.
kube_api_tailnet_address = ""

# Pass 1 of a green-field build: true for the FIRST apply of a cluster that does not exist
# yet, false (or absent) for every apply after it. One flag rather than three settings that
# have to move together. Leaving it true keeps the Kubernetes API reachable from the public
# internet, gated only by firewall_kube_api_source — so delete this line once you are past
# pass 2 rather than leaving it lying around set to false.
# COMMENTED OUT, and shipped that way on purpose. The variable's own default is false
# "so that the safe state is the one you get by not thinking about it", and until
# 2026-08-14 this file shipped it as `true` — which inverts exactly that. Leaving it true
# keeps the Kubernetes API reachable from the public internet, gated only by
# firewall_kube_api_source.
#
# Uncomment it for the first apply, then comment it out again. See docs/RUNBOOK.md §2.
# bootstrap_phase = true

# ─── Terraform Remote State Backend: credentials only ────────────────────────
# WHICH state store to use is not set here. providers.tf declares a partial backend and
# the bucket/key/region/endpoint go in backend.hcl:
#
#   cp backend.hcl.example backend.hcl && $EDITOR backend.hcl
#   terraform init -backend-config=backend.hcl
#
# The bucket must exist before the first init — Terraform does not create the store it
# keeps its own state in. Create it with versioning enabled; docs/RUNBOOK.md has the
# reasoning and the restore procedure.
#
# The two keys below are S3 credentials for that bucket. init.sh and destroy.sh read
# them from this file and export them as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY,
# which is where the backend looks. For Hetzner Object Storage they come from
# Cloud Console > Object Storage > Credentials.
tf_state_access_key = "<object-storage-access-key>"
tf_state_secret_key = "<object-storage-secret-key>"

# !! Remove .example after you have added your variables
# NEVER COMMIT THIS FILE IT CONTAINS YOUR TOKENS
