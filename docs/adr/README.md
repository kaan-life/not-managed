# Architecture Decision Records

Decisions that shape this repository. Each record is self-contained: context, the decision,
the alternatives that were rejected, and the consequences.

ADR-001 through ADR-006 were recorded together on 2026-08-05 as the decision gate (G0) for
open-sourcing this repository. They are written in English because they travel to the public
repository.

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001](0001-apache-2-0-license.md) | Apache-2.0 as the project license, MIT retained for derived files | accepted | 2026-08-05 |
| [0002](0002-reference-architecture-not-module.md) | Publish as a reference architecture, not a reusable registry module | accepted | 2026-08-05 |
| [0003](0003-new-public-repo-clean-history.md) | New public repository with clean history; private repo stays private | accepted | 2026-08-05 |
| [0004](0004-terraform-only-opentofu-untested.md) | Terraform is the tested CLI; OpenTofu documented but untested | accepted | 2026-08-05 |
| [0005](0005-attribution-matrix.md) | Attribution matrix for upstream code and dependencies | accepted | 2026-08-05 |
| [0006](0006-dco-contribution-model.md) | DCO sign-off as the contribution model | accepted | 2026-08-05 |
| [0007](0007-two-forkable-variants-one-repository.md) | Two independently forkable root configurations in one public repository | accepted | 2026-08-08 |
| [0008](0008-gitops-companion-repository.md) | The reference architecture is two repositories; the GitOps repo is published too | accepted | 2026-08-08 |

ADR-0007 was recorded on 2026-08-08, when the objective changed from publishing one artefact to
publishing two variants — `variants/solo/` (the stack in production) and `variants/ha/` (what a
managed Kubernetes service provides that it does not). It refines ADR-0002 and ADR-0003 rather than
superseding them.
