# k3s on Hetzner Cloud — a reference architecture, in two variants

> **This is a reference architecture, not a module.** Fork it and edit it. There is no
> stable input API, no versioned interface, and no promise that the next commit will not
> restructure something you depend on. If that is not what you want, use the upstream
> module directly — [kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner)
> — which this builds on and pins to 2.19.2. See `docs/adr/0002`.

Two complete, independently forkable Terraform root configurations for a k3s cluster on
Hetzner Cloud with ArgoCD, a NAT router, a dedicated egress node, and a Kubernetes API
served only over a Tailscale tailnet.

**Copy one directory. It is yours.** They do not reference each other.

## Which one

| | [`variants/solo`](variants/solo) | [`variants/ha`](variants/ha) |
|---|---|---|
| Control planes | 1 | 3, split 2 + 1 across two datacentres |
| Losing a control plane | API down until it reboots — pods keep running, nothing schedules | survives |
| General agents | 2 | 3 |
| Can you drain a worker? | **No.** Nowhere to put the pods | Yes |
| Autoscaler | none | 0 → 3 nodes, ~3 min to schedule |
| NAT router | 1 — single point of failure for egress *and* the API path | 2, keepalived VIP, second datacentre |
| Cost, idle | **€76** / month | **€107** / month (1.40×) |
| Cost, autoscaler at ceiling | — | €138 / month (1.81×) |
| Proven by | **running a real workload** | static checks only so far — never booted; see its README |

**Choose `solo`** if you are one operator, the bill matters, and a control-plane reboot is
an inconvenience rather than an incident.

**Choose `ha`** if the API must survive losing a node, if you need to drain workers, or if
one datacentre going away should cost availability rather than the cluster.

Each variant's README states its own trade-offs and what it does *not* give you.
`docs/cost-comparison.md` shows the measured prices; `docs/variant-delta.md` is the exact
diff between the two.

## What this is honest about

Neither variant is managed Kubernetes, and six of the twelve capabilities in
`docs/managed-k8s-parity.md` are gaps **no self-hosted stack closes**:

1. **A managed control-plane SLA** — there is nobody to page.
2. **Workload identity** (IRSA / GKE WI / AKS managed identity) — pods keep long-lived secrets.
3. **Node auto-repair for static pools** — a NotReady node stays NotReady until a human acts.
4. **Tamper-evident off-host audit logging** — the trail lives on the node it audits.
5. **Vendor-tested add-on compatibility** — you are the integration tester.
6. **Single-cloud-account blast radius** — one account, one token, everything.

The parity document gives each one a cost, a mechanism if there is one, and the residual
risk if there is not. It is the most useful thing in this repository.

## The comments are the point

Most of the value here is not the HCL — it is why each line exists. A pinned CSI version
because an older one reformatted a production database volume during a node failover. A
toleration patch re-triggered by a fingerprint because two nodes silently stopped
rebooting for three days and the apply reported success. `system_upgrade_use_drain = false`
in `solo` because a drain with nowhere to put the pods cordoned a node for two and a half
hours with eight pods Pending, one of them Alertmanager.

Read the comments before deleting a line. Each one is a description of what breaks.

## Layout

```
variants/solo/        complete root configuration — the stack that runs in production
variants/ha/          complete root configuration — the HA reference
docs/ARCHITECTURE.md  why the shape is the shape, and what each choice costs
docs/adr/             the decisions, and what was rejected
docs/RUNBOOK.md       procedures that are not expressible as configuration
docs/managed-k8s-parity.md    twelve capabilities, measured against EKS/GKE/AKS
docs/cost-comparison.md       measured prices
docs/variant-delta.md         generated diff between the two variants
docs/README.md        how these documents are maintained, and which are generated
NOTICE                upstream attribution that has to travel with a redistribution
THIRD_PARTY.md        every dependency, its licence, and whether it is distributed here
CONTRIBUTING.md       DCO sign-off, which licence your patch is under, what gets rejected
SECURITY.md           private reporting channel, threat model, what is out of scope
.github/              CI and Dependabot
```

## Status

This tree is being prepared for publication and is **not finished**.

- `variants/solo` is a de-identified copy of a configuration that runs a real workload.
- `variants/ha` has **never been applied**. It validates and plans cleanly against an
  empty state; it has not been booted, and neither the control-plane kill nor the etcd
  restore has been executed. That is the next step, and until it happens the availability
  claims are design intentions.
- **CI runs green, and it earned that by going red first.** All nine jobs pass with no
  credentials of any kind. Its first run found two real defects: `required_version` claimed
  `~> 1.10` while upstream's own validation cannot parse on anything below 1.12, and the
  generated `docs/variant-delta.md` was locale-dependent, so the drift-guard passed for the
  maintainer's shell and failed for everybody else's. Both are fixed; the version floor is
  now bisected rather than guessed, and both bounds of the constraint run on every pull
  request.
- Still to come: the finished documentation set. Both variant READMEs are drafts marked as
  such, and their quickstarts have not been walked end to end by anyone starting from an
  empty account — so the boot time, the real cost and the manual repairs a first run needs
  are not in them yet.
