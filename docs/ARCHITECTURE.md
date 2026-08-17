# Architecture

Six decisions that look strange until you know what they are for. Each one is in the
configuration with a comment beside it; this document is the version you can read
end-to-end before deciding whether the shape suits you.

Everything here describes `variants/solo`, the stack that runs in production, and notes
where `variants/ha` diverges. The mechanical difference between the two is
`docs/variant-delta.md`; the capability difference is `docs/managed-k8s-parity.md`.

---

## 1. The Kubernetes API is on a private overlay network, not on the internet

`firewall_kube_api_source` restricts the API to a Tailscale tailnet.
`control_plane_load_balancer_enable_public_network = false` removes the control-plane load
balancer's public interface entirely. (`docs/RUNBOOK.md` records how the old 2.19.2 name for
this input, `control_plane_lb_enable_public_interface`, was found not to exist in 3.1.0.)
Measured against the live API: **no node has a public IPv4 address except the NAT router.**

**Why.** Reachability becomes the first authentication factor. An attacker who steals a
kubeconfig still has to be on the tailnet to use it. Managed Kubernetes offers this as an
opt-in "private endpoint" and defaults to public; here it is the only mode, which is why
`docs/managed-k8s-parity.md` §3.9 records this as the one row where a self-hosted stack
*exceeds* the managed default.

**What it costs, stated plainly.** The design assumes a **trusted tailnet**, and its
provider is a third party sitting in the authentication path. If that provider is
unavailable, you cannot reach your cluster — and **there is no documented break-glass
path**. That is a real gap, not a rhetorical one, and it is named in `SECURITY.md` under
what is out of scope.

**One deliberate non-choice.** Inbound UDP 41641 — Tailscale's direct-connection port — is
**not** opened. A direct connection needs outbound UDP too, which would weaken
`restrict_outbound_traffic` for every node in the cluster. Relayed connections over DERP
are slower and cost nothing here, so the trade goes the other way. If you are running
latency-sensitive traffic over the tailnet, this is the line to revisit.

---

## 2. A NAT router, because the nodes have no public address

Nodes with no public IPv4 still need outbound traffic: image pulls, OS updates, the k3s
upgrade channel. A single `cx23` NAT router carries all of it.

**Three consequences worth knowing before you copy this.**

1. **It forces a second load balancer.** `nat_router` requires
   `enable_control_plane_load_balancer = true` (a hard precondition in the module, not just
   advice), so there is a control-plane LB in addition to the ingress one. That is €18.12/month,
   not €9.06 — a quarter of the idle bill, and easy to miss when reading the configuration.
2. **Enabling it rewrites the NAT router's cloud-init once.** With
   `control_plane_load_balancer_enable_public_network = false` the module forwards
   `kubernetes_api_port` to the private control-plane LB by itself — in 3.1.0 that is automatic
   and there is no input to set. It triggers a **one-time NAT-router rebuild**. The public
   address survives, because it is a separate stable primary-IP resource, and `kubectl` over
   the tailnet is unaffected. Expect it, and do not mistake it for drift.
3. **The forwarded API port is firewall-gated.** The resulting 6443 forward on the NAT
   router's public address is restricted to `firewall_kube_api_source`, so it is not publicly
   reachable. It is a forward, not an exposure — but it is the one place where "the API is
   not on the internet" depends on a firewall rule rather than on the absence of an address.

**It is a single point of failure**, and it takes both SSH and the API path with it when it
fails. `solo` sets `enable_redundancy = false`; `ha` enables it with a `standby_location`,
which is where the extra €6.64 in the cost comparison goes.

---

## 3. A dedicated egress node — declared, and parked at zero

Cilium's egress gateway is enabled, and an `egress` agent nodepool is declared: a `cx23`
labelled `node.kubernetes.io/role=egress` and **tainted** so nothing lands on it by
accident. **Since 2026-08-17 that pool ships at `count = 0`.** The comment above it in
`variants/*/main.tf` says why, and what to change to bring it back.

**Why the pool exists.** Third-party APIs that authenticate by IP allowlist need your
traffic to come from a predictable address. Without an egress gateway, a pod's source
address is whichever node it happened to be scheduled on, so an allowlist has to cover
every node — and break every time you add one. Pinning egress to one node makes the
allowlist a single entry that survives scaling.

**Why it is parked anyway.** With a `nat_router` present, egress already leaves through a
single predictable address — the NAT router's — so the gateway node buys nothing until you
have a workload that needs a *second*, different one. Running it unused was measured on the
source cluster: six pods, all DaemonSets, no `CiliumEgressGatewayPolicy` anywhere, and a
CPU peak of 0.49 of 2 cores over three days of retention. That is €6.64 gross per month for
a node whose only job was to be monitored.

**What turning it on costs.** One more server, `floating_ip = true` so it has an address of
its own, a `CiliumEgressGatewayPolicy` that selects it, and a taint you have to tolerate
deliberately in any workload that needs the stable address. That last part is a feature: it
means "this workload's source IP matters" is written down in the workload, not remembered.

---

## 4. kured, with the reboot window as the load-bearing part

The nodes run openSUSE MicroOS, which is **transactional**: updates are staged into a new
snapshot and take effect **on reboot**. Something has to reboot the nodes or the updates
pile up invisibly, and the cluster looks patched while running the old snapshot.

kured does the rebooting, with:

| Option | Value | Why |
|---|---|---|
| `start-time` / `end-time` | 03:00–05:00 | reboots land when nobody is watching |
| `drain-timeout` | 5m | a pod that will not evict does not hold the window open |
| `force-reboot` | true | ...and the reboot happens anyway |
| `lock-ttl` | 30m | a node that dies mid-reboot cannot hold the cluster-wide lock forever |

**The k3s upgrade window is 01:00–03:00, ending exactly where kured's window starts.** That
adjacency is deliberate. Overlapping them risks system-upgrade-controller cordoning a node
at the same moment kured wants to reboot that same node. Upgrade first, reboot after.

**The cost is that both windows are published**, here and in `SECURITY.md`. A known
maintenance window is a known weak moment. It is still the right trade: the alternative is
disruption at an arbitrary time, which is worse in every way except secrecy.

---

## 5. k3s upgrades cordon instead of drain

`system_upgrade_use_drain = false`. The node is cordoned, k3s is upgraded in place, the
node is uncordoned. Pods experience an agent restart rather than a migration.

**Why, concretely.** With two schedulable nodes, a drain has nowhere to put the pods. On
2026-08-05 an upgrade drained an agent that could not be emptied and left it cordoned for
**two and a half hours with eight pods Pending**. Upstream's own guidance points the same
way for small clusters: pods that resist eviction keep the node unschedulable indefinitely.

**Why the disruption is acceptable.** An agent restart is not a new class of event here —
kured already stops those same pods every night with `--drain-timeout=5m --force-reboot=true`.
The upgrade is not introducing a risk the cluster does not already take daily.

**This is a mitigation, not a fix, and the configuration says so.** The fix is enough
capacity to empty a node: a third worker, static or autoscaled. That is precisely what
`ha` buys, and it is why the upgrade-window row in the parity matrix is split — the window
goes in `solo` for free, the headroom costs €10.27 and goes in `ha`.

**A trap on the way there.** Agent pools are keyed by **list index**. Never delete a
zero-count pool to make room in the list: removing one rebuilds every pool after it. Add
capacity by changing a count, or by appending.

---

## 6. This repository owns local-path-provisioner, k3s does not

k3s ships local-path-provisioner as a packaged component and re-applies it **on every
start** — not on version upgrades, which is the intuitive and wrong assumption, but on
every start: a config change, a node reboot, a crash. Each re-apply resets
`storageclass.kubernetes.io/is-default-class` to `true`, leaving the cluster with **two**
default StorageClasses.

Kubernetes tolerates two defaults and gives a class-less PVC the most recently created one.
But "which volume you get depends on object creation order" is not a property to run
storage on, and repairing it at apply time means `terraform plan` is dirty after every
reboot — which teaches people to stop reading plans, and that is the real damage.

The answer is the one k3s' own maintainers recommend ([k3s-io/k3s#4083](https://github.com/k3s-io/k3s/issues/4083)):
stop letting k3s own it. A `.skip` file stops the deploy controller touching the manifest,
and `extra-manifests/local-path-provisioner.yaml.tpl` is a vendored copy with the
annotation already `false`.

Not `--disable local-storage`, which reads like the obvious answer: k3s implements that by
applying an **empty owned set**, which deletes the StorageClass, the provisioner, the
ConfigMap, the ServiceAccount and the RBAC. Correct on an empty cluster, an outage on one
with workloads already on local-path.

**The cost, stated plainly: k3s no longer updates local-path-provisioner — this repository
does.** `scripts/vendor-local-path.sh` regenerates the manifest from any k3s tag and has a
`--check` mode, so re-syncing after an upgrade is one command and a reviewable diff. CI
runs that check. `docs/RUNBOOK.md` has the procedure.

---

## Why there is no shared module between the variants

`variants/solo` and `variants/ha` are independent copies, roughly 1700 duplicated lines,
and that is deliberate. A root configuration with a `backend` block, provider
configuration and shell scripts is not a reusable child module, and factoring one out
would make the whole thing a dependency rather than something you fork and edit.

The duplication is fine while it is **visible** and fatal once it is not, so
`docs/variant-delta.md` is a committed, generated diff between the two directories, and CI
fails when it goes stale. A change made to one variant and forgotten in the other shows up
there, in the pull request that caused it.

The reasoning is in `docs/adr/0002-reference-architecture-not-module.md` and
`docs/adr/0007-two-forkable-variants-one-repository.md`. Both were revisited and both held.
