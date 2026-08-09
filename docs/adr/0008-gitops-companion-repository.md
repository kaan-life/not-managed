# ADR-0008: The reference architecture is two repositories, and the GitOps repo is published too

**Date**: 2026-08-08
**Status**: accepted
**Deciders**: repository owner

## Context

This repository builds a cluster. It does not describe what runs on it. That lives in a companion
GitOps repository, which holds ArgoCD's root ApplicationSet, the Tekton pipelines, and the Tekton
CRD bootstrap Application. The two are not independent: a cluster built from this repository alone
comes up with ArgoCD installed and nothing for ArgoCD to sync.

The dependency was also expressed in the worst possible way. `init.sh` applied a manifest by
**filesystem path**:

```
kubectl apply -f "${SCRIPT_DIR}/../<gitops-repo>/tekton/crds/crds-app.yaml"
```

with a comment assuming the GitOps repository was cloned as a sibling directory of this one.
That is an undeclared dependency on a private repository and on one particular directory layout.
Anyone who forked this repository and followed the README got a failed bootstrap at that line
(audit **P0-7**), and the green-field proof in M4 — which must run with no private repository
anywhere on disk — could not have passed.

The earlier plan offered two ways out: publish a minimal example GitOps repository, or make the
step optional and document the contract a GitOps repository has to satisfy. The second is cheaper
and produces a worse artefact: a reference architecture with a hole where the interesting half was.

## Decision

**Publish both.** The reference architecture is explicitly a **two-repository system**: this
repository builds the cluster, and a companion GitOps repository describes the workloads. The
companion repository is open-sourced separately and linked from this one.

Three rules follow, and they are what this ADR is really deciding:

1. **No filesystem assumptions, ever.** This repository never requires the GitOps repository to
   exist at a particular path. It resolves it, in order: an explicit path if the operator gives
   one, then a conventional sibling checkout if one happens to be there, and otherwise a shallow
   clone of the URL.
2. **One source of truth for the URL.** The bootstrap derives the GitOps repository URL from
   `github_org_url` + `github_repo_name` — the same inputs ArgoCD is configured with. It is
   structurally impossible for the CRD bootstrap and ArgoCD to end up pointed at different
   repositories, which is a class of bug that would otherwise be very hard to see.
3. **The reference is pinnable.** The clone takes a ref (`GITOPS_REF`). A fork that cares about
   reproducibility pins a tag rather than tracking `main`, for the same reason the kube-hetzner
   module is pinned exactly.

The bootstrap also gains a skip switch (`SKIP_TEKTON_BOOTSTRAP=1`) for clusters that do not want
Tekton at all — which is a legitimate choice, not a workaround for the dependency.

## Alternatives Considered

### Alternative 1: Make the bootstrap optional, document the contract, publish nothing
- **Pros**: no second repository to sanitise, publish or maintain; smallest possible scope.
- **Cons**: the published artefact builds an empty cluster. Every forker then has to invent the
  GitOps half from a prose contract, which is the part where the real design decisions live.
- **Why not**: it converts a reference architecture into a tutorial with the last chapter missing.

### Alternative 2: Vendor the GitOps manifests into this repository
- **Pros**: one repository; no cross-repository version skew; nothing to resolve at runtime.
- **Cons**: ArgoCD pulls from a git repository by design — vendoring means the manifests are in a
  repository ArgoCD is not watching, so they would have to be copied out again to be useful. It
  also merges two things with different change cadences and different blast radii: a cluster
  rebuild versus a deploy.
- **Why not**: it fights the GitOps model this architecture is demonstrating.

### Alternative 3: Keep the sibling-directory convention, document it loudly
- **Pros**: zero code change.
- **Cons**: it is still an undeclared dependency; it still fails for anyone whose checkout is laid
  out differently; and it still fails the green-field proof.
- **Why not**: documenting a trap does not remove the trap.

## Consequences

### Positive
- The published stack **actually works end to end**. A forker gets a cluster with workloads on it.
- The green-field proof in M4 becomes possible: no private repository has to exist on disk.
- Deriving the URL from ArgoCD's own inputs removes a whole class of "the bootstrap and ArgoCD
  disagree" failures that would have been diagnosed by hand.
- The two repositories can be pinned against each other, so a fork can reproduce a known-good pair.

### Negative
- **Two repositories to sanitise, not one.** The GitOps repository is the one holding application
  manifests, ingress hostnames and namespace names, so its de-identification burden is *larger*
  than this repository's, not smaller. It needs its own pass of the M2-c gate and its own entry in
  the M6 security review.
- Two repositories to keep compatible. A release of this repository is only meaningful together
  with a compatible GitOps revision.
- The bootstrap now performs a network clone, so it needs git credentials for a private GitOps
  repository and network access at a point where previously it needed neither.

### Risks
- **Version skew.** Someone pins this repository and tracks `main` on the GitOps side, and the
  bootstrap manifest stops matching. Mitigation: `GITOPS_REF` exists and the README tells a forker
  to pin it; the contract of required paths is documented rather than implied.
- **The GitOps repository leaks more than this one.** It describes live workloads. Mitigation: it
  goes through the same gates, and it must not be published before its own sanitiser pass — the
  M7 sign-off covers both repositories or neither.
