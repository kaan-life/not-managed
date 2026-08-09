# ADR-0005: Attribution matrix for upstream code and dependencies

**Date**: 2026-08-05
**Status**: accepted
**Deciders**: repository owner

## Context

Attribution obligations depend on whether code is **distributed** or merely **referenced**. Copying a
file creates an obligation; pinning a version number does not — a version string is not a
distribution of code. This ADR records what was measured, so `NOTICE` and `THIRD_PARTY.md` can be
written from evidence rather than assumption.

Verified on 2026-08-05 against the pinned versions.

### Distributed — attribution required

| Artefact | Evidence | License | Obligation |
|---|---|---|---|
| `packer/hcloud-microos-snapshots.pkr.hcl` | Differs from upstream v2.19.2 in **18 lines of ~210**; carries `creator = "kube-hetzner"` at lines 130 and 145. The only change is SHA256 verification of the MicroOS images. | MIT | **Yes** — keep MIT SPDX on the file, notice in `NOTICE` |
| `main.tf` | Shares **30 of 249** substantive unique lines with upstream `kube.tf.example` (~12%) — configuration-level derivation | MIT | **Yes**, out of caution — attribute the module and the example |

### Referenced only — no obligation, listed for completeness

| Component | Pinned | License | Why no obligation |
|---|---|---|---|
| `kube-hetzner/kube-hetzner/hcloud` module | 2.19.2 | MIT | fetched by Terraform at init; not vendored |
| argo-cd Helm chart (`argoproj/argo-helm`) | 8.2.5 | Apache-2.0 | fetched by Helm; not vendored |
| Argo CD itself | via chart | Apache-2.0 | container image |
| hcloud CSI driver | v2.22.0 | MIT | container image |
| hcloud cloud-controller-manager | v1.22.0 | Apache-2.0 | container image |
| kured | 1.21.0 | Apache-2.0 | container image |
| providers hcloud / helm / kubernetes / time | see ADR-0004 | MPL-2.0 | downloaded at init |
| provider github | `~> 6.12` | MIT | downloaded at init |

### Checked and cleared

`extra-manifests/kustomization.yaml.tpl` is five lines of generic Kustomize boilerplate (not
copyrightable). `extra-manifests/kured-patch-marker.yaml.tpl` is original work that *describes*
kube-hetzner's `extra_kustomize` mechanism but copies nothing from it. **No attribution obligation
from `extra-manifests/`.**

## Decision

`NOTICE` reproduces the upstream MIT permission text and attributes
`kube-hetzner/terraform-hcloud-kube-hetzner` by name, URL and pinned version (v2.19.2), covering both
the Packer template and `main.tf`. `THIRD_PARTY.md` lists every row above, including the
referenced-only components, with its license and the reason it is or is not an obligation.

## Alternatives Considered

### Alternative 1: Attribute only what is legally required (the Packer template)
- **Pros**: minimal, defensible.
- **Cons**: a reader diffing `main.tf` against `kube.tf.example` finds 30 shared lines and no mention.
- **Why not**: attribution costs a paragraph; a missing attribution is a license breach. When the
  question is close, answer it generously.

### Alternative 2: Vendor upstream `LICENSE` files for every dependency
- **Pros**: maximal transparency.
- **Cons**: none are distributed, so the files would be noise that goes stale.
- **Why not**: `THIRD_PARTY.md` with links and pinned versions conveys the same information and stays
  accurate.

## Consequences

### Positive
- Both `NOTICE` and `THIRD_PARTY.md` can be written directly from this table in G4.
- The distributed/referenced distinction is recorded, so future dependencies get classified the same way.

### Negative
- The matrix needs updating whenever a pin changes — add it to the upgrade checklist.

### Risks
- **Upstream's `LICENSE` has no copyright holder line** (see ADR-0001). Mitigation: reproduce the
  permission text verbatim and attribute by project name and URL rather than inventing a holder.
- The Packer template's SHA256 verification is a genuine improvement over upstream. Consider
  contributing it back; if upstream adopts it, this file's provenance note should be revisited.
