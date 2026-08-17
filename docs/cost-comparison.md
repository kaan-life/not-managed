# Cost: solo vs ha

Every figure here was read from the Hetzner pricing API on **2026-08-09**, not estimated
and not copied from a page. Prices are **gross monthly EUR, including 19 % VAT**; the net
figures are roughly 17.5 % lower. Prices are identical across the German and Finnish
locations, so moving a server between them changes nothing on this table.

Reproduce it:

```bash
hcloud server-type list -o json | jq '.[] | select(.name=="cx23" or .name=="cx33")'
hcloud load-balancer-type list -o json | jq '.[] | select(.name=="lb11")'
curl -sS -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/pricing
```

## Unit prices (measured)

| Item | Gross / month |
|---|---|
| cx23 | €6.64 |
| cx33 | €10.27 |
| lb11 | €9.06 |
| Volume | €0.0692 / GB |
| Snapshot | €0.0173 / GB |
| Primary IPv4 | €0.605 |

## Side by side

| Line | solo | ha | ha total |
|---|---|---|---|
| cx23 | 3 — control plane, egress, NAT router | 6 — **3** control planes, egress, **2** NAT routers | €39.84 |
| cx33 | 3 — two general agents, CI agent | 4 — **three** general agents, CI agent | €41.08 |
| lb11 | 2 — traefik + control plane | 2 | €18.12 |
| Volumes (100 GB) | ✓ | ✓ | €6.92 |
| Primary IPv4 | 1 — NAT router | 2 — active + standby NAT router | €1.21 |
| Snapshots (~1.4 GB MicroOS) | ✓ | ✓ | €0.02 |
| Autoscaler pool at `min_nodes = 0` | idle | idle | €0.00 |
| **Total, idle** | **€76.40** | | **€107.19** |

**Ratio: 1.40×.**

Two load balancers, not one: enabling the NAT router forces
`enable_control_plane_load_balancer = true`,
so there is a control-plane LB in addition to the ingress one. That is €18.12, not €9.06,
and it is easy to miss when reading the configuration.

## The autoscaler is the part that can surprise you

`min_nodes = 0` means the idle bill above is the real one. But an autoscaler with no
upper bound has an unbounded monthly cost, and "it only scales when it needs to" is not a
budget. `max_nodes` is a cost ceiling first and a capacity limit second.

**Both variants have one.** `solo` runs `min_nodes = 0, max_nodes = 1`, so its ceiling is
one cx33 above idle: **€86.67**. `ha` runs `max_nodes = 3`. Until 2026-08-12 the row above
showed a dash for `solo` and the comparison table in the root README said it had no
autoscaler at all — both wrong, and both found the same way: a green-field build of `solo`
produced an `…-autoscaled-…` node that nothing in the documentation predicted.

| `max_nodes` | Worst-case monthly | Ratio to solo |
|---|---|---|
| 0 (idle) | €107.19 | 1.40× |
| 1 | €117.46 | 1.54× |
| **3 (configured)** | **€138.00** | **1.81×** |
| 8 | €189.35 | 2.48× |
| 9 | €199.62 | 2.61× |

This project set itself a stop condition of **2.5× solo** for the `ha` variant. That
ceiling is €190.95/month, which leaves €83.77 of burst budget — exactly **eight** cx33
nodes. So `max_nodes = 8` is not a round number, it is the largest value consistent with
the constraint, and the configured 3 leaves deliberate room underneath it.

Raise `max_nodes` only together with the budget line it consumes.

## What is not in this table

- **Traffic.** Every server includes 20 TB/month; egress beyond that is €1.19/TB gross.
  All egress here leaves through the NAT router, so it is that server's allowance that
  matters, not the sum.
- **Application data growth.** The 100 GB of volumes is what the source cluster happens to
  use. Volumes are €0.0692/GB/month and scale linearly.
- **Volume snapshots for DR.** Same €0.0692/GB. Snapshotting all 100 GB adds €6.92/month
  per full generation.
- **Object storage** for Terraform state and etcd snapshots — a few cents at these sizes.
- **Your time.** The honest largest line item in a self-hosted cluster, and the one
  managed Kubernetes is actually selling. `docs/managed-k8s-parity.md` is the attempt to
  price it in capabilities rather than euros.
