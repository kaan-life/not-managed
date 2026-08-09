# Variant: solo

> **Draft quickstart.** Written before the green-field build that verifies it. Every step
> below is either exercised in the running cluster this variant was derived from, or
> reasoned from the code — but the sequence as a whole has not yet been run start to
> finish by someone with no prior knowledge. That run is what turns this into the real
> README, with measured timings and whatever manual repairs it needed.

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
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519

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
