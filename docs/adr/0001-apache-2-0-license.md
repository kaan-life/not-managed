# ADR-0001: Apache-2.0 as the project license, MIT retained for derived files

**Date**: 2026-08-05
**Status**: accepted
**Deciders**: repository owner

## Context

This repository is being published as a public reference architecture. It has no license today,
which means "all rights reserved" — nobody may legally fork or reuse it. It also contains code
derived from [kube-hetzner/terraform-hcloud-kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner)
(MIT), so the outbound license must be compatible with MIT and must not strip the inbound notice.

Measured derivation (see ADR-0005 for the full matrix):

- `packer/hcloud-microos-snapshots.pkr.hcl` differs from upstream v2.19.2 in **18 lines out of ~210**
  — it is effectively a copy with one security improvement (SHA256 verification of the MicroOS images).
- `main.tf` shares **30 of 249** substantive unique lines with upstream's `kube.tf.example` (~12%),
  which is configuration-level derivation rather than copying.

## Decision

The project is licensed **Apache-2.0**. Files that are substantially derived from MIT-licensed
upstream code keep an **MIT** SPDX identifier and carry the upstream notice; every other file gets
`SPDX-License-Identifier: Apache-2.0`. `NOTICE` and `THIRD_PARTY.md` carry the attribution.

## Alternatives Considered

### Alternative 1: MIT for everything
- **Pros**: identical to upstream, zero compatibility questions, shortest text.
- **Cons**: no explicit patent grant; no `NOTICE` convention, so upstream attribution has no natural home.
- **Why not**: infrastructure code is exactly where an explicit patent grant is cheap insurance, and
  the `NOTICE` file is the mechanism that keeps upstream attribution visible over time.

### Alternative 2: Apache-2.0 for every file, including the derived Packer template
- **Pros**: one identifier, simplest tooling story.
- **Cons**: relicensing a near-verbatim MIT file as Apache-2.0 is permitted (MIT grants sublicensing)
  but obscures its origin, and a reader diffing against upstream would find a license mismatch with
  no explanation.
- **Why not**: honesty about provenance costs one SPDX line per file and removes all ambiguity.

### Alternative 3: No license / source-available
- **Why not**: defeats the purpose. A reference architecture nobody may fork is a screenshot.

## Consequences

### Positive
- Forking is unambiguously permitted, with a patent grant.
- Upstream attribution has a defined home (`NOTICE`), satisfying MIT's notice-retention requirement.
- Per-file SPDX headers make provenance machine-readable (and REUSE-compliance reachable later).

### Negative
- Two licenses in one repository requires discipline: every new file needs the right SPDX header,
  and CI should check for missing headers.
- Apache-2.0 is longer and slightly more legalistic than MIT — a small friction for casual readers.

### Risks
- **Upstream's `LICENSE` contains the MIT permission text but no copyright holder line.** MIT says
  "the above copyright notice … shall be included", and there is none to include. Mitigation:
  attribute by project name, repository URL and pinned version, and reproduce the upstream permission
  text verbatim in `NOTICE`. This over-satisfies the obligation rather than guessing at a holder.
- If the derived Packer changes are ever upstreamed, the file may converge back to pure upstream —
  revisit the per-file identifier then.
