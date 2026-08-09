# ADR-0004: Terraform is the tested CLI; OpenTofu is documented but untested

**Date**: 2026-08-05
**Status**: accepted
**Deciders**: repository owner

## Context

Publishing HCL raises a licensing question that is widely misunderstood, so it is recorded here with
verified facts rather than folklore. Licenses checked on 2026-08-05 by reading each project's
`LICENSE` at the pinned tag:

| Component | Pinned | License (verified) |
|---|---|---|
| Terraform CLI | 1.15.6 locally | **BUSL-1.1** |
| Packer CLI (needed to build the MicroOS snapshots) | — | **BUSL-1.1** |
| OpenTofu | — | MPL-2.0 |
| `hashicorp/helm` provider | `~> 3.1` (v3.1.0) | **MPL-2.0** |
| `hashicorp/kubernetes` provider | `~> 3.0` (v3.0.0) | **MPL-2.0** |
| `hashicorp/time` provider | `~> 0.13` (v0.13.0) | **MPL-2.0** |
| `hetznercloud/hcloud` provider | `~> 1.60` (v1.60.0) | MPL-2.0 |
| `integrations/github` provider | `~> 6.12` (v6.12.0) | MIT |

Two conclusions follow. First, **the HashiCorp providers did not move to BUSL** — the 2023
relicensing hit the CLI tools (Terraform, Packer, Vault, Consul, Nomad), not the providers, which
remain MPL-2.0. Second, **BUSL does not restrict publishing HCL configuration at all**: it restricts
offering a competing commercial product, not writing, sharing or running configuration. Nothing about
this repository's publication is encumbered.

What *is* real: a user of this repository must run a BUSL-licensed CLI (Terraform) and, for the
snapshot build, a second BUSL-licensed CLI (Packer). Users in organisations with a policy against
BUSL tooling need to know that before they clone.

## Decision

**Terraform is the supported and tested CLI.** CI runs Terraform only. The README states the BUSL
situation factually, notes that OpenTofu exists as an MPL-2.0 alternative, and says plainly that
OpenTofu is **untested here**. No compatibility claim is made without a test to back it.

## Alternatives Considered

### Alternative 1: Test both in a CI matrix and claim dual support
- **Pros**: widens the audience; OpenTofu users get a guarantee.
- **Cons**: doubles CI surface, and the guarantee has to hold for real — the backend uses
  `use_lockfile` (native S3 state locking, Terraform 1.10+), whose OpenTofu equivalence is not
  verified. The upstream kube-hetzner module also targets Terraform.
- **Why not**: not rejected forever — rejected *now*. Adding a `tofu` CI job is roughly ten lines,
  so this is cheap to revisit once someone actually wants it.

### Alternative 2: Switch to OpenTofu as the primary CLI
- **Pros**: fully MPL-2.0 toolchain, no BUSL anywhere except Packer.
- **Cons**: the live cluster runs Terraform state today; migrating the production stack is a separate
  project with its own risk analysis, and Packer would still be BUSL.
- **Why not**: out of scope. The goal is publishing what runs, not changing what runs.

## Consequences

### Positive
- The compatibility promise matches what CI actually proves.
- Readers get the BUSL facts, including the correction that the providers are MPL-2.0.

### Negative
- OpenTofu users must try it themselves and may hit `use_lockfile` differences.

### Risks
- The BUSL landscape may shift again. Mitigation: the table above records the date and the exact
  pinned versions that were checked, so a future reader knows what was true and when.
