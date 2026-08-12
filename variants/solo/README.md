# Variant: solo

> **This variant has been built green-field from this tree**, twice, on an empty project —
> most recently on 2026-08-12, when it was also used to prove that the companion GitOps
> repository reconciles end to end. What that build needed beyond the steps below is
> written down: see **"What a first run actually needed"** in
> [`../ha/README.md`](../ha/README.md). Eight of its nine items apply to this variant
> unchanged; the ninth (`nat_router_hcloud_token`) is `ha`-only.
>
> What has *not* happened yet is the test that matters most for a quickstart: nobody
> unfamiliar with this repository has walked it start to finish. Until that happens, treat
> the ordering as verified and the *explanations* as unproven — the author knows too much
> to notice what is missing.

One control plane, two general-purpose agents, a dedicated CI node, a dedicated egress
node, and a NAT router. The Kubernetes API is reachable only over a Tailscale tailnet;
no node has a public IPv4 except the NAT router.

**This is the variant that runs a real workload.** Everything in it exists because
something happened: the pinned CSI version is there because an older one reformatted a
production database volume during a node failover; the kured tolerations patch is there
because two nodes silently stopped rebooting for three days; `system_upgrade_use_drain`
is `false` because a drain with nowhere to put the pods cordoned a node for two and a
half hours. The comments explain each one. Read them before deleting a line.

## Choose this variant if

- one operator, one cluster, and a control-plane restart is an inconvenience rather than
  an incident;
- the bill matters (this is roughly 70 % of the cost of the `ha` variant before any
  autoscaling);
- you can tolerate the API being unavailable while a single control plane reboots — pods
  keep running, but scheduling, self-healing, GitOps sync and every `kubectl` stop.

Choose `variants/ha` instead if you need the API to survive losing a node or a
datacentre, or if you need to be able to drain a worker. See the root README for the
side-by-side table.

## Prerequisites

| | |
|---|---|
| Terraform | ≥ 1.10 (`required_version = "~> 1.10"`) |
| Packer | required for the first build only — `init.sh` builds the MicroOS snapshot |
| A Hetzner Cloud project | with a read-write API token |
| S3-compatible object storage | two buckets: Terraform state and etcd snapshots. **Enable versioning on the state bucket.** |
| A Tailscale tailnet | plus an auth key; the kube-API is served only there |
| A GitHub organisation | with an App (for ArgoCD repo access) and an OAuth App (for SSO) |
| A companion GitOps repository | see `docs/adr/0008` — or set `SKIP_TEKTON_BOOTSTRAP=1` |
| A domain | with DNS you control, for the ArgoCD ingress |
| `kubectl`, `hcloud`, `python3`, `git` | on the machine running Terraform |

## Build

```bash
# 1. Inputs. Every variable without a default must be set — there are 25 of them, and
#    the identifiers among them deliberately have no defaults so that a fork cannot
#    inherit somebody else's domain, bucket or GitHub team.
cp secrets.auto.example.tfvars secrets.auto.tfvars
chmod 600 secrets.auto.tfvars
$EDITOR secrets.auto.tfvars

# 2. Which state store to use. providers.tf declares a PARTIAL backend and names no
#    bucket, so init fails until you say. Create the bucket first, with versioning.
cp backend.hcl.example backend.hcl
$EDITOR backend.hcl

# 3. The GitHub App private key, at the path named in secrets.auto.tfvars.
cp ~/Downloads/your-app.private-key.pem secrets/your-github-app.pem
chmod 600 secrets/your-github-app.pem

# 4. An ssh-agent holding the private half of ssh_public_key_path. The key is
#    deliberately never given to Terraform — it would be written into the state in
#    cleartext — so provisioners get it from the agent instead.
eval "$(ssh-agent -s)" && ssh-add <the private half of ssh_public_key_path>

# 5. Build.
bash init.sh
```

### The build takes two passes, and the first one looks like a failure

`kube_api_tailnet_address` is the control plane's address on your tailnet. Tailscale
assigns it when the node first joins, so on a cluster that does not exist yet **you
cannot know it in advance** — and it is required in the API server's certificate.

Set a placeholder inside `100.64.0.0/10`, leave
`control_plane_lb_enable_public_interface = true` in `main.tf`, run `init.sh`, then read
the assigned address, put it in `secrets.auto.tfvars`, set the flag to `false`, and
`terraform apply` again. Full procedure with the reasoning: **`docs/RUNBOOK.md` §2.**

Skipping this is why a green-field build fails on the first apply.

## Day two

```bash
terraform init -backend-config=backend.hcl
terraform plan     # read it. it is the only review that catches silent drift
terraform apply
```

`bash apply.sh` is the same thing with Packer and the phased apply skipped.

Two things in this configuration are hashed into Terraform state, so **editing a comment
is not always free**: the `helm_release` values block (comments inside it are chart
values) and anything under `extra-manifests/` or `scripts/` that is fingerprinted. A
`plan` after a comment-only edit may legitimately show work. That is the mechanism doing
its job — it exists so that editing a script actually deploys it.

## Tearing down

`destroy.sh` and `remove-protection.sh` both require `--project <name>`, prove the API
token belongs to that project, default to a dry run, and demand a typed confirmation.
`restore-protection.sh` puts delete protection back. Run them against a throwaway
project only.

> **A single `terraform destroy` does not empty the project, and it can fail without
> saying why.** Measured on this variant, 2026-08-12: the destroy hung twenty minutes on a
> network subnet and ended on `context deadline exceeded`, because an autoscaler node —
> which is never in Terraform state — was still attached to the network. Three CSI
> `pvc-*` volumes were left behind for the same reason: the driver created them, so
> Terraform never had them.
>
> Delete those by hand, re-run, and finish with an explicitly targeted destroy for the
> network, because a full one cannot even plan once the cluster is gone
> (`kubernetes_manifest` has no API to talk to). `docs/RUNBOOK.md` §4 has the commands and
> the ordering rule that goes with them — including: tear the cluster down **before** you
> delete the companion GitOps repository, never after.

## What this variant does not give you

Stated plainly, because a reader coming from EKS/GKE/AKS will assume otherwise:

- **No managed control-plane SLA** — there is nobody to page.
- **No node auto-repair.** A NotReady node stays NotReady until a human acts.
- **No drain headroom.** With two schedulable nodes there is nowhere to move pods to,
  which is why `system_upgrade_use_drain = false`.
- **A single NAT router** carrying all egress and the forwarded API port.
- **etcd is yours.** Backups run; the restore is a manual procedure.

`docs/managed-k8s-parity.md` accounts for all of it, row by row, with what it would cost
to close each gap.
