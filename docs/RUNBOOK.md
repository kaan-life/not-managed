# Runbook

Procedures that cannot be expressed as configuration, because they involve ordering,
a value that does not exist yet, or a decision a human has to make.

Three files point here — `providers.tf`, `variables.tf` and `main.tf` — so if you are
reading this after following a comment, you are in the right place.

1. [Initialising the remote state backend](#1-initialising-the-remote-state-backend)
2. [Bootstrapping a new cluster: the two-pass build](#2-bootstrapping-a-new-cluster-the-two-pass-build)
3. [State: what protects it, and how to get it back](#3-state-what-protects-it-and-how-to-get-it-back)
4. [etcd: what is backed up, and how to restore it](#4-etcd-what-is-backed-up-and-how-to-restore-it)
5. [local-path: why this repository owns a k3s component](#5-local-path-why-this-repository-owns-a-k3s-component)
6. [Dead man's switch: noticing from outside that the cluster stopped reporting](#6-dead-mans-switch-noticing-from-outside-that-the-cluster-stopped-reporting)

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
2. Leave `kube_api_tailnet_address` **empty**. Empty is the bootstrap value, not an
   oversight — the address does not exist yet, and both of the variable's validations
   admit `""` on purpose. A placeholder inside `100.64.0.0/10` also passes validation, but
   it is worse: it is a plausible-looking address that belongs to no node, and pass 2 has
   no way to tell it apart from a real one you forgot to update.
3. Set `bootstrap_phase = true`.

   **This is one flag, not three settings.** Pass 1 needs the tailnet SAN dropped, the
   control-plane load balancer's public interface kept open, and the kubeconfig pointed at
   that interface — and those have to move together. `bootstrap_phase` moves them.

   Until 2026-08-12 this runbook said to set
   `control_plane_lb_enable_public_interface = true` "in `main.tf`" instead. **There is no
   such input** — `grep` it in `variables.tf` and you get nothing. Two independent readers
   coming to this repository cold both stopped here, which is how it was found.
4. `bash init.sh` — builds the MicroOS snapshot with Packer and runs the phased apply.

The node boots, `preinstall_exec` installs Tailscale and runs `tailscale up`, and the
node registers with your tailnet.

### Pass 2 — pin the real address and close the public interface

5. Read the assigned address: `tailscale status`, or the Tailscale admin console.
6. Put it in `secrets.auto.tfvars` as `kube_api_tailnet_address`.
7. Set `bootstrap_phase = false` — or simply delete the line, since `false` is the default.
   **Leaving it `true` is a real exposure**, not a cosmetic one: it keeps the API reachable
   from the public internet, gated only by `firewall_kube_api_source`.
8. `terraform apply`. The API server certificate is reissued with the new SAN, and the
   load balancer's public interface is removed.

> With a `nat_router` present, step 8 also makes the NAT router forward
> `kubernetes_api_port` to the private control-plane LB. In 3.1.0 that is automatic whenever
> `control_plane_load_balancer_enable_public_network = false`. In 2.19.2 `enable_cp_lb_port_forward`
> was the input you set; in 3.1.0 there is no such input — the identifier survives as a value the
> module computes for itself (`nat-router.tf`), so grepping the module still finds it. It rewrites
> the NAT router's
> cloud-init and therefore **rebuilds the NAT router once**.
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

> **This procedure has been executed, twice, on 2026-08-12.** It was run end to end on a
> throwaway `ha` cluster with three control planes — a real three-member etcd, because a
> restore onto a single member proves almost nothing about the operation you would actually
> be performing.
>
> **How it was checked, and why that matters.** "The cluster came back" is not evidence: a
> cluster that never lost anything also comes back. The test used two marker ConfigMaps
> instead. `restore-marker-pre` was created *before* the snapshot and had to **survive**;
> `restore-marker-post` was created *after* it and had to **disappear**. Both rounds:
> pre present, post gone, all four nodes `Ready`, `kube-system` entirely
> `Running`/`Completed`. If you adapt this procedure, keep that shape — a check that cannot
> fail is not a check.
>
> **The second round deleted the local snapshot copy first**, so the node had nothing but
> the bucket to restore from. That is the case the backup exists for, and it is the one
> people forget to test:
>
> ```
> Retrieving etcd snapshot n5restore-… from S3
> S3 download complete for /var/lib/rancher/k3s/server/db/snapshots/n5restore-…
> restored snapshot … kvstore restored current-rev:4933
> ```
>
> **Measured RTO: under five minutes** from `systemctl stop k3s` on the first node to all
> nodes `Ready` again, on a cluster with a 24 MB snapshot. That is the mechanical part
> only. It excludes deciding to restore, choosing which snapshot, and everything you will
> discover afterwards about what changed between the snapshot and now.
>
> Two defects in this section were found by running it rather than reading it: the missing
> server-URL step (§1b below) and the snapshot listing command immediately below. Both are
> fixed here. Assume there are more, and re-run this on a throwaway cluster after any k3s
> minor-version bump.

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

3. **The endpoint must be a BARE HOST.** `etcd_s3_endpoint` is
   `fsn1.example-objectstorage.com`, never `https://fsn1.example-objectstorage.com`. k3s
   prepends the scheme itself, so a value that carries one becomes `https://https://...`
   and the S3 client refuses it. This fails in the worst shape available: snapshots keep
   SAVING and only the RESTORE breaks, so the cluster accumulates months of green, current,
   correctly-sized S3 snapshots it cannot restore from, and nothing says so until the day
   you need it. Measured on the green-field rig, 2026-08-11 — with the scheme,
   `--cluster-reset --etcd-s3` dies on `Endpoint url cannot have fully qualified paths`;
   with a bare host it logs `Retrieving etcd snapshot ... from S3` and completes.
   `variables.tf` now rejects a scheme at plan time so this cannot be reintroduced.

Verify you can list snapshots *before* an incident, not during one:

```bash
sudo k3s etcd-snapshot list
```

**No `--s3` flag, and no S3 credentials on the command line.** `config.yaml` already sets
`etcd-s3: "true"` together with the bucket, endpoint, region and keys, so k3s picks all of
it up on its own. Passing `--s3` as well is not merely redundant — it aborts:

```
Incorrect Usage: Cannot use two forms of the same flag: etcd-s3 s3
```

This runbook told you to pass it until 2026-08-12, which meant the one step it asks you to
rehearse before an incident was itself broken. Measured output of the working form — note
that it lists the bucket copy and the on-disk copy as separate rows, which is how you
confirm the upload actually happened:

```
Name                              Location                                              Size      Created
n5restore-…-1786522709            s3://<bucket>/n5restore-…-1786522709                  24379424  2026-08-12T08:18:29Z
n5restore-…-1786522709            file:///var/lib/rancher/k3s/server/db/snapshots/…     24379424  2026-08-12T08:18:29Z
```

If a snapshot appears only as `file://`, the upload is failing and you have no off-node
backup — which is exactly the failure the bare-host rule above produces.

### Restoring

The shape of the operation: **all servers stop, one server is reset from the snapshot and
becomes a new single-member cluster, the others wipe their database and rejoin it.** A
restore is not a rolling operation and there is no way to do it without downtime.

```bash
# 1. Stop k3s on EVERY server node. Do this first and completely — a surviving member
#    with the old data will fight the restored one over cluster identity.
sudo systemctl stop k3s          # on each control-plane node

# 1b. On the node you are about to reset, REMOVE THE SERVER URL from its config, or the
#     reset refuses to start:
#       cannot perform cluster-reset while server URL is set - remove server from
#       configuration before resetting
#     This step was missing from this runbook until 2026-08-11, when the first real restore
#     stopped here. Note the quoting: kube-hetzner writes config.yaml with QUOTED keys, so
#     the line is `"server": "https://..."` and a sed for '^server:' silently matches
#     nothing — which is exactly what happened on the first attempt.
sudo cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.bak
sudo sed -i '/^"server":/d' /etc/rancher/k3s/config.yaml

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
- **Autoscaler nodes are invisible to `terraform destroy`.** They are created by the
  cluster autoscaler, never enter Terraform state, and so survive a destroy — and a
  surviving node holds the private Network, which then cannot be deleted either. Measured
  on 2026-08-11: a green-field teardown reported success and left one server plus the
  Network billing. Check for it after every destroy, with the project's own API token:

  ```bash
  for r in server volume floating-ip load-balancer network ssh-key placement-group; do
    printf '%-16s' "$r"; hcloud "$r" list -o noheader | wc -l
  done
  ```

  Every line must read `0`. Anything else is billing you forgot about, and the Network in
  particular cannot be deleted while a stray server still sits in it.

  (Until 2026-08-12 this line named a `scripts/assert-no-orphans.sh` instead. That script
  is green-field test tooling for the throwaway project and is deliberately **not**
  published — so this runbook was prescribing a file no reader of it could have. Two
  independent readers went looking for it and found nothing.)

  **Re-measured on 2026-08-12, and it is worse than "reported success".** The same
  teardown left **three** classes behind, not one, and the second one is the reason the
  first is easy to miss:

  1. the autoscaler node, as above;
  2. **CSI `pvc-*` volumes** — provisioned by the driver, never in Terraform state, so
     `destroy` never had them (this is the same gap `enable_delete_protection` has: it
     covers the volumes Terraform declares, not the ones Kubernetes asks for);
  3. because (1) was still attached to it, `hcloud_network_subnet` sat in
     `Still destroying...` for **twenty minutes** and the run ended on
     `Error: Get "https://api.hetzner.cloud/v1/networks/…": context deadline exceeded`.

  So the destroy does not necessarily *claim* success — it can hang for twenty minutes and
  then fail, with the actual cause (one stray server) never named. Delete the orphans by
  hand first, then re-run.

  **And the last resource is a special case.** Once the cluster is gone, a full
  `terraform destroy` cannot even plan: `kubernetes_manifest.letsencrypt` fails with
  `cannot create REST client: no client config`, because the provider has no API to talk
  to. Finish with an explicitly targeted destroy instead:

  ```bash
  terraform destroy -target='module.kube-hetzner.hcloud_network_subnet.control_plane[0]' \
                    -target='module.kube-hetzner.hcloud_network.k3s[0]'
  ```

- **Tear the cluster down BEFORE deleting the companion GitOps repository.** Measured
  2026-08-12: with the repo already gone, `terraform destroy` fails during *planning* with
  `failed to create OAuth token from GitHub App: 404` — the App installation cannot mint a
  token without a repository, and Terraform configures the `github` provider even when the
  state contains no `github` resource at all (0 of 123, in the run that hit this). Nothing
  is destroyed. Targeting the cloud resources routes around it —
  `-target=module.kube-hetzner -target=helm_release.argocd -target=time_sleep.wait_for_argocd`
  destroyed all 102 — but the cheap fix is ordering: cluster first, repository second.
- **Terraform does not know a restore happened.** Run `terraform plan` afterwards and
  read it carefully. Resources it created after the snapshot still exist in the cloud and
  in Terraform state, but the Kubernetes objects backing them may not — the plan is the
  only thing that will show you the divergence.

### What this does not protect against

etcd snapshots contain Kubernetes objects, **not persistent volume data**. Restoring etcd
restores the PersistentVolumeClaim; it does not restore what was inside the database that
claim was mounted into. Application data is a separate backup problem with a separate
answer — volume snapshots, or dumps taken by the applications themselves.

---

## 5. local-path: why this repository owns a k3s component

k3s ships local-path-provisioner as a *packaged component* and re-applies it **on every k3s
start** — not on upgrades, on every start. Each re-apply resets
`storageclass.kubernetes.io/is-default-class` to `"true"`, leaving the cluster with two
default StorageClasses.

Kubernetes permits that. Its documented behaviour is that a PersistentVolumeClaim with no
`storageClassName` gets **the most recently created** default class, and multiple defaults
are explicitly allowed "to allow for seamless migration". So this was never data loss
waiting to happen — but "which kind of volume you get depends on object creation order" is
not a property to run storage on, and repairing it at apply time meant `terraform plan` was
dirty after every reboot. A plan that is never clean is a plan people stop reading.

### What was done

1. **`local-storage.yaml.skip`** in `/var/lib/rancher/k3s/server/manifests/` — the deploy
   controller ignores the manifest. Verified in k3s source (`pkg/deploy/controller.go`): a
   skipped file is a `continue`, nothing else. Already-deployed objects are untouched.
2. **`extra-manifests/local-path-provisioner.yaml.tpl`** — a vendored copy of k3s' own
   manifest with the annotation already `"false"`, generated by
   `scripts/vendor-local-path.sh`. This is the shape of fix k3s' maintainers recommend
   (k3s-io/k3s#4083: *"provide your own copy of the local-storage manifest"*).

The skip is written in two places because they cover different nodes: the kustomize deploy
commands handle nodes already running (which never re-run cloud-init), and
`postinstall_exec` handles every new or rebuilt one — including autoscaled nodes.

### Why not `--disable local-storage`

It is the documented option and it is wrong *here*. `--disable` calls the deploy
controller's `delete()`, which applies an **empty owned object set** — it removes the
StorageClass, the provisioner Deployment, the ConfigMap, the ServiceAccount and the RBAC.
On a cluster with workloads on local-path that is an outage, not a configuration change.
On a genuinely empty cluster it is a fine choice.

There is also advice in circulation to edit
`/var/lib/rancher/k3s/server/manifests/local-storage.yaml` directly. That does not work:
k3s rewrites packaged manifests on startup.

### The cost, and the procedure that pays it

**k3s no longer updates local-path-provisioner. This repository does.** It is pinned at
whatever `scripts/vendor-local-path.sh` last generated.

After a k3s minor upgrade:

```bash
./scripts/vendor-local-path.sh "$(kubectl version -o json | jq -r .serverVersion.gitVersion)" --check
```

If it reports stale, re-run without `--check`, read the diff, and apply. The generator
performs exactly four transformations and lists them in the file header, so the diff
against a new upstream is reviewable rather than a memory test.

### Verifying it, at the level that matters

Test the outcome, not the mechanism — this runs the real admission plugin and writes
nothing:

```bash
kubectl apply --dry-run=server -o json -f - <<'EOF' | jq -r '.spec.storageClassName'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: default-class-probe, namespace: default}
spec:
  accessModes: ["ReadWriteOnce"]
  resources: {requests: {storage: 1Gi}}
EOF
```

It must print the replicated CSI class. Also useful:

```bash
kubectl get sc                                            # exactly one (default)
kubectl get sc local-path -o json --show-managed-fields   # manager must not be deploy@…
```

That last one is the real proof: while `deploy@…` still appears as a field manager, k3s is
still in charge and the fix has not taken.

### Proving the skip still works, without restarting k3s

The deploy controller re-scans every 15 seconds, but a re-apply needs the manifest's
**content checksum** to change — `deploy()` returns early when the checksum matches what
the Addon recorded. So `touch`ing the file proves nothing: it moves the timestamp past the
first gate and then stops at the checksum. Appending a comment line does change the
checksum, and that is a valid trigger.

Run the negative control first, or a passing result means nothing:

```bash
M=/var/lib/rancher/k3s/server/manifests
sc() { kubectl get sc local-path \
  -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'; }

# NEGATIVE CONTROL — skip removed, content changed. Expect "true" within ~45s.
mv $M/local-storage.yaml.skip $M/.parked && echo '# probe' >> $M/local-storage.yaml
sleep 45; sc

# restore, then repair the annotation through Terraform so the field manager is right
mv $M/.parked $M/local-storage.yaml.skip
terraform apply -target=kubernetes_annotations.local_path_not_default

# POSITIVE — skip in place, same change. Expect "false".
echo '# probe' >> $M/local-storage.yaml
sleep 45; sc
```

Restore the manifest afterwards (k3s rewrites it on the next start anyway).

Measured on 2026-08-09: negative `true`, positive `false`.

**What this does and does not prove.** It exercises the checksum-mismatch path. A real k3s
restart takes the *force* path, where the checksum comparison is skipped entirely — but
both reach the same `shouldSkipFile` check, and that check runs before either, so the
result carries. Confirming it after a genuine restart still costs nothing and is worth
doing the next time one happens.

---

## 6. Dead man's switch: noticing from outside that the cluster stopped reporting

> **Status: written, not carried out.** This section is the *procedure*. As of 2026-08-23
> no such rule exists, and nothing outside this cluster observes it. Until somebody works
> through the steps below and records the date in "Verifying it", the gap described in the
> next paragraph — and in `docs/managed-k8s-parity.md` §3.3 — is still open. Do not read
> the existence of this section as the existence of the control.

Alert evaluation runs on the cluster. Every rule you write, and every notification it
would send, depends on a pod that lives on a node inside the thing being watched. When
that node stops, nothing evaluates and nothing pages — and the rule that would have told
you so is one of the rules that stopped. `docs/managed-k8s-parity.md` §3.3 reaches the
same gap from the other side and names the compensation without shipping it: "alert on
NotReady from outside the cluster".

### The mechanism, and why it is not another exporter

Prometheus already writes a filtered copy of its series outward, to a hosted Prometheus,
over remote write. The observer you need is therefore not a new component: it is **one
alert rule in the hosted system that fires when those series stop arriving**. Nothing
about it runs on the cluster, so the cluster cannot take it down with itself.

**The better-known form of this, and why this is not it.** The Prometheus convention is a
`Watchdog` alert — a rule whose expression is `vector(1)`, so it fires permanently, routed
to an outside service that raises an incident when the stream of notifications stops.
Silence is the failure signal. That form needs Alertmanager to be alive to keep sending,
so it detects a dead Alertmanager but leans on a third-party dead-man's-switch service.
The form below inverts it: the *query* looks for absence, in a system that already
receives your data, so it needs no extra account and it survives Alertmanager being dead
too. If you already pay for a dead-man's-switch service, the `Watchdog` form is less
work; if you do not, this one costs nothing further.

### Step 0 — the access precondition

The whole value of this control is being reachable when the cluster is not, so establish
before anything else, and write the answers down where the on-call person can reach them:

- which hosted account receives the remote write, and whether it is in good standing;
- that you can sign in to it **today** — not that you could once;
- where that credential lives, and who else can reach it.

An account you cannot log into is not an observer. If step 0 fails, stop here: the rest of
this section is unbuildable, and the honest state of the system is that nothing outside
the cluster is watching.

### Prerequisites, checked before the rule is written

Three checks. A rule written against a series that never arrives fires immediately and
permanently, which is worth less than no rule at all, because it also trains you to
ignore it.

1. **The series `up` survives your write filter.** The remote write block normally carries
   a `keep` relabel action listing the metric families worth exporting, because a free
   tier has an active-series cap and `node_*` alone would exceed it. Confirm `up` is one
   of them. It costs one series per scrape target. (The key is `write_relabel_configs`
   under `remote_write` in raw Prometheus configuration, and `writeRelabelConfigs` under
   `remoteWrite` in the Prometheus Operator CRD — grep for whichever your deployment
   actually uses.)

2. **The write is succeeding right now.** From inside the Prometheus pod:

   ```bash
   # expect 0
   wget -qO- 'http://localhost:9090/api/v1/query?query=rate(prometheus_remote_storage_samples_failed_total%5B10m%5D)'
   # expect a number that is larger the second time you run it
   wget -qO- 'http://localhost:9090/api/v1/query?query=prometheus_remote_storage_samples_total'
   ```

   A zero failure rate on its own proves nothing: it is also what you get when nothing is
   being sent. The pair of reads is the check, not the first one.

3. **The selector the rule will use actually resolves on the other side.** This is the one
   that matters, and it is the one that is easy to skip, because the first two look like
   they cover it. They do not: both are read from inside the cluster and prove only that
   samples left without error. Neither proves that a series matching the rule's exact
   selector is queryable in the hosted store.

   In the hosted Grafana, open **Explore**, select the data source that receives your
   writes, and run:

   ```promql
   count(up{job="prometheus"})
   ```

   Expect a number ≥ 1. If it returns nothing, the label value is wrong for your
   deployment — `job="prometheus"` is what a self-scrape job is called here, but a stock
   kube-prometheus-stack names it after the generated ServiceMonitor instead. Fix the
   selector now and use the fixed one in the rule below. This check subsumes both of the
   others for the rule's purposes; keep them anyway, because they tell you *which* half is
   broken when this one fails.

If any of the three fails, stop and fix it. None has a degraded form still worth writing
the rule against.

### The rule

In the hosted Grafana: **Alerts & IRM → Alert rules → + New alert rule**. (Older Grafana
calls the top-level section **Alerting**; if the navigation does not match, that is why.)

1. **Query A**, data source = the hosted Prometheus that receives your writes. **Set the
   query type to `Instant`** — this is not optional and it is the step most likely to be
   skipped, because the form defaults to a range query. A threshold needs one number per
   series; a range query hands it a series, and you get either a rule stuck in Error or a
   condition that means "some point in the window was below 1", which is a different and
   much twitchier rule than the one described here. If you would rather leave the query as
   a range, then you must put a **Reduce** expression with the `Last` reducer between the
   query and the threshold — `Last`, not `Min`, or any single gap in the window fires.

   In code mode:

   ```promql
   count(up{job="prometheus"}) OR on() vector(0)
   ```

   The `OR on() vector(0)` is the load-bearing half. `count()` over a selector that matches
   nothing returns an empty vector, and the fallback turns that into the number 0 so the
   threshold has something to compare. Grafana would otherwise treat it as no data, which
   is not silent — see step 4 — but produces a synthetic alert instance carrying different
   labels and none of the summary you write in step 6. Keeping the expression on the normal
   path is the point. (The `on()` is inert here, both sides being label-less; it is written
   out because it is what makes the construction read unambiguously.)

2. **Condition**: a Threshold expression on A, **IS BELOW 1**.

   Three states, one condition: series arriving → `count()` ≥ 1 → Normal. Series never
   present → `vector(0)` → fires. Series arrived and stopped → `vector(0)` once they go
   stale → fires.

3. **Evaluation**: a new folder and evaluation group, evaluate every `1m`, **pending
   period `10m`**.

   **Know what that actually buys you, because it is not ten minutes.** An instant query
   resolves a selector by looking back up to the data source's lookback delta, which
   defaults to **5 minutes** in both Prometheus and Mimir (what backs Grafana Cloud). When
   ingestion stops at T, the hosted store keeps answering with the last sample it received
   until roughly T+5m; only then does the expression fall through to `vector(0)` and the
   pending period start. Real time to firing is therefore

       lookback delta + pending period + up to one evaluation interval  ≈  5m + 10m + 1m

   — about **16 minutes**, plus whatever group wait the contact point adds. Size the
   pending period knowing that, and use the sum, not the pending period, everywhere you
   state a detection time.

   Ten minutes is chosen to sit above a pod roll, a node reboot and a scrape gap. That is a
   judgement, not a measurement: nothing here has timed how long remote write is actually
   interrupted by a Prometheus restart on a network volume, where a volume detach and
   attach plus WAL replay can run long. The lookback delta adds five minutes of accidental
   headroom on top. If you have a measured number, put it here and replace this paragraph.

4. **Configure no data and error handling**: no data → **Alerting**; execution error →
   **Alerting**.

   Both defaults already notify — Grafana's are `No Data` and `Error`, which emit firing
   instances named `DatasourceNoData` and `DatasourceError`. Mapping them to Alerting is
   not about breaking silence; it is about routing and content. Those synthetic instances
   carry substituted labels, so a notification policy that routes on this rule's labels can
   miss them, silences on this rule do not apply to them, and they arrive without the
   summary you write in step 6.

5. **Contact point**: one whose delivery does not depend on anything in the cluster. Note
   the distinction — an external phone or paging *service* is fine and is probably the
   right answer even if the cluster's own Alertmanager already sends to it. What must not
   be in the path is a *sender* that lives on the cluster: its Alertmanager, or mail
   relayed through a smarthost running there. Send to the service directly from the hosted
   Grafana.

6. **Summary**: state what it means and what it does not distinguish — "no metrics have
   arrived for at least 15 minutes; the cluster, its network egress, or its monitoring
   stack is down". The person reading it will not reconstruct that at the time.

### Capture the rule where the rest of the system lives

Everything else here is in version control; this rule would be a set of clicks in somebody
else's tenant, and it is the one control designed to outlive the cluster. Export its
provisioning definition (Grafana's alert-rule export, YAML or JSON) and commit it beside
this runbook, together with the folder and evaluation group it belongs to. A hosted tenant
that gets reset, or an account that moves, should cost you a re-import and not a
re-derivation.

### What it proves, and what it does not

- It proves that node, container runtime, Prometheus, egress and credentials were all
  working within the last quarter of an hour. That is a great deal of coverage for one
  rule. It does **not** prove the kubelet was healthy: a wedged kubelet leaves running
  containers running, so Prometheus can keep scraping itself and writing outward across a
  kubelet outage.
- It cannot say **which** of those failed. It is a starting gun, not a diagnosis.
- It says nothing about a cluster that is up while its workloads are broken. The
  on-cluster rules cover that case, and they only work while the cluster is up. The two
  sets are complements, and neither substitutes for the other.
- If the hosted account lapses or its ingestion quota is exceeded, writes fail and this
  rule fires while the cluster is perfectly healthy. That is not a false positive — you
  have genuinely lost the observer — but it is worth telling apart from a dead cluster.
  **Do not try to tell them apart with the counter from prerequisite 2.** That read runs
  inside the Prometheus pod, and in every scenario this rule fires that pod is unreachable
  or gone; asking for it is asking you to query the thing whose silence paged you. The
  distinguishing signal has to come from outside: the hosted account's own ingestion or
  usage view, its billing state, or an independent reachability probe against a public
  endpoint. If `prometheus_remote_storage_samples_failed_total` is in your write filter's
  keep list, you can query it from the hosted side and that is the fastest answer; if it is
  not — and it is not here — say so, and reach for the account view instead.

### Verifying it, which is the step that gets skipped

An untested dead man's switch looks exactly like a working one, which is the failure mode
it exists to prevent. Test it once, deliberately:

- **Stop the writes for longer than the lookback delta plus the pending period** — with the
  values above, more than 15 minutes, and give it 20. Waiting only for the pending period
  is the classic botched test: the rule sits in Normal and you conclude it is broken.
- **Prefer breaking the destination to stopping Prometheus.** Pointing `remoteWrite.url` at
  a host that does not resolve leaves scraping running, the WAL buffering and all
  on-cluster rules evaluating. Scaling the Prometheus workload to zero also silences every
  in-cluster rule for the duration, so a real incident inside the window is invisible and
  the recovery produces a burst of notifications afterwards. If you do scale it to zero,
  say so to whoever is on call first.
- **Go through git.** A GitOps controller with self-heal reverts a live `kubectl` edit
  within seconds, and you will conclude the rule does not work when what failed was the
  test.
- **Watch the rule move Normal → Pending → Alerting**, and confirm the contact point
  actually delivered. Delivery is a separate failure surface from evaluation and is not
  implied by a red rule in the UI.
- **If it does not move**, work the three in order before touching the rule: run the
  section's query in Explore and check it returns 0 rather than nothing; check the rule's
  state history and its last evaluation timestamp to confirm it is evaluating at all; and
  check that the writes really stopped, from the hosted side rather than from the cluster.
- **Put it back, and record the date here.** Re-test after any change to the write filter,
  the credentials or the contact point — **and on a fixed calendar interval regardless**,
  six months being a reasonable default. The event-triggered re-tests only cover failures
  somebody causes. The ones that actually kill a hosted free-tier observer are an account
  lapse, a quota change, a tenant suspension, an expired token or a product sunset, and
  nobody schedules those.

  Last verified end to end: **never**.

### If the hosted route is unavailable

Any always-on machine outside the cluster can probe a public endpoint on a timer and push
to a notification service when the probe fails. It is a weaker observer — it sees
reachability, not whether alert evaluation is still happening — and it moves the single
point of failure onto that machine. It needs no account, and it is not nothing. Say which
of the two you have; do not let a reader assume the stronger one.
