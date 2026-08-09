# ADR-0002: Publish as a reference architecture, not a reusable registry module

**Date**: 2026-08-05
**Status**: accepted
**Deciders**: repository owner

## Context

There are two ways to publish Terraform code: as a **module** consumed via `source = "..."`, or as a
**reference architecture** that people fork and edit. The choice determines the API contract, the
support burden, and what users are entitled to expect.

This repository is a root module: it contains a `backend "s3"` block, configured `provider` blocks,
shell scripts that drive `terraform apply`, and opinionated choices (Tailscale-only kube-API, a NAT
router, a dedicated egress node, a specific kured reboot window). Those are all things a *root*
module owns and a *child* module must not.

## Decision

Publish as a **reference architecture**. The README states this prominently: one opinionated stack
that works for one operator's use case, meant to be forked and adapted — not a general-purpose
module, and not something with a stable input API.

## Alternatives Considered

### Alternative 1: Refactor into a reusable registry module under `modules/`
- **Pros**: consumable by `source =`, versioned releases, discoverable on the registry.
- **Cons**: a child module may not contain a `backend` block or `provider` configuration, so the
  refactor means splitting the repository and redesigning every input; and it creates an implicit
  promise of API stability across versions.
- **Why not**: the underlying reusable module already exists — it is `kube-hetzner`, which this
  repository *consumes*. Wrapping it in another module adds a layer whose only content is opinions,
  which is precisely the part that should not be abstracted.

### Alternative 2: Publish as a template repository ("Use this template" button)
- **Pros**: GitHub-native forking flow.
- **Cons**: orthogonal to this decision — a reference architecture can also be a template repo.
- **Why not**: not rejected; adopt it later as a convenience. It does not change the contract.

## Consequences

### Positive
- No API-stability promise, so `main.tf` may keep its opinions and its incident-driven workarounds.
- Users who fork own their copy outright, which is the honest model for infrastructure this specific.
- Documentation can explain *why* each choice was made instead of parameterising everything.

### Negative
- No registry discoverability; adoption depends on the README and word of mouth.
- Improvements do not flow back to users automatically — a forker must rebase manually.

### Risks
- Users may still treat it as a module and file issues expecting general applicability. Mitigation:
  the "What this is NOT" section sits at the top of the README, not buried at the bottom.
