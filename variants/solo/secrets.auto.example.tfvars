# Your Hetzner token can be found in your Project > Security > API Token (Read & Write is required).
hcloud_token   = ""
robot_user     = ""
robot_password = ""

# k3s cluster-join-token (optioneel; leeg laten = module genereert er zelf één).
# Rotatieprocedure: zie variable "k3s_token" in variables.tf.
k3s_token = "<48-tekens-alfanumeriek>"

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
argocd_admin_team = "k8s-admins"

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

utility_namespaces = ["your-tooling", "your-tekton"]
app_namespaces     = ["your-dev", "your-prod"]

etcd_s3_endpoint   = "xxxx.r2.cloudflarestorage.com"
etcd_s3_access_key = "<access-key>"
etcd_s3_secret_key = "<secret-key>"
etcd_s3_bucket     = "k3s-etcd-snapshots"
etcd_s3_region     = "<your-s3-bucket-region>"

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

tailscale_auth_key = "<your-tailscale-auth-key>"

# The control-plane node's tailnet address. Serves double duty: certificate SAN and the
# address kubeconfig dials. Tailscale assigns it when the control plane first joins, so
# on a NEW cluster you cannot know it up front — apply once without it (public LB still
# enabled), read the assigned address, set it here, apply again. See docs/RUNBOOK.md.
kube_api_tailnet_address = "100.64.0.1" # REPLACE with your control plane's tailnet address

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
