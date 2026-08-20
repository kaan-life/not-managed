# Managed Kubernetes parity

Twelve capabilities that EKS, GKE and AKS give you for the price of the control plane,
measured against what this repository actually configures. For each one: what the managed
service does, what `variants/solo` does today, what mechanism exists in the pinned module,
what closing it costs, and — the part that matters most — what stays open even after you
close it.

> **Version note, added 2026-08-17.** This study was run against **2.19.2**; the repository has
> since moved to **3.1.0** (`variants/*/main.tf`, and `NOTICE`). Every `Mechanism (2.19.2)` row
> below is therefore a historical label: it records the version a mechanism was verified in, and is
> deliberately not rewritten to 3.1.0, because that would claim a re-verification that has not
> happened. Where an input was *renamed* between the two, the current name is given alongside the
> old one — a reader copying a 2.19.2 variable name into a 3.1.0 configuration gets an error, and
> that is worth more than tidiness.

**Module under test:** `kube-hetzner/kube-hetzner/hcloud` **2.19.2**, read from the module
cache rather than from upstream documentation, so every "the mechanism exists" claim below
is a claim about the exact code this configuration runs.

**Method.** Every statement about cost was read from the Hetzner pricing API; every
statement about running state was read from the Hetzner API read-only, or out of the
configuration in this repository. Nothing here is inferred from a documentation page. No
write operation was performed to produce this document.

**One section was removed before publication.** The working version of this document
carried a measured baseline of the cluster it was written against — node names, addresses,
volume identifiers. That is operator-specific and is not published. Nothing is hidden by
removing it: every conclusion drawn from those measurements is stated in full below, the
cost half of it is published in `docs/cost-comparison.md`, and the topology it described is
the topology `variants/solo` declares, which you can read directly. Section numbering is
left as it was, because the variant configurations cite these rows by number.

---

## 1. Three things that measurement contradicted

Each of these looks settled if you read the configuration casually. Each would have
produced a wrong row.

### 1.1 "There are no placement groups" — there are, by default

The configuration contains a commented-out `# placement_group = "default"`, which reads
like an unused feature. Measured against the live API: two `spread` placement groups exist,
and every node except the NAT router is in one. kube-hetzner creates them **by default** —
`enable_placement_groups` defaults to `true` — and the commented-out line concerns
*fine-grained, named* group assignment, not whether groups exist at all.

The real residual gap is sharper and worth stating precisely: a Hetzner **spread** placement
group guarantees different physical hosts **within one datacentre**, capped at 10 servers
per group. It is not an availability-zone mechanism. So `solo` has anti-affinity; it does
not have multi-AZ.

### 1.2 "One load balancer" — there are two

`enable_control_plane_load_balancer = true` with
`control_plane_load_balancer_enable_public_network = false`, and the second load balancer is not
optional: the module enforces it. `nat_router` *requires* `enable_control_plane_load_balancer =
true` unless `node_transport_mode = "tailscale"` — a precondition that fails the plan, not a note
in the docs. (Both inputs were called `use_control_plane_lb` and
`control_plane_lb_enable_public_interface` in 2.19.2, when this study was run; 3.1.0 renamed
them.) Load-balancer cost is therefore **2 × €9.06 = €18.12/month**,
not €9.06. It is easy to miss when reading the configuration, and it is roughly a quarter of
the idle bill.

### 1.3 "No maintenance window for k3s auto-upgrade" was a gap in `solo`, not a feature `ha` had to buy

`automatically_upgrade_k3s = true` ran in no window at all. The mechanism to fix that —
`system_upgrade_schedule_window`, requiring system-upgrade-controller ≥ v0.15.0 — **exists in
2.19.2**. The configuration simply did not set it. That made it a **€0 fix assignable to
`solo`**, and it is now set (§3.4).

Related: `system_upgrade_use_drain = false` — the module's cordon-instead-of-drain knob — is
a *mitigation* for having no drain headroom, not a fix. The fix is a third schedulable node,
which is what `ha` buys.

---

## 2. Cost

Cost is measured, in its own document, and not repeated here: **`docs/cost-comparison.md`**
carries the unit prices read from the pricing API, both variants side by side, and the
autoscaler's worst case. In summary, `ha` idles at **1.44×** `solo`, and its `max_nodes` is
chosen as a budget ceiling rather than as a capacity wish.

The per-row **€ delta** figures in §3 are the marginal cost of closing that one row. They do
not sum to the difference between the variants, because several rows share hardware.

---

## 3. The matrix

Legend for the assignment column: **solo** = closed in the variant that runs in production ·
**ha** = closed in the HA reference variant · **both** · **neither** = no mechanism exists in
kube-hetzner 2.19.2, recorded as a finding rather than quietly omitted.

### 3.1 Control-plane HA and quorum → **ha**

| | |
|---|---|
| **EKS/GKE/AKS** | The control plane is managed, replicated across ≥3 zones, 99.95 % SLA. You never see etcd, never restore it, never size it. |
| **`solo` today** | One control-plane node. Two further control-plane pools are declared at `count = 0`. Losing the node does not stop running pods, but it stops scheduling, self-healing, Argo CD sync and every `kubectl`. |
| **Mechanism (2.19.2)** | Set the parked pools to `count = 1` → three control planes. `use_control_plane_lb = true` is already on (`enable_control_plane_load_balancer` in 3.1.0). etcd needs an odd member count ≥ 3 for quorum. |
| **€ delta** | **+€13.28** (2 × cx23) |
| **How `ha` does it** | Three members: two in `var.primary_location`, one in `var.secondary_location`, with `etcd-arg` heartbeat and election timeouts widened for the inter-datacentre hop. |
| **Residual gap** | You still operate etcd. Losing 2 of 3 members is unrecoverable without a restore. And a cross-location member is a real WAN hop: etcd is fsync- and heartbeat-sensitive, so a 2+1 split needs tuned election timeouts, or quorum stays in one location and multi-location buys availability of the *API*, not of *quorum*. `ha` therefore defaults `secondary_location` to a **nearby** datacentre and documents the distant one as a deliberate choice. **The round-trip time of the pair you actually build is a number to measure, not to inherit from this document.** |

### 3.2 etcd backup **and** a proven restore → **both**

| | |
|---|---|
| **EKS/GKE/AKS** | Not your problem. GKE and AKS additionally offer a managed cluster-backup add-on. You cannot restore etcd yourself and never need to. |
| **`solo` today** | `etcd_s3_backup` is configured, and the schedule is no longer the k3s default. Measured before changing it: no etcd-snapshot settings at all, so k3s' defaults applied — every 12 hours, keep 5, i.e. **RPO 12 h and ~2.5 days of retention**. Restore a Friday-evening mistake on Monday and the snapshot that predates it is already gone. Now `0 */4 * * *` with retention 42: **RPO 4 h, a rolling 7 days**. Sized against measurement rather than taste — snapshots are 40–51 MB, so 42 of them is ~2.1 GB against 13 GB free on a 39 GB control-plane disk. |
| **Mechanism (2.19.2)** | Backup: `etcd_s3_backup`. Schedule and retention: `etcd-snapshot-schedule-cron` and `etcd-snapshot-retention`, delivered through `control_planes_custom_config` rather than `k3s_exec_server_args` — exec args are baked into the *install* command, so they reach new nodes only and would leave a running control plane untouched. Restore: a documented k3s procedure, not a module feature. |
| **€ delta** | **€0** — object storage at these sizes is cents |
| **Residual gap** | The restore procedure is written (`docs/RUNBOOK.md`) but **executing it is what turns it from paper into proof**, and that has not happened yet. The two things that make a restore impossible if you discover them mid-incident are named there: the k3s join token and the snapshot bucket credentials. If both live in one file on one machine, your restore has a single point of failure your cluster does not. RTO is bounded by a human being awake. |

### 3.3 Node auto-repair → **neither** (structural)

| | |
|---|---|
| **EKS/GKE/AKS** | GKE node auto-repair drains and recreates an unhealthy node automatically; EKS managed node groups replace failed instances; AKS does node auto-remediation. No human in the loop. |
| **`solo` today** | **None.** A NotReady node stays NotReady until a human notices. That is not hypothetical: an agent went NotReady under memory pressure on 2026-06-13 and stayed there, which is why the kubelet system reservations exist in `variants/solo/main.tf`. |
| **Mechanism (2.19.2)** | **None for static nodepools.** The cluster autoscaler removes unregistered and long-unready nodes, but only for pools it manages (`autoscaler_nodepools`). Static pools have no health-driven replacement anywhere in the module. |
| **€ delta** | €0 — there is nothing to buy |
| **Residual gap** | **Unmatched, and honestly so.** Three compensations, none of which is auto-repair: alert on NotReady from outside the cluster (a monitoring concern this repository does not ship); put every replaceable workload on autoscaler-managed pools, which *do* get unready-node removal; and write a "replace a node" runbook with a measured time-to-recover. A forker who assumes GKE-like self-healing will be wrong, which is why this is in the README too. |

### 3.4 Node auto-upgrade and surge → **solo (window) + ha (headroom)**

| | |
|---|---|
| **EKS/GKE/AKS** | Surge upgrades: a replacement node joins *before* the old one drains (`maxSurge` / `maxUnavailable`), inside a maintenance window, with automatic rollback on failure. |
| **`solo` today** | `automatically_upgrade_k3s = true`, `automatically_upgrade_os = true`, kured reboots confined to 03:00–05:00 — and now a k3s upgrade window of **01:00–03:00**, deliberately ending where kured's window starts. Overlapping them risks system-upgrade-controller cordoning a node while kured wants to reboot that same node: upgrade first, reboot after. `system_upgrade_use_drain = false`, so pods are not moved off; the node is cordoned. There is **no surge** — no node is ever added first. |
| **Why the window is not the fix** | An upgrade once cordoned an agent for 2.5 hours and left 8 pods Pending, because with two schedulable nodes there was nowhere to put them. Windowing does not fix the capacity problem. It moves the disruption to a time when nobody is looking at it, which is worth doing and is not the same thing. |
| **Mechanism (2.19.2)** | `system_upgrade_schedule_window` · `system_upgrade_use_drain` · `system_upgrade_enable_eviction` · and, for anything resembling surge, **spare capacity**: a third schedulable agent so `use_drain = true` can succeed again. |
| **€ delta** | **solo: €0** (window only). **ha: +€10.27** (a third cx33 as drain headroom). |
| **Autoscaler nodes sit outside all of this** | Measured 2026-08-17 on the source cluster: `transactional-update.timer` is `disabled` and `inactive` on the autoscaler-created node, and `enabled` and `active` on every static agent. No timer means no MicroOS transactional-update, which means no reboot sentinel, which means kured never reboots it — even though kured *runs* there and tolerates its taint. The node had been up **137 hours** against 12–13 for every other node, and was the only one still on kernel `6.19.5-2-default` while the rest had moved to `7.1.8-1-default`. `automatically_upgrade_os = true` therefore covers the static pools and not this one. Note that `min_nodes = 0` does not make an autoscaler node short-lived: this one stayed up for five days because it stayed busy. |
| **…and why, established 2026-08-18** | The module's shared cloud-init runcmd disables the timer for the duration of first boot — correct in itself, since an update running mid-bootstrap can race the k3s install. Re-enabling it happens in exactly one place, `terraform_data.os_upgrade_toggle` in `modules/host`, which is keyed on `hcloud_server.server.id`. Autoscaler nodes are not `hcloud_server` resources — the cluster autoscaler creates them from a rendered `cloudInit` blob — so that toggle can never run for them. Reported upstream as [kube-hetzner#2266](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/issues/2266), with a proposed fix in [#2267](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/pull/2267). **Be precise about the claim:** the timer most likely still fires once during first boot — the same runcmd deletes `/var/run/reboot-required` immediately after disabling it, which only makes sense if a sentinel can already exist — so it is one first-boot update whose result is discarded, then nothing, rather than "never patched". |
| **A causal link this document used to imply, and should not** | An earlier revision noted that the unpatched node was also the only one with repeated container-runtime stalls, which reads as though being unpatched caused them. That is probably wrong. A static node created later ran the same `6.19.5` kernel from the same snapshot and did not stall, while the stalling node carried 63 of ~110 pods on 4 vCPU. The measurable precursor is the kubelet's own housekeeping loop: `Housekeeping took longer than expected` at 1.4 s nineteen seconds before the first stall, and at **46.4 s** before a later episode in which the container runtime never went down at all. Load explains it; patch level does not. |
| **Residual gap** | k3s' system-upgrade-controller has no true `maxSurge`; headroom emulates it. An upgrade that fails mid-way has no automatic rollback — manual recovery belongs in the runbook. |

### 3.5 Cluster autoscaler → **ha**

| | |
|---|---|
| **EKS/GKE/AKS** | A managed autoscaler, Karpenter, or GKE node auto-provisioning: capacity follows Pending pods within a minute or two, and scales to zero. |
| **`solo` today** | None. Capacity is whatever `agent_nodepools` declares. |
| **Mechanism (2.19.2)** | `autoscaler_nodepools` plus the full `cluster_autoscaler_*` family — version, replicas, resource limits, extra args, provisioning timeout. **Confirmed present in 2.19.2**, so this row needs no module upgrade. |
| **€ delta** | **€0 idle** with `min_nodes = 0`; burst cost is hourly and capped at the monthly price. |
| **Measured, not designed** | Scale-up end to end **2m47s**, tested non-disruptively with synthetic Pending pods (2 × 2500m CPU): pod Pending → **+6s** autoscaler decision → **+77s** server `running` → **+128s** node joined, NotReady → **+167s** node Ready and pod Running. Scale-down: candidate **1s** after the workload was removed, node deleted after **10m01s**, server gone, Node object cleaned up about 45s later by the cloud-controller-manager. The whole proof cost €0.014. |
| **Measured again on 2026-08-17, and it failed** | The same mechanism, same repository, same module version, on the source cluster: a Pending pod carrying the CI nodeSelector and toleration. The autoscaler did its half correctly — it matched the pod against the node group (`Pod … can be moved to template-node-for-k3s-ci-…`) and created a cx33 within seconds. **The server never joined.** Ten minutes later the cluster still had four nodes. On the server: `cloud-init status: error`, `k3s-agent` never installed (`inactive` / `not-found`), and the control-plane k3s log contained no join attempt at all. What `/var/log/cloud-init-output.log` shows, stated as observation rather than diagnosis: `curl: (22) The requested URL returned error: 429` three times, and — interleaved with it — `tailscaled` logging connection timeouts from its own tailnet address to an openSUSE mirror ("no associated peer node"), alongside `Tailscale is stopped`, `iptables not found` and a `resolv.conf` complaint. **The cause of the 429 is not established.** A 429 is a completed HTTP exchange, so it is not simply "no connectivity"; and per §2 of `docs/ARCHITECTURE.md` this class of traffic is meant to leave through the NAT router, not the tailnet. Whether the two symptoms share a cause, or the mirror was rate-limiting the shared NAT address, was not determined. **What is certain is that it is not a standing egress fault:** from an existing node at that same moment, `download.opensuse.org`, `get.k3s.io` and `github.com` all returned HTTP 200. The 2m47s measurement above is not withdrawn — it happened. But scale-up is not reliably reproducible here, and the failure is **silent**: the autoscaler reports the group at size 1 and the pod simply stays Pending. Anything pinned to such a pool, CI in particular, hangs until a human looks. |
| **Residual gap** | 2m47s is comfortably fast for the drain case — the incident above left pods Pending for 2.5 hours; with an autoscaler that would have been under three minutes. But the autoscaler reacts to **Pending pods**, so it does not help with CPU starvation on an existing node, where nothing is Pending. Hetzner has no spot or preemptible tier, so there is no cost-optimised scaling. And the autoscaler needs its own cloud token, which widens the credential blast radius. |

### 3.6 Multi-AZ and anti-affinity → **ha** (partly structural)

| | |
|---|---|
| **EKS/GKE/AKS** | Three availability zones inside one region, ~1 ms apart, `topology.kubernetes.io/zone` populated automatically, `PodTopologySpread` working out of the box, and the control plane spread for you. |
| **`solo` today** | Anti-affinity: **yes** — spread placement groups, on by default (§1.1). Multi-AZ: **no** — every node is in one location. |
| **Mechanism (2.19.2)** | `location` per nodepool; placement groups already default-on; the Hetzner cloud-controller-manager populates topology labels. `nat_router.enable_redundancy` with `standby_location` for the egress path. |
| **€ delta** | **€0 for spreading itself** (same node count, different locations) plus **€6.64** if NAT redundancy adds a standby cx23. |
| **Residual gap** | **Hetzner has no availability zones inside a location.** "Multi-AZ" here means multi-*datacentre*, which is a different latency domain — so it buys blast-radius reduction and costs etcd latency (§3.1). That is a genuine architectural trade, not a free upgrade, and both the README and `variants/ha/main.tf` say so at the top. |

### 3.7 Managed add-on lifecycle → **both** (structural)

| | |
|---|---|
| **EKS/GKE/AKS** | The provider ships and patches CNI, CSI, CoreDNS and kube-proxy, and guarantees a compatibility matrix against the control-plane version. |
| **`solo` today** | Every component is hand-pinned: cloud-controller-manager, CSI driver, kured, cert-manager and traefik. The pinning is correct and hard-won — the CSI pin exists because an older version reformatted a production database volume during a node failover. But there is no compatibility matrix, no notification, and no automated bump. |
| **Mechanism (2.19.2)** | Per-component version variables, already used, plus Dependabot or Renovate on the repository. |
| **€ delta** | €0 |
| **Residual gap** | **Structural: you are the integration tester.** No mechanism in any self-hosted stack replaces a vendor's compatibility matrix. The compensation is process, and process has to be written down to exist: pin exactly, read release notes, snapshot volumes before a CSI bump, and keep the CSI incident in the runbook as the worked example rather than as folklore. |

### 3.8 API audit logging → **solo** (the cheapest high-value row in this table)

| | |
|---|---|
| **EKS/GKE/AKS** | Audit logs on by default, shipped off-host to CloudTrail / Cloud Audit Logs / Azure Monitor, retained, queryable, and outside the reach of a compromised node. |
| **`solo` today** | Configured. It was not: `k3s_audit_policy_config` was unset, so **nothing recorded who called the API**. The mechanism existed in 2.19.2 all along. |
| **Mechanism (2.19.2)** | `k3s_audit_policy_config` plus `k3s_audit_log_path` (default `/var/log/k3s-audit/audit.log`), `k3s_audit_log_maxage` (30 d), `maxbackup` (10) and `maxsize` (100 MB). |
| **€ delta** | **€0** — local disk, and shipping it off-host reuses whatever log pipeline you already run |
| **Residual gap** | The log sits on the control-plane node: lose the node and you lose the trail, and it is not tamper-evident against root on that node. Off-host shipping is on you. Note the interaction with §3.1 — with one control plane, the audit log has exactly the same single point of failure as the API it audits. |

### 3.9 Private API endpoint → **neither** (`solo` already meets or exceeds it)

| | |
|---|---|
| **EKS/GKE/AKS** | An optional private endpoint: the API is reachable only from the VPC or peered networks. Public by default; going private is opt-in and often awkward. |
| **`solo` today** | **Already stronger than the managed default.** The kube-API is restricted to a private overlay network (`firewall_kube_api_source`), `control_plane_load_balancer_enable_public_network = false` (named `control_plane_lb_enable_public_interface` in 2.19.2), and — measured — no node has a public IPv4 except the NAT router. Egress leaves through one address. |
| **Mechanism (2.19.2)** | Already applied. |
| **€ delta** | €0 |
| **Residual gap** | The design assumes a **trusted overlay network**, and its provider is a third party in the authentication path. `additional_tls_sans` is a variable rather than a hardcoded address, so a fork does not inherit somebody else's SAN. **There is no documented break-glass path if the overlay network provider is unavailable** — a genuine operational gap this matrix surfaced, and it belongs in the runbook rather than in a comment. |

### 3.10 IAM integration → **both, documented only** (workload identity is structural)

| | |
|---|---|
| **EKS/GKE/AKS** | Cloud IAM identities map to RBAC (EKS access entries, GKE Google IAM, AKS Entra ID); and workload identity — IRSA, GKE WI, AKS managed identity — gives pods short-lived cloud credentials with no stored secret. |
| **`solo` today** | None. Access is a static client certificate in the kubeconfig: no per-user identity, no OIDC, and no revocation short of rotating the CA. A GitHub team gates Argo CD, which is not the same thing as gating the kube-API. |
| **Mechanism (2.19.2)** | `authentication_config` — k3s structured authentication configuration, i.e. an external OIDC provider. Present in 2.19.2. |
| **€ delta** | €0 if you already run an identity provider |
| **Why `ha` does not implement it** | The obvious provider to point at is one running *inside the cluster*, which makes cluster access depend on a workload the cluster hosts — a bootstrap circularity that a forker, who has no such provider, would inherit as a broken example. The path is documented; the wiring is left to the operator. |
| **Residual gap** | **Workload identity has no equivalent here.** Pods keep long-lived secrets; that is structural for self-hosted and is better said out loud than left as an omission. And adding OIDC puts the identity provider in the critical path for cluster access, so the certificate-based kubeconfig has to be retained as break-glass — which partly re-opens the revocation problem it was meant to close. |

### 3.11 CVE patch cadence → **solo**

| | |
|---|---|
| **EKS/GKE/AKS** | The provider patches the control plane within days of a CVE, publishes security bulletins, and force-upgrades at end of life. |
| **`solo` today** | Genuinely decent: k3s auto-upgrade on a pinned channel, MicroOS auto-updates, kured rebooting inside 03:00–05:00. The channel is now named explicitly (`initial_k3s_channel = "v1.33"`) — a no-op against the module's current default, and *that is exactly why it is worth writing down*: the value was **inherited**, so a module bump that changed the default would have moved the cluster a minor version with no diff to show it. Patch releases within the minor still arrive automatically, which is the intended cadence. |
| **Mechanism (2.19.2)** | `initial_k3s_channel` / `install_k3s_version` · `automatically_upgrade_os` · Dependabot on the module and providers. |
| **€ delta** | €0 |
| **Residual gap** | No SLA and no bulletin: you patch when you notice. Subscribing to the k3s and openSUSE MicroOS advisory feeds is the compensation, and it is a human process, not a control. |

### 3.12 DR, RTO and RPO → **both**

| | |
|---|---|
| **EKS/GKE/AKS** | Control-plane recovery is the provider's problem and effectively invisible; a regional cluster survives losing a zone. Your application data remains your problem either way. |
| **`solo` today** | etcd RPO **4 h**, with 7 days of retention (§3.2). RTO: **the restore procedure is written but has not been executed**, so the honest answer is "unknown, bounded by an awake human". Application data: `enable_delete_protection` covers the floating IP, the load balancer and the declared volume — it does **not** cover CSI-provisioned `pvc-*` volumes, which is easy to assume and wrong. Single location: losing it takes the whole cluster. |
| **Mechanism (2.19.2)** | etcd S3 backup, present, plus a written *and executed* restore · a multi-location control plane (§3.1) · CSI `VolumeSnapshot` for application data. |
| **€ delta** | Covered by §3.1 and §3.6; volume snapshots are about €0.069/GB/month. |
| **Residual gap** | **A single cloud account remains a single point of failure** — a billing dispute, an account lockout or one compromised token reaches every resource at once. No self-hosted architecture fixes that. Only an off-provider copy of state, etcd snapshots and volume data does. That is the honest bottom of this matrix. |

---

## 4. What a self-hosted stack structurally cannot match

Six findings rather than six failures. Each is in the README as well, because a forker who
learns them after building is a forker who was misled.

1. **A managed control-plane SLA** — there is nobody to page. §3.1
2. **Workload identity (IRSA-equivalent)** — pods keep long-lived secrets. §3.10
3. **Node auto-repair for static nodepools** — no mechanism exists in 2.19.2. §3.3
4. **Tamper-evident, off-host audit logging by default** — the trail lives on the node it audits. §3.8
5. **Vendor-tested add-on compatibility** — you are the integration tester. §3.7
6. **Single-cloud-account blast radius** — one account, one token, everything. §3.12

---

## 5. Where each row landed

| Row | Assignment | € delta | Status |
|---|---|---|---|
| 3.4 upgrade window | **solo** | €0 | closed — 01:00–03:00, ending where kured's window starts |
| 3.8 API audit logging | **solo** | €0 | closed — the mechanism existed and was unset |
| 3.11 pin the k3s channel | **solo** | €0 | closed — the value was inherited, now named |
| 3.2 etcd retention | **solo** | €0 | closed — RPO 12 h → 4 h, retention 2.5 d → 7 d |
| 3.2 restore *proof* | **both** | €0 | procedure written; **executing it is still outstanding** |
| 3.1 control-plane HA | **ha** | +€13.28 | 2 + 1 across locations, with tuned etcd timeouts |
| 3.4 drain headroom | **ha** | +€10.27 | a third schedulable agent |
| 3.5 cluster autoscaler | **ha** | €0 idle | `min_nodes = 0`, `max_nodes` as a cost ceiling |
| 3.6 multi-location + NAT redundancy | **ha** | +€6.64 | standby NAT router |
| 3.10 OIDC | **both** | €0 | **documented only**, deliberately |
| 3.7 add-on lifecycle | **both** | €0 | process plus Dependabot |
| 3.12 DR / volume snapshots | **both** | ~€0.07/GB | |
| 3.3 node auto-repair | **neither** | — | structural; alert and document |
| 3.9 private API endpoint | **neither** | — | already exceeds the managed default |

**Four of the twelve rows closed for €0**, because the mechanism was already in the pinned
module and simply unset. That is the most actionable result in this document, and it is the
argument for reading a module's variables rather than its README.

---

## 6. Decisions taken while writing this

Four questions this matrix raised, and how they were answered. They are recorded because the
answers shaped both variants, and a reader who disagrees with an answer can see exactly what
it changed.

1. **The four €0 rows were applied to `solo`**, not deferred to `ha`. They touch the running
   cluster — an upgrade window and audit logging both take effect on apply — so they went in
   behind a shown-and-approved plan diff, like any other change. They are the highest
   value-per-risk changes in this whole project.
2. **`ha` builds etcd quorum 2+1 across locations**, with the single-location alternative
   documented rather than hidden. The trade cannot be settled from a desk: it depends on the
   round-trip time between the two locations *you* pick, under etcd load. `ha` therefore
   defaults to a nearby second location and tunes the heartbeat and election timeouts, and
   the README does not recommend a topology this project has not measured.
3. **OIDC is documented, not implemented** (§3.10) — implementing it against an in-cluster
   identity provider would ship a bootstrap circularity as an example.
4. **Node auto-repair is accepted as unmatched** (§3.3). An alert plus a documented manual
   replacement is the answer; a homegrown repair controller is out of scope for a reference
   architecture, and shipping one would be the least-tested code in the repository.
