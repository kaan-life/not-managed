# Runbook

Procedures that cannot be expressed as configuration, because they involve ordering,
a value that does not exist yet, or a decision a human has to make.

Three files point here — `providers.tf`, `variables.tf` and `main.tf` — so if you are
reading this after following a comment, you are in the right place.

---

## 1. Initialising the remote state backend

`providers.tf` declares a **partial** backend. It configures how to talk to an
S3-compatible object store and deliberately does not say which one. That is not an
omission to be filled in by editing the file:

```hcl
backend "s3" {
  use_path_style = true
  # ... protocol flags only. No bucket, no key, no region, no endpoint.
}
```

A `backend` block cannot reference `var.*` — Terraform has no syntax for it — so
anything written there is a constant for everyone who clones the repository. When the
bucket was a literal, `git clone && terraform init` pointed a stranger's Terraform at
the original author's live state file. The first `apply` then plans a brand-new cluster
as a diff against a running one.

### Setup

```bash
cp backend.hcl.example backend.hcl
$EDITOR backend.hcl                       # bucket, key, region, endpoint
terraform init -backend-config=backend.hcl
```

`backend.hcl` is gitignored. `backend.hcl.example` is the tracked one.

Credentials are **not** in `backend.hcl`. The S3 backend reads `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` from the environment; `init.sh` and `destroy.sh` export them
from `tf_state_access_key` / `tf_state_secret_key` in `secrets.auto.tfvars`. To run
`terraform` directly:

```bash
export AWS_ACCESS_KEY_ID=$(sed -n 's/^[[:space:]]*tf_state_access_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' secrets.auto.tfvars)
export AWS_SECRET_ACCESS_KEY=$(sed -n 's/^[[:space:]]*tf_state_secret_key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' secrets.auto.tfvars)
terraform init -backend-config=backend.hcl
```

### Create the bucket first, with versioning on

Terraform will not create the store it keeps its own state in. Create the bucket by
hand before the first `init`, and **enable versioning on it**. A truncated or
overwritten state file is recoverable from a previous object version and is recoverable
from nothing else; without versioning, one interrupted write can leave you re-importing
every resource by hand.

### What each entry point does

| Command | Backend | Notes |
|---|---|---|
| `terraform init -backend-config=backend.hcl` | real state store | the normal path |
| `bash init.sh` / `bash destroy.sh` | real state store | resolve `backend.hcl` from the *script's* directory, not `$PWD`; override with `TF_BACKEND_CONFIG` |
| `terraform init -backend=false` | none | validation and CI; needs no credentials and no bucket |

### Failure modes, measured

| Situation | What happens |
|---|---|
| `terraform init -input=false` with no `-backend-config` | exits 1: `Missing Required Value — The attribute "bucket" is required by the backend` (and the same for `key`) |
| interactive `terraform init` with no `-backend-config` | prompts for the bucket; with no one to answer, exits 1 (`Error asking for input to configure backend "s3": bucket: EOF`) |

`region` is the one field that can also come from `AWS_REGION` / `AWS_DEFAULT_REGION` in
the environment. `bucket` and `key` cannot come from anywhere but `-backend-config`, and
those are the two that decide whose state you are about to write.

| `init.sh` / `destroy.sh` with no `backend.hcl` | exits 1 before touching Terraform, printing the `cp backend.hcl.example` command |
| switching an existing working copy to a different `backend.hcl` | Terraform detects the change and asks to migrate. Answer `no` unless you *mean* to move state. `-reconfigure` discards the existing backend settings without migrating |

---

## 2. Bootstrapping a new cluster: the two-pass build

The Kubernetes API is served only over the VPN, at the control plane's tailnet address.
That address is assigned by Tailscale when the control plane first joins the tailnet, so
on a cluster that does not exist yet **you cannot know it in advance** — and it is
required in two places at once:

- `additional_tls_sans`, or the API server's certificate does not cover the address you
  dial and every `kubectl` fails the TLS handshake;
- `kubeconfig_server_address`, which is what kubeconfig and the `kubernetes` / `helm`
  providers actually dial.

Both read `var.kube_api_tailnet_address`, so they cannot drift apart. But neither can be
filled in before the node exists. Hence two passes. Skipping pass 1 is why a green-field
build used to fail outright.

### Pass 1 — bring the control plane up so Tailscale can address it

1. Set every other variable in `secrets.auto.tfvars`.
2. Set `kube_api_tailnet_address` to a placeholder inside the accepted range — the
   variable rejects public addresses, so use something in `100.64.0.0/10`.
3. Leave the public control-plane load-balancer interface **enabled**:
   in `main.tf`, `control_plane_lb_enable_public_interface = true`.
4. `bash init.sh` — builds the MicroOS snapshot with Packer and runs the phased apply.

The node boots, `preinstall_exec` installs Tailscale and runs `tailscale up`, and the
node registers with your tailnet.

### Pass 2 — pin the real address and close the public interface

5. Read the assigned address: `tailscale status`, or the Tailscale admin console.
6. Put it in `secrets.auto.tfvars` as `kube_api_tailnet_address`.
7. Set `control_plane_lb_enable_public_interface = false`.
8. `terraform apply`. The API server certificate is reissued with the new SAN, and the
   load balancer's public interface is removed.

> With a `nat_router` present, step 8 also turns on `enable_cp_lb_port_forward`, which
> rewrites the NAT router's cloud-init and therefore **rebuilds the NAT router once**.
> The public IP survives (it is a separate, stable primary-IP resource) and `kubectl`
> over the tailnet is unaffected. Expect it in the plan; it is not drift.

### Verifying

```bash
kubectl get nodes          # over the tailnet; fails if the SAN is wrong
tailscale status           # the control plane should be listed and reachable
```

If `kubectl` reports a certificate error naming an IP address, the SAN and the dialled
address have diverged — check that both really do come from
`var.kube_api_tailnet_address` and re-apply.

### The GitHub App private key must be PKCS#1, and the error says otherwise

The `github` provider authenticates as a GitHub App using the PEM at
`github_app_private_key_path`. It accepts **PKCS#1** only — the file must start with:

```
-----BEGIN RSA PRIVATE KEY-----
```

GitHub hands you a PKCS#1 key, so this is usually invisible. It bites when the key has
been round-tripped through a tool that re-encodes it — `openssl genpkey`, `ssh-keygen -m
PKCS8`, some secret managers — producing `-----BEGIN PRIVATE KEY-----` instead. Then
`terraform plan` fails with:

```
Error: x509: failed to parse private key (use ParsePKCS8PrivateKey instead for this key format)
```

which reads like advice and is actually the provider telling you it tried PKCS#1 and
found PKCS#8. Convert it back:

```bash
openssl rsa -in pkcs8-key.pem -traditional -out secrets/your-github-app.pem
chmod 600 secrets/your-github-app.pem
head -1 secrets/your-github-app.pem     # must say BEGIN RSA PRIVATE KEY
```

An empty or placeholder file gives a different message — `no decodeable PEM data found`.

---

## 3. State: what protects it, and how to get it back

The state file is the single most valuable object in this system. It describes every
resource, and it contains secrets in cleartext — the webhook shared secret is a real
resource attribute the provider must persist, and older versions still hold an SSH
private key that was removed from the configuration on 2026-08-05. Losing it means
re-importing every resource by hand. Reading it is equivalent to holding the credentials.

### What is configured, measured against the live bucket

| Control | State | Notes |
|---|---|---|
| Bucket versioning | **Enabled** | every write keeps the previous object; this is the whole restore story |
| MFA delete | Disabled | not offered by this provider |
| Noncurrent version expiry | **90 days** | bounded on purpose: unbounded retention keeps the old SSH key and old webhook secret forever |
| Abort incomplete multipart uploads | 7 days | stops a half-written state from accumulating cost |
| Bucket ACL | project owner only, `FULL_CONTROL` | no `AllUsers` or `AuthenticatedUsers` grant — the bucket is not public |
| Object lock | not configured | not offered |
| Bucket default encryption (SSE) | **not available** | the provider rejects it, see below |
| State locking | native `.tflock` in the bucket (`use_lockfile = true`) | no DynamoDB equivalent needed |

**Encryption at rest is not available here, and that is a measured fact rather than an
oversight.** `GetBucketEncryption` returns
`ServerSideEncryptionConfigurationNotFoundError`, and setting one was attempted on
2026-08-05: `PutBucketEncryption` was refused with `InvalidArgument`. This object storage
does not offer bucket default encryption, so there is no configuration change that closes
this — it is a property of the provider.

What that means in practice: treat the state file as **unencrypted at rest**, and treat
the two S3 credentials as equivalent to the contents of the state. That is the reason the
90-day noncurrent expiry above is a control and not housekeeping — it is the only thing
that eventually removes the old SSH private key and past webhook secrets from reach. If
encryption at rest becomes a requirement, the answer is a different storage provider, not
a different setting.

### Restoring a previous state version

Versioning is only a backup if someone has retrieved from it. This procedure was
exercised read-only on 2026-08-08: a previous version was fetched, parsed, and checked
for lineage and serial. Nothing was written.

```bash
# List what is available. Requires an S3 client; boto3 is enough.
python3 - <<'EOF'
import boto3, botocore
s3 = boto3.client("s3", endpoint_url="<endpoint from backend.hcl>", region_name="<region>",
                  aws_access_key_id="<tf_state_access_key>",
                  aws_secret_access_key="<tf_state_secret_key>",
                  config=botocore.config.Config(s3={"addressing_style": "path"}))
for v in sorted(s3.list_object_versions(Bucket="<bucket>", Prefix="terraform.tfstate")["Versions"],
                key=lambda v: v["LastModified"], reverse=True)[:10]:
    print(v["LastModified"], v["Size"], "CURRENT" if v["IsLatest"] else "", v["VersionId"])
EOF
```

Before restoring anything, check three fields in the candidate:

- **`lineage`** must equal the current state's lineage. A different lineage is a different
  state file's history; restoring it makes Terraform think it has never seen this
  infrastructure.
- **`serial`** should be lower than the current one. Equal or higher means you have the
  wrong object.
- **instance count** — and count *instances*, not entries. Terraform regroups the
  `resources` array between writes, so comparing `len(state["resources"])` is misleading:
  in the two versions inspected on 2026-08-08 that count went 132 → 87 while the actual
  set of resource addresses went 102 → 104 and nothing was lost. Expand each resource's
  `instances` and compare addresses.

To restore, download the chosen version to `terraform.tfstate` locally and push it:

```bash
umask 077                       # the file contains credentials
# ... download the chosen VersionId to ./restored.tfstate ...
terraform state push restored.tfstate     # increments serial; keeps lineage
shred -u restored.tfstate
```

Then run `terraform plan` and read every line. A restored state is a claim about
reality that has not been checked yet: anything created after the restored version
exists in the cloud and not in the state, and will be planned as an addition.

### If the state is gone entirely

There is no shortcut. Recreate the bucket, `terraform init -backend-config=backend.hcl`,
and `terraform import` each resource. The module creates far more resources than this
root configuration declares, so budget for a long day and expect to read
`terraform state list` from a colleague's copy or from an etcd snapshot's cluster
metadata to reconstruct the inventory. This is why the versioning row above matters more
than any other row in the table.

### Related but separate: etcd snapshots

Cluster *data* is not in Terraform state. etcd snapshots run every 4 hours with 42 kept
(a rolling 7 days) and are copied to object storage — see `control_planes_custom_config`
and `etcd_s3_backup` in `main.tf`. Restoring etcd rebuilds Kubernetes objects; restoring
Terraform state rebuilds Terraform's knowledge of the servers. Losing either one does not
help you recover the other.
