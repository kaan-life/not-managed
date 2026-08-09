# ADR-0007: Two independently forkable root configurations in one public repository

**Date**: 2026-08-08
**Status**: accepted
**Deciders**: repository owner

## Context

The objective changed after ADR-0002 was accepted. The repository is no longer published as one
artefact but as **two**:

- **V1 "solo"** — the stack that runs in production today: one control plane, Tailscale-only
  kube-API, a NAT router, a dedicated egress node. Small, cheap, secure.
- **V2 "ha"** — everything a managed Kubernetes service provides that V1 does not: control-plane
  HA, multi-location placement, cluster autoscaling, node auto-repair, surge upgrades, a proven
  backup/restore path, and real drain headroom. V2 is a **published reference only** and is never
  applied to production.

ADR-0002 fixed the *form* (reference architecture, fork-and-edit, no input-API promise) and
ADR-0003 fixed the *repository strategy* (a new public repository with clean history; the private
repository stays private and remains canonical for infrastructure behaviour). Neither says how two
variants are packaged, and the packaging decision is not cosmetic. It determines:

1. whether the de-identification gate and the sanitiser produce one PASS decision or two;
2. how many irreversible publish steps exist;
3. where V2 is authored, and therefore whether V2 ever contains an internal identifier at all;
4. whether "V2 can never be planned against the production state" is a *structural property* or
   merely a convention.

Four measured constraints bound the choice:

- **V1 is a root module.** It contains a `backend "s3"` block (`providers.tf:46`), configured
  `provider` blocks, and shell scripts that drive `terraform apply`. ADR-0002 already established
  that this cannot become a child module without splitting the repository and redesigning every
  input.
- **The private repository is the live production definition.** Moving its root files into a
  subdirectory rewrites every path in `init.sh`, `apply.sh` and `destroy.sh`, invalidates the
  existing `.terraform/` working directory, and changes the operator's workflow against a running
  cluster — for zero benefit to the private repository.
- **kube-hetzner keys nodepools by list index.** `main.tf:215-231` documents this in-tree ("MUST
  stay last in this list … inserting a pool earlier re-indexes (and recreates) the egress node"),
  and the G1 audit records it again as a P2. A nodepool list whose *length* depends on a variable
  is therefore destructive, not convenient.
- **V2 is never applied.** It has no state, no cluster, and no operator. Its only consumers are
  forkers and the green-field proof run.

## Decision

Publish **two independently forkable root configurations as sibling directories in one public
repository**:

```
variants/solo/      V1 — de-identified copy of the private root; the stack in production
variants/ha/        V2 — authored directly in the public tree; never applied to production
docs/               shared: adr/, managed-k8s-parity.md, ARCHITECTURE.md, RUNBOOK.md, variant-delta.md
.github/            shared CI, matrixed over both variant directories
LICENSE  NOTICE  THIRD_PARTY.md  CONTRIBUTING.md  SECURITY.md  README.md
```

Each variant directory is **complete and self-contained**: its own `backend "s3" {}` (partial)
block, provider configuration, `variables.tf`, `secrets.auto.example.tfvars`,
`backend.hcl.example`, and a per-variant `README.md`. "Fork this" means: *copy one directory; it is
yours.* Neither variant references the other at apply time.

The **private repository keeps its current flat layout and contains V1 only.** V2 is authored in
the public tree, derived from the already de-identified V1 — so V2 never contains an internal
identifier and carries no sanitisation debt of its own.

The root `README.md` opens with the ADR-0002 disclaimer and a **"choose V1 if… / choose V2 if…"**
decision table. That table is the repository's front door and is the reason both variants live
behind one URL.

### Directory naming

`variants/solo/` and `variants/ha/`, settled at the M0 gate rather than later — naming is the
cheapest part of this decision to change now and the most expensive to change after publication,
because it lands in URLs and in every fork.

The runner-up was `variants/hobby/`, the working vocabulary of the plan. It was rejected on two
grounds: it compares *ambition* to *mechanism* while `solo`/`ha` compares mechanism to mechanism
(one control plane versus three), and it would permanently label the stack that runs a live
business a hobby. Suitability — "choose this if you are a single operator who can tolerate a
control-plane reboot" — belongs in the README decision table, where it can be stated properly,
not compressed into a directory name.

## Alternatives Considered

### Alternative 1: Shared base module under `modules/`, two thin example roots
- **Pros**: no duplicated HCL; a single place to fix a bug; the two variants cannot silently drift.
- **Cons**: a child module may contain neither a `backend` block nor provider configuration, so
  both roots duplicate those anyway. Everything that actually differs — nodepool topology,
  locations, placement groups, autoscaler, NAT redundancy — becomes an *input* to the shared
  module, which re-creates exactly the stable input API that ADR-0002 refused. And the wrapper's
  only content would be opinions, which is the specific layer ADR-0002 says must not be abstracted.
- **Why not**: it overturns ADR-0002 in substance while claiming to respect it.

### Alternative 2: Two separate public repositories
- **Pros**: maximum isolation; each repository is unambiguously one fork target.
- **Cons**: doubles the sanitiser runs, the CI, the history scan and — decisively — **the number of
  irreversible publish steps**. The "choose V1 or V2" decision table belongs to neither repository.
  `LICENSE`, `NOTICE`, `THIRD_PARTY.md` and the ADR set must be duplicated or given a third home,
  and a forker comparing the two has to open two tabs to see a diff that should be one command.
- **Why not**: the two variants are the same architecture at two operating points. Splitting them
  destroys the comparison, which is the most useful thing this publication has to offer.

### Alternative 3: One root configuration with an `ha` feature flag
- **Pros**: zero duplication; one tree to maintain.
- **Cons**: three independent objections. (a) A flag that changes the *length* of
  `control_plane_nodepools` or `agent_nodepools` re-indexes kube-hetzner's index-keyed pools and
  **recreates running nodes** — the exact failure the in-tree comment at `main.tf:215-231` warns
  about. (b) V1 and V2 become the same root with the same backend key, so "V2 must never be
  plannable against production state" degrades from a structural property to a naming convention;
  one variable flipped in the production tfvars restructures production. (c) A flag *is* an input
  API, which ADR-0002 declined to promise.
- **Why not**: objection (b) alone makes the M3 gate unprovable.

### Alternative 4: Author V2 in the private repository, then fork both
- **Pros**: one authoring workflow; V2 gets the private repo's CI and review flow.
- **Cons**: places a configuration that is never applied inside the repository that *defines
  production*, where a mis-targeted `apply` has a live blast radius; and it puts V2 through the
  de-identification and sanitisation gates for no reason, since V2 has no history to clean.
- **Why not**: it adds production risk and sanitisation work to buy nothing.

## Consequences

### Positive
- **One sanitiser report, one PASS decision, one irreversible publish step.** The G4 gate keeps its
  "one FAIL = do not publish" semantics without being run twice against two decision-makers.
- **V2 is born clean.** Because it is authored downstream of de-identification, no internal
  identifier can reach it, and the history scan (axis A) still only ever concerns the private repo.
- **The comparison becomes a feature.** `diff -ru variants/solo variants/ha` is a legitimate way
  to read the repository, and `docs/managed-k8s-parity.md` has one obvious home.
- **The private repository is untouched structurally**, so the live workflow and the read-only plan
  procedure keep working exactly as documented.
- **"V2 can never plan against production state" becomes structural**: a separate directory, a
  partial backend with nothing committed, and no `backend.hcl` tracked anywhere in the tree.

### Negative
- **~1700 lines are duplicated** between the two variant directories, and a fix applied to one is
  not automatically applied to the other.
- **Backport gains a path mapping.** ADR-0003's rule (private is canonical for infrastructure
  behaviour) now needs a directory translation:
  `git -C <private> format-patch -1 <sha> --stdout | git -C <public> apply --directory=variants/solo`
  — and the reverse for public-origin fixes, which must be reviewed against the live cluster before
  they land privately.
- **Gate scripts must report per-variant.** A per-file grep that finds the same pattern twice looks
  like one deduplicated finding; the gate must print a PASS/FAIL line per variant directory so a
  fix in `solo` cannot be mistaken for a fix in `ha`.

### Risks
- **Silent drift between the variants.** Mitigation: `docs/variant-delta.md` is a generated,
  committed artefact (`diff -ru variants/solo variants/ha`, normalised); CI regenerates it and
  fails when the committed copy is stale. A change to one variant then either updates the other or
  forces an explicit, reviewed entry in the delta.
- **A forker copies the wrong directory.** Mitigation: the decision table sits above the fold in
  the root README, and each variant README opens by naming its own operating point and its
  trade-off against the other.
- **V2 is never exercised in production, so its failure modes are unproven.** Mitigation: the
  green-field proof (M4) applies V2 for real, and its smoke test explicitly includes a control-plane
  node kill and an etcd restore. Anything not proven there is stated as unproven in the V2 README.
