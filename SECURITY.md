# Security policy

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository: the *Security* tab →
*Report a vulnerability*. That opens a private advisory visible only to you and the
maintainers.

Please do **not** open a public issue or pull request for a security problem, and do not
attach a working exploit against anyone's live infrastructure.

Useful in a report, roughly in order of usefulness:

- the file and line, or the specific variable and value
- what an attacker gets, concretely — "reads the state bucket", not "could be a risk"
- whether it affects `variants/solo`, `variants/ha`, or both, since they are independent
  copies and a fix in one is not a fix in the other
- whether it is reachable with the shipped defaults, or only after a forker changes
  something

This is a single-maintainer project. Expect an acknowledgement in a few days rather than a
few hours, and no bounty programme.

## What is supported

The tip of the default branch, and nothing else. There are no maintained release branches
and no backports: this is a reference architecture you fork (`docs/adr/0002-reference-architecture-not-module.md`),
so the supported version is the one you copied and then own.

## Threat model

What the design assumes, so that a report can tell the difference between a vulnerability
and a documented trade-off.

**Assumed trustworthy.** These are outside the boundary, and compromising one compromises
the cluster by design, not by defect:

- **The private overlay network** that fronts the kube-API. The API is not exposed to the
  internet; reachability *is* the first authentication factor, and the overlay network's
  provider is a third party sitting in that path. `docs/managed-k8s-parity.md` §3.9 states
  this plainly, including that there is no documented break-glass path if that provider is
  unavailable.
- **The object storage holding Terraform state.** State contains provisioning material.
  Whoever can read that bucket can, in effect, read the cluster's secrets — which is why
  the backend is partial, why no filled-in `backend.hcl` is ever committed, and why the
  bucket credentials belong in a different blast radius from everything else.
- **The cloud account and its API token.** One token reaches every resource in the project.
  `docs/managed-k8s-parity.md` §3.12 names this as the bottom of the whole design: no
  self-hosted architecture fixes it.
- **The machine running `terraform apply`.** It holds every credential at once.

**In scope, and worth reporting:**

- A default in the shipped configuration that is unsafe for a forker who changes nothing —
  an open firewall source, a permissive RBAC binding, a credential with more reach than its
  job needs.
- A secret reaching a place it should not: Terraform state, an output, a log line, a
  container image, or a tracked file.
- Anything in the example variable files that reads as "fill this in" but is actually
  usable as-is in a way that weakens the cluster.
- A supply-chain problem: a pin that resolves to something other than what the comment
  claims, or a lockfile that no longer matches its declared constraint.
- Privilege escalation between namespaces or workloads beyond what Kubernetes gives you by
  default.

## Explicitly out of scope

Not because they do not matter, but because they are known properties of this design.
A report that rediscovers one of these will be closed with a link to this section:

- **No multi-tenant isolation.** Every workload is assumed to be operated by the same
  people. There is no tenant boundary, no per-tenant network policy, and none is planned.
- **Pods hold long-lived credentials.** There is no workload-identity equivalent — no IRSA,
  no GKE Workload Identity. That is structural for self-hosted Kubernetes and is documented
  in `docs/managed-k8s-parity.md` §3.10.
- **Cluster access is a static client certificate.** No per-user identity and no revocation
  short of rotating the CA. An OIDC path exists and is deliberately not wired up (§3.10).
- **Audit logs live on the node they audit.** Not tamper-evident against root on that node,
  and lost with the node. Off-host shipping is left to the operator (§3.8).
- **No node auto-repair.** An unhealthy node stays unhealthy until a human acts (§3.3).
- **The maintenance windows are published.** Upgrades run 01:00–03:00 and reboots
  03:00–05:00 in the configured timezone. A known window is the cost of having a window at
  all, and it is the right trade.
- **`variants/ha` has never been applied to production by its authors.** Its failure modes
  are reasoned about, not all observed. Treat it as a reference, and read
  `docs/variant-delta.md` before assuming a property of `solo` also holds there.
- Findings against the upstream projects in `THIRD_PARTY.md`. Report those to their
  maintainers; if the fix belongs here as a pin bump, a normal issue is the right channel.

## What this repository does about secrets

- No credential-bearing file is tracked. `.gitignore` covers state, `backend.hcl`,
  `*.tfvars` other than the examples, kubeconfigs and `*.pem`; the export that produced
  this tree used an allowlist rather than `.gitignore`, because a commit filter is not a
  publication boundary.
- The backend is **partial**: `terraform init` fails without an explicit
  `-backend-config`. There is nothing in this tree that can point a fork at somebody else's
  state.
- The published history is a fresh history, not a filtered one
  (`docs/adr/0003-new-public-repo-clean-history.md`).
