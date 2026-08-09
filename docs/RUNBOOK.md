# Runbook

Procedures that cannot be expressed as configuration, because they involve ordering,
a value that does not exist yet, or a decision a human has to make.

Three files point here — `providers.tf`, `variables.tf` and `main.tf` — so if you are
reading this after following a comment, you are in the right place.

1. [Initialising the remote state backend](#1-initialising-the-remote-state-backend)
2. [Bootstrapping a new cluster: the two-pass build](#2-bootstrapping-a-new-cluster-the-two-pass-build)
3. [State: what protects it, and how to get it back](#3-state-what-protects-it-and-how-to-get-it-back)
4. [etcd: what is backed up, and how to restore it](#4-etcd-what-is-backed-up-and-how-to-restore-it)

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

### The GitHub App private key must be PKCS#1, and the error points the wrong way

The `github` provider authenticates as a GitHub App using the PEM at
`github_app_private_key_path`, and it accepts **PKCS#1 only**. The two encodings are
distinguishable from the first line: a PKCS#1 header names the algorithm — the word `RSA`
appears in it — and a PKCS#8 header does not.

GitHub hands you PKCS#1, so this is normally invisible. It bites when the key has been
round-tripped through something that re-encodes it: `openssl genpkey`, `ssh-keygen -m
PKCS8`, some secret managers. Then `terraform plan` fails with

```
Error: x509: failed to parse private key (use ParsePKCS8PrivateKey instead for this key format)
```

which reads like advice and is actually the provider saying it tried PKCS#1 and found
PKCS#8. Convert it back:

```bash
openssl rsa -in pkcs8-key.pem -traditional -out secrets/your-github-app.pem
chmod 600 secrets/your-github-app.pem
head -1 secrets/your-github-app.pem       # the header should name RSA
```

An empty or placeholder file gives a different message: `no decodeable PEM data found`.

> Neither header is reproduced literally above, on purpose. A repository containing a
> private-key header line is a permanent finding for every secret scanner that reads it —
> gitleaks, trufflehog, GitHub push protection — and the usual remedy is to teach each
> scanner an exception for the documentation file. Exceptions are how a real key
> eventually slips past one. Describing the signature costs a sentence; excepting it
> costs a control.

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

---

## 4. etcd: what is backed up, and how to restore it

> **This procedure has been written but not executed.** It is assembled from k3s'
> documented `--cluster-reset` behaviour and from what this configuration actually sets,
> and every command below is one you can read in advance. It has not been run end to end
> against a real cluster, and until it has, treat the RTO as unknown rather than short.
> Executing it — deliberately, on the `ha` variant, after killing a control-plane node —
> is the step that turns this section from paper into a procedure.

Terraform state and etcd are two different backups solving two different problems.
Restoring etcd rebuilds *Kubernetes objects*: namespaces, secrets, deployments, ArgoCD
Applications. Restoring Terraform state rebuilds *Terraform's knowledge of the servers*.
Losing one does not help you recover the other. §3 covers the other one.

### What is configured

`main.tf` sets `etcd_s3_backup` (endpoint, bucket, region, credentials) and, in
`control_planes_custom_config`:

| Setting | Value | Meaning |
|---|---|---|
| `etcd-snapshot-schedule-cron` | `0 */4 * * *` | a snapshot every four hours → **RPO ≤ 4 h** |
| `etcd-snapshot-retention` | `42` | 42 × 4 h = **a rolling 7 days** |

Snapshots are written to the control-plane node's disk *and* uploaded to the bucket.
Sized against measurement: snapshots of this cluster are 40–51 MB, so 42 of them is about
2.1 GB locally against ~13 GB free on a 39 GB control-plane disk.

The defaults, had they been left alone, were every 12 hours keeping 5 — an RPO of half a
day and a retention window of about two and a half days. Restore a Friday evening mistake
on Monday and the snapshot that predates it is already gone.

### Before you need it: the two things that make a restore impossible

1. **`k3s_token`.** A restored server rejoins using the cluster token. If you cannot
   produce the value that was in effect when the snapshot was taken, the snapshot is
   inert. It lives in `secrets.auto.tfvars`, mode 0600, on one machine. **Keep a copy
   somewhere that survives losing that machine**, and treat rotating it as a event that
   invalidates every older snapshot's usability.
2. **The S3 credentials for the snapshot bucket.** Same argument. They are in the same
   file, and if that file is only on the laptop that died, so is your recovery.

Verify you can list snapshots *before* an incident, not during one:

```bash
sudo k3s etcd-snapshot list --s3 \
  --s3-bucket=<bucket> --s3-endpoint=<endpoint> --s3-region=<region> \
  --s3-access-key=<key> --s3-secret-key=<secret>
```

### Restoring

The shape of the operation: **all servers stop, one server is reset from the snapshot and
becomes a new single-member cluster, the others wipe their database and rejoin it.** A
restore is not a rolling operation and there is no way to do it without downtime.

```bash
# 1. Stop k3s on EVERY server node. Do this first and completely — a surviving member
#    with the old data will fight the restored one over cluster identity.
sudo systemctl stop k3s          # on each control-plane node

# 2. On ONE control-plane node, reset the cluster from a snapshot. Use the S3 form to
#    pull it directly; use a local path if the node still has the file.
sudo k3s server \
  --cluster-reset \
  --etcd-s3 \
  --cluster-reset-restore-path=<snapshot-name> \
  --etcd-s3-bucket=<bucket> --etcd-s3-endpoint=<endpoint> --etcd-s3-region=<region> \
  --etcd-s3-access-key=<key> --etcd-s3-secret-key=<secret> \
  --token=<k3s_token>

# It runs in the foreground and exits when the reset completes, printing a line telling
# you to restart. That exit is success, not a crash.

# 3. Start it as a normal service. You now have a ONE-member cluster.
sudo systemctl start k3s
kubectl get nodes    # the other servers will show NotReady; that is expected

# 4. On EVERY OTHER control-plane node: delete the old etcd database, then start.
#    Skipping this is the classic mistake — the node tries to rejoin with a database
#    from the cluster that no longer exists and never becomes Ready.
sudo rm -rf /var/lib/rancher/k3s/server/db
sudo systemctl start k3s

# 5. Agents usually need nothing. If one stays NotReady:
sudo systemctl restart k3s-agent
```

### After a restore, before declaring it over

```bash
kubectl get nodes                                   # every node Ready
kubectl -n kube-system get pods                     # CNI, CSI, CCM, kured all running
kubectl -n argocd get applications                  # Synced + Healthy, or syncing
kubectl get pvc -A                                  # bound to the volumes they had
```

Two things that will surprise you:

- **The cluster is back at the snapshot's moment in time.** Anything created since — a
  namespace, a secret, an ArgoCD Application — is gone from Kubernetes but may still
  exist in the cloud. Volumes provisioned after the snapshot become orphans: real,
  billed, and referenced by nothing.
- **Terraform does not know a restore happened.** Run `terraform plan` afterwards and
  read it carefully. Resources it created after the snapshot still exist in the cloud and
  in Terraform state, but the Kubernetes objects backing them may not — the plan is the
  only thing that will show you the divergence.

### What this does not protect against

etcd snapshots contain Kubernetes objects, **not persistent volume data**. Restoring etcd
restores the PersistentVolumeClaim; it does not restore what was inside the database that
claim was mounted into. Application data is a separate backup problem with a separate
answer — volume snapshots, or dumps taken by the applications themselves.
