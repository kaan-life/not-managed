# Variant: ha

> **Draft quickstart, and a stronger warning than the one on `solo`.** This variant has
> **never run a production workload.** It was authored in this repository, derived from
> the variant that does. It is verified as far as a green-field build verifies anything:
> it boots, it passes its smoke tests, a control-plane node was killed and etcd was
> restored. Everything beyond that — behaviour under real load, over months, during an
> incident — is unproven, and this README will say so until it isn't.

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
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
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
