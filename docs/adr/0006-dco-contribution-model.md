# ADR-0006: DCO sign-off as the contribution model

**Date**: 2026-08-05
**Status**: accepted
**Deciders**: repository owner

## Context

A public repository needs a stated basis on which contributions are accepted. Without one, every
inbound pull request has ambiguous provenance: the maintainer cannot show that the contributor had
the right to submit the code. The two conventional options are a Developer Certificate of Origin
(a `Signed-off-by:` line per commit, verified by CI) and a Contributor License Agreement (a signed
document, usually requiring a bot and a record of signatures).

This project is a single-maintainer reference architecture (ADR-0002) with no relicensing ambition
and no corporate backer.

## Decision

Use the **DCO**. `CONTRIBUTING.md` explains `git commit -s`, and CI enforces the sign-off on every
commit in a pull request.

## Alternatives Considered

### Alternative 1: CLA
- **Pros**: allows future relicensing or dual-licensing; stronger paper trail.
- **Cons**: requires a signature-tracking bot and a legal document; a real deterrent for a one-line
  documentation fix.
- **Why not**: relicensing is not a goal, and the friction is disproportionate to a project people are
  expected to fork rather than contribute to.

### Alternative 2: No contribution model at all
- **Pros**: zero friction.
- **Cons**: provenance of inbound code is undocumented.
- **Why not**: the DCO costs one CI check and one line per commit. That is the cheapest defensible
  option, and cheaper than retrofitting one later.

## Consequences

### Positive
- Contributors assert their right to contribute, with no paperwork.
- Enforced mechanically in CI, so it cannot be forgotten in review.

### Negative
- Contributors who forget `-s` must amend and force-push their branch — mildly annoying; the CI
  failure message should say exactly how to fix it.
- Rules out a future relicensing that would need contributor consent.

### Risks
- Because ADR-0001 uses two licenses (Apache-2.0 plus MIT for derived files), a contribution to a
  derived file is a contribution under MIT. `CONTRIBUTING.md` must say so explicitly, otherwise
  contributors will assume Apache-2.0 everywhere.
