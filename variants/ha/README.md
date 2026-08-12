# Variant: ha

> **Draft quickstart, and a stronger warning than the one on `solo`.** This variant has
> **never been applied to anything.** It was authored in this repository, derived from the
> variant that runs a real workload, and at the time of writing it has been verified only
> by static means: `terraform validate`, and a plan that resolves the full 46-resource
> graph against an empty state.
>
> It has **not** been booted. The control-plane kill and the etcd restore that this design
> exists to survive have **not** been executed. Until they have, treat every availability
> claim here as a design intention rather than a measurement — and read the `solo` variant
> if you need something whose failure modes are known.

Three control planes across two datacentres, three general-purpose agents, a cluster
autoscaler, a dedicated CI node, a dedicated egress node, and a redundant NAT router.
Same architecture as `variants/solo`, different operating point.

## Choose this variant if

- the Kubernetes API has to survive losing a node — with one control plane, a reboot
  stops scheduling, self-healing, GitOps sync and every `kubectl`, even though running
  pods carry on;
- you need to be able to **drain** a worker, for an upgrade or to move a workload. That
  is not a configuration flag, it is spare capacity: `solo` cannot do it, and this
  variant can only do it because of the third agent;
- one datacentre going away should cost you availability, not the cluster.

Choose `variants/solo` if none of those are true. This one costs about **1.4×** as much
before any autoscaling, and roughly 1.8× with the autoscaler at its configured ceiling.
Three control planes are three things to patch, not one.

## What differs from `solo`, and what each difference buys

| Change | Buys | Costs |
|---|---|---|
| 3 control planes, split 2 + 1 across locations | API survives losing one node; quorum survives losing one member | +2 × cx23; you still operate etcd, and losing the *primary* location still costs the cluster |
| 3 general agents instead of 2 | a drain has somewhere to put the pods | +1 × cx33 |
| `system_upgrade_use_drain = true` | pods move off a node before it is upgraded, instead of riding out a restart | only safe while the headroom above exists |
| Autoscaler `max_nodes = 3` | Pending pods get a node in under three minutes | up to +3 × cx33 when it fires |
| Redundant NAT router | egress and the forwarded API port survive losing one router | +1 × cx23, **and egress leaves from a different public IP after failover** |
| `etcd-arg` heartbeat/election tuning | etcd tolerates the hop between datacentres without election storms | a longer election timeout means a longer stall when a leader genuinely dies |

`docs/variant-delta.md` is the exact diff. `docs/cost-comparison.md` has the measured
prices behind the numbers above.

## The decision this variant asks you to make

`secondary_location` defaults to a datacentre in the same country as `primary_location`,
not a distant one, and that is the interesting choice in the whole design.

Geographic separation and etcd performance pull in opposite directions. A second site
across the continent survives a regional event; it also puts tens of milliseconds between
etcd members, and every write that needs the third member pays it. Get the heartbeat and
election timeouts wrong for that distance and the failure is not a crash — it is a leader
election storm, where members declare the leader dead over a late heartbeat, elect a new
one, and repeat, while the API stalls for seconds at a time and nothing looks broken.

The default trades regional survivability for single-digit latency: a different building,
different power, different network, a few milliseconds away. **Measure your own
round-trip time before choosing differently**, and raise the `etcd-arg` values in
`main.tf` to match if you do.

## Prerequisites and build

Identical to `variants/solo` — same tools, same accounts, same two-pass build for the
tailnet address (`docs/RUNBOOK.md` §2). Only the two location inputs are extra, and both
have defaults:

```bash
cp secrets.auto.example.tfvars secrets.auto.tfvars && chmod 600 secrets.auto.tfvars
cp backend.hcl.example backend.hcl
$EDITOR secrets.auto.tfvars backend.hcl
eval "$(ssh-agent -s)" && ssh-add <the private half of ssh_public_key_path>
bash init.sh
```

> **Use a different `key` in `backend.hcl` from any other cluster.** Two clusters sharing
> a state key will fight over it and destroy each other's resources. The backend is
> partial precisely so this is a decision you make rather than inherit.

### Extra step: verify quorum before you trust it

Three control planes that never formed a quorum look exactly like three control planes
that did, until the first failure. After the build:

```bash
kubectl get nodes -l node-role.kubernetes.io/control-plane
# expect 3, all Ready, across two locations

kubectl -n kube-system exec -it <a control-plane pod> -- \
  etcdctl endpoint status --cluster -w table
# expect 3 members, exactly one leader, and RAFT INDEX values within a few of each other
```

A member that is persistently behind on raft index is a member that will not save you.

## What this variant still does not give you

Fewer than `solo`, but the list is not empty, and every item is structural rather than an
omission:

- **No managed control-plane SLA.** Three control planes are three you maintain.
- **No node auto-repair.** The autoscaler replaces nodes it manages; the static pools
  have no health-driven replacement anywhere in kube-hetzner 2.19.2. A NotReady static
  node stays NotReady until a human acts. Alert on it.
- **Not true surge upgrades.** k3s' system-upgrade-controller never adds a node before
  removing one, and a failed upgrade has no automatic rollback. Headroom emulates surge.
- **No availability zones.** Hetzner has datacentres, not zones — a different, larger
  latency domain than the ~1 ms zones managed Kubernetes spreads across.
- **No workload identity.** Pods keep long-lived secrets.
- **One cloud account** remains a single point of failure for everything in it.

`docs/managed-k8s-parity.md` accounts for all twelve capabilities, including the six no
self-hosted stack can match.

## What a first run actually needed

This variant has been built from a clean checkout on an empty project. Every item below is
something that first run had to work around, in the order it came up. None of them is a
defect you should have to rediscover.

**Before `terraform plan` will even run**

1. **Build the Packer snapshot first.** The image data sources are evaluated at *plan*
   time, not apply time, so a plan against a project with no snapshot fails outright.
   `init.sh` does this in the right order; if you drive Terraform by hand, do it yourself.
2. **`etcd_s3_endpoint` must be a bare host** — `fsn1.example.com`, never
   `https://fsn1.example.com`. `variables.tf` rejects a scheme at plan time now, and the
   reason that validation exists is worth reading in `docs/RUNBOOK.md` §4: with a scheme,
   snapshots keep *saving* and only the *restore* breaks.

**Before the first apply will succeed**

3. **`firewall_ssh_source` needs your own public /32**, not just the tailnet range.
   Terraform reaches the NAT router over its public address to run provisioners; with only
   `100.64.0.0/10` the apply hangs and then fails on `dial tcp …:22: i/o timeout`.
4. **`bootstrap_phase = true` for the first apply, false afterwards.** The tailnet address
   the API certificate needs does not exist until the control plane has joined the tailnet.
   `docs/RUNBOOK.md` §2 explains the two passes; the flag exists so it is one decision.
5. **`tailscale_advertise_routes` must differ per cluster** if you put two clusters from
   this repository on one tailnet. Every node advertises it — the line is in
   `preinstall_exec` — so two clusters contest the same prefix and Tailscale elects one
   primary for it. Give the second cluster its own range, or set the list to `[]` and
   reach it by node address.

**Failures you may hit that are not your configuration**

6. **`error during placement (resource_unavailable)`.** A *spread* placement group needs a
   distinct physical host per server, and a busy location may not have enough free at that
   moment. Two things that do **not** fix it: the server type (a standalone server of the
   same type places fine) and lowering `-parallelism` (measured 2026-08-12: it failed with
   `-parallelism=1` as well). What works is fewer servers in the group, another location,
   or waiting.

**After the cluster is up**

7. **A private companion GitOps repository cannot sync until the ArgoCD repository
   credentials exist**, and those are created in the phase that runs *after* the cluster
   (`terraform_data.github_secrets` → a `repo-creds` secret). Until then ArgoCD reports
   `failed to list refs: authentication required: Repository not found` — which is the
   *same* message GitHub returns for a `repoURL` that does not exist at all. Two very
   different causes, one string; check the secret before you go looking at the URL.
8. **Namespace names must equal the companion repository's top-level directory names.**
   The root ApplicationSet sets `path: {{environment}}` from
   `utility_namespaces + app_namespaces`. A namespace with no matching directory produces
   an Application stuck on `ComparisonError: <name>: app path does not exist` — and it
   reports `Healthy` while doing so, because an Application with zero resources is
   trivially healthy. Never read the health column alone.

**When you tear it down**

9. `terraform destroy` does not empty the project by itself, and it can hang for twenty
   minutes without naming why. Read the orphan and ordering notes in `docs/RUNBOOK.md` §4
   before you need them, and run `assert-no-orphans.sh` afterwards.
