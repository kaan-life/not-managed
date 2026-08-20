# k3s on Hetzner Cloud — a reference architecture, in two variants

> **This is a reference architecture, not a module.** Fork it and edit it. There is no
> stable input API, no versioned interface, and no promise that the next commit will not
> restructure something you depend on. If that is not what you want, use the upstream
> module directly — [kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner)
> — which this builds on and pins to 3.1.0. See `docs/adr/0002`.

Two complete, independently forkable Terraform root configurations for a k3s cluster on
Hetzner Cloud with ArgoCD, a NAT router, and a Kubernetes API
served only over a Tailscale tailnet.

**Copy one directory. It is yours.** They do not reference each other.

## Which one

| | [`variants/solo`](variants/solo) | [`variants/ha`](variants/ha) |
|---|---|---|
| Control planes | 1 | 3, split 2 + 1 across two datacentres |
| Losing a control plane | API down until it reboots — pods keep running, nothing schedules | survives |
| General agents | 2 | 3 |
| Can you drain a worker? | **No.** Nowhere to put the pods | Yes |
| Autoscaler | 0 → **1** node, `cx33` | 0 → **3** nodes, `cx33`, ~3 min to schedule |
| NAT router | 1 — single point of failure for egress *and* the API path | 2, keepalived VIP, second datacentre |
| Cost, idle | **€70** / month | **€101** / month (1.44×) |
| Cost, autoscaler at ceiling | €80 / month | €131 / month (1.88×) |
| Proven by | **running a real workload**, and a green-field build from this tree | a green-field build from this tree: booted, control-plane killed, etcd restored |

> **This table said `solo` had no autoscaler until 2026-08-12, and that was wrong.**
> `variants/solo/main.tf` declares an `autoscaler_nodepools` block with
> `min_nodes = 0, max_nodes = 1`, and a green-field build of this variant produced an
> `…-autoscaled-…` node without being asked to. Both the capability row and the ceiling
> cost row are corrected above. It is recorded rather than quietly edited because this
> table is the one thing in the repository a reader is invited to make a decision from,
> and "we fixed the decision table" is the sort of change a returning reader should be
> able to see.

**Choose `solo`** if you are one operator, the bill matters, and a control-plane reboot is
an inconvenience rather than an incident.

**Choose `ha`** if the API must survive losing a node, if you need to drain workers, or if
one datacentre going away should cost availability rather than the cluster.

Each variant's README states its own trade-offs and what it does *not* give you.
`docs/cost-comparison.md` shows the measured prices; `docs/variant-delta.md` is the exact
diff between the two.

## What the same cluster costs on the big three

Same shape as `solo` — three 4 vCPU / 8 GB agents and two 2 vCPU / 4 GB nodes — priced on
**2026-08-20** from each vendor's own public price API, net of VAT, USD converted at the ECB
reference rate for that week (EUR/USD 1.1605). Each row uses the **cheapest predefined
instance that meets the spec, any architecture**, which is the reading most favourable to the
vendor; `solo` stays on the x86 `cx` types it actually declares.

| Compute, monthly | Instances priced | Net € | × `solo` |
|---|---|---|---|
| **`not-managed` solo** | 3× `cx33` + 2× `cx23` | **€36** | **1.0×** |
| AWS `eu-central-1` | 3× `c6g.xlarge` + 2× `t4g.medium` | €341 | 9.4× |
| Azure `germanywestcentral` | 3× `B4als_v2` + 2× `B2als_v2` | €343 | 9.4× |
| GCP `europe-west3` | 3× `e2-standard-4` + 2× `e2-medium` | €380 | 10.4× |

**Compute only, on every row.** Load balancers, block storage and egress are excluded
everywhere — including from `solo`'s own €36, whose full bill is €69.76 gross in
`docs/cost-comparison.md`. Excluding them uniformly is what makes the four rows comparable.

**Where `solo`'s €36 comes from.** `variants/solo/main.tf` declares eight agent and
control-plane pools, four of which sit at `count = 0`: the second and third control planes,
`storage`, and `egress` (parked 2026-08-17 — the comment there explains why zero beats
deletion). What runs at idle is three `cx33` — `agent-small`, `agent-large`, `agent-ci` — and
two `cx23`, one control plane plus the NAT router. That is 3 × €8.49 + 2 × €5.49 = **€36.45**
net. The autoscaler is `min_nodes = 0` and adds nothing until it fires.

AWS and Azure match the spec exactly. **GCP does not**, and its row is the weaker one twice
over: no predefined `e2` type offers 4 vCPU with 8 GB, so those agents carry 16 GB and the row
is oversized (custom machine types would fit, but their price was not retrieved); and where
the other three rows come from the Hetzner Cloud pricing API, the AWS metered-unit maps for
EU (Frankfurt)/Linux and the Azure Retail Prices API, Google's Cloud Billing Catalog API
refuses unauthenticated callers, so the GCP figures come from the third-party mirror
`gcloud-compute.com` (data stamped 2026-08-16), unverified against a Google-operated source.

Egress is left out because the reference cluster moves 32 GB/month, immaterial at any
published rate.

**A 9× multiplier is not by itself an argument.** It buys none of the twelve capabilities in
`docs/managed-k8s-parity.md`, six of which no self-hosted stack closes — the next section is
about exactly that.

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

**You will be running BUSL-licensed CLIs.** Terraform has been under the Business Source
License since 2023, and so has Packer, which the first build needs for the MicroOS
snapshot. The *providers* are MPL-2.0 and the configuration here is Apache-2.0 — the
licence question is about the tools, not this code — but if your organisation has a policy
against BUSL tooling, you need to know that before you clone rather than after.

**OpenTofu exists as an MPL-2.0 alternative and is untested here.** No compatibility claim
is made, because none has been tested: CI runs Terraform only, and the S3 backend uses
native `use_lockfile` state locking whose OpenTofu equivalence nobody has verified. Adding
a `tofu` CI job is about ten lines if someone wants the guarantee — see
`docs/adr/0004-terraform-only-opentofu-untested.md`, which has said since 2026-08-05 that
this README states the position. Until 2026-08-13 it did not; a reader coming to the
repository cold noticed the ADR promising something the README never said.

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

## The companion GitOps repository

This repository builds the cluster. It does not describe what runs on it — that is
[`not-managed-gitops`](../not-managed-gitops), and the two are published as one thing.
Neither is much use alone: this one without the companion boots an empty cluster; the
companion without this one is a pile of manifests with nothing to apply them.

<!-- Relative link on purpose: GitHub resolves ../name against this repository's owner, so
     the cross-link works without naming the hosting account in the file. -->

You do not have to use it. `SKIP_TEKTON_BOOTSTRAP=1 bash init.sh` builds a cluster with no
Tekton and no ArgoCD Applications, which is a legitimate choice. If you do use it, the
companion's README lists the five things a fork must supply before anything reconciles.

**What this repository requires of a GitOps repository**, whether it is the companion or
your own — three clauses, and only the first is obvious:

1. **A manifest at `tekton/crds/crds-app.yaml`.** `init.sh` applies exactly this one file
   during bootstrap, and nothing else from the GitOps side. Override the path with
   `GITOPS_CRD_PATH` if your layout differs.
2. **A reachable `repoURL` *inside* that manifest.** `init.sh` applies the file unchanged,
   so the URL it carries is the URL ArgoCD will use — deriving the clone URL from
   `github_org_url` + `github_repo_name` does not rewrite it. Leave the companion's
   placeholder in place and bootstrap waits `GITOPS_CRD_TIMEOUT` (600s) and then fails.
3. **One top-level directory per namespace.** The root ApplicationSet is generated with
   `path: {{environment}}`, so every name in `utility_namespaces + app_namespaces` must
   match a directory in the GitOps repository. A namespace with no directory produces an
   Application that reports `Healthy` — an Application with zero resources trivially is —
   while `sync` sits at `Unknown` with `app path does not exist`. The example tfvars in
   both variants ship `["tooling", "tekton"]` and `["prod"]` — the directories the
   companion actually has — so the pair works unedited. They are the only values in that
   file without a `your-` prefix, because they are not free-form names.

### Where `init.sh` looks for the companion

Before cloning anything, `init.sh` looks for a local checkout next to this repository:
`../<github_repo_name>`, and — because this file lives in `variants/<name>/` —
`../../../<github_repo_name>`. It prints which one it used. Set **`GITOPS_LOCAL_PATH`** to
point it at any other location, and `SKIP_TEKTON_BOOTSTRAP=1` to skip the whole step.

> Until v1.0.1 it probed only the first of those two paths, which from `variants/solo/`
> resolves to `variants/not-managed-gitops` and can therefore never exist. A local checkout
> was ignored and the remote cloned in its place, with nothing printed to say so — which
> meant testing an edit to the companion silently tested `main` instead.

### The placeholder in the companion must stay a placeholder

The companion ships `repoURL: https://github.com/example-org/gitops`, which does not exist
and returns 404. **Do not "fix" it to point at the real repository, in the companion or in
any fork you publish.** A working URL there means anyone who forgets to substitute it
reconciles their cluster out of somebody else's repository — with no error, no symptom and
no way to notice. A 404 fails loudly on the first sync, and loud is the entire design.

Substitute it in *your* fork, in both files that carry it (`root.yaml` and
`tekton/crds/crds-app.yaml`), and leave the published one alone.

### Pinning the pair

The two repositories carry **the same tag**. `not-managed v1.0.0` goes with
`not-managed-gitops v1.0.0` — one version number, no translation table, so a mismatch is
visible rather than inferred.

> **`GITOPS_REF` pins less than it looks like it does.** It selects which revision of the
> companion the bootstrap manifest is *read from*. It does **not** pin what ArgoCD
> reconciles afterwards: that is `targetRevision`, and it is `main` in three places — the
> companion's `root.yaml`, its `tekton/crds/crds-app.yaml`, and the ApplicationSet this
> repository generates in `scripts/apply-argocd-appset.py`. A fork that sets only
> `GITOPS_REF` has pinned one file out of thirty-five build directories, and every push to
> the companion's `main` still lands in the cluster.
>
> Pinning the pair properly means changing `targetRevision` in all three places as well.

## Status

This tree is being prepared for publication and is **not finished**.

- `variants/solo` is a de-identified copy of a configuration that runs a real workload.
- **`variants/ha` has now been booted, and both availability claims have been executed
  rather than asserted.** On a throwaway project, from a clean checkout of this tree and
  nothing else:
  - **control-plane kill** (2026-08-11) — `poweroff`, not a graceful shutdown, on one of
    the three. During the outage: 10/10 API probes succeeded, and an etcd *write* went
    through on the surviving two members. The write is the evidence; a readable API only
    proves the load balancer is doing its job. The node rejoined ~30 s after power-on.
  - **etcd restore** (2026-08-12, twice) — full `--cluster-reset` from a snapshot, checked
    with a marker that had to survive and a second marker that had to disappear, because
    "the cluster came back" is also what a cluster that lost nothing does. The second run
    deleted the node's local snapshot copy first and restored from the bucket alone.
    Measured RTO for the mechanical part: **under five minutes**. `docs/RUNBOOK.md` §4 is
    now written as executed, and running it is what found the two defects fixed in it.
- **CI runs green, and it earned that by going red first.** All nine jobs pass with no
  credentials of any kind. Its first run found two real defects: `required_version` claimed
  `~> 1.10` while upstream's own validation cannot parse on anything below 1.12, and the
  generated `docs/variant-delta.md` was locale-dependent, so the drift-guard passed for the
  maintainer's shell and failed for everybody else's. Both are fixed; the version floor is
  now bisected rather than guessed, and both bounds of the constraint run on every pull
  request.
- **Measured build times**, from a clean checkout on a throwaway project, excluding the
  Packer snapshot (~5 min, and reusable across builds):

  | | `terraform apply`, first pass | to all nodes `Ready` | teardown |
  |---|---|---|---|
  | `ha`, 3 control planes + 1 agent + NAT router | ~15 min (102 resources) | same pass | ~4 min |

  The teardown figure is the *targeted* destroy that actually completes — see the orphan
  and ordering notes in `docs/RUNBOOK.md` §4 before you rely on a single `destroy`.

- Still to come: `variants/solo/README.md` and `variants/ha/README.md` are drafts. What a
  first run actually needed is now written down — see **"What a first run actually needed"**
  in `variants/ha/README.md` — but neither quickstart has been walked end to end by someone
  who has not read this repository before, which is the test that finds the rest.
