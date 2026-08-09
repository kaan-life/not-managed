# ADR-0003: New public repository with clean history; the private repo stays private

**Date**: 2026-08-05
**Status**: accepted
**Deciders**: repository owner

## Context

The private repository's history contains real infrastructure identifiers and, per the comment at
`variables.tf:11`, a k3s join token leaked into a diagnostic session on 2026-06-10 — the same day as
the bulk of the early commits. History rewriting (`git filter-repo`) on a repository that other
clones and CI may reference is disruptive and never fully verifiable: a rewrite proves nothing about
what a stale fork or a cached object still holds.

Two facts constrain the choice:

- The private repository has five refs, including two remote feature branches, so any history-based
  approach must cover all of them, not just `main`.
- **Local `main` is 4 commits ahead of `origin/main`** (measured 2026-08-05): the ArgoCD webhook work
  (`23a9736`, `445f68c` and two merges) exists only on this machine. The publishable tree is local
  `main` (`047e2a3`), not `origin/main` (`9fe91d0`).

## Decision

Create a **new public repository** whose history starts with a single initial commit containing the
sanitized tree. The private repository stays private, is never rewritten, and is never force-pushed.
The fork is taken from **local `main`**, and the private repo's unpushed commits are pushed first so
the two agree.

## Alternatives Considered

### Alternative 1: Flip the existing repository to public after scrubbing history
- **Pros**: preserves authorship history and commit rationale; one repository to maintain.
- **Cons**: requires `filter-repo` plus force-push; leaked material may survive in forks, caches, PR
  refs and the GitHub API; and every historical commit would need to be sanitized, not just the tip.
- **Why not**: unverifiable. The only way to be certain nothing historical leaks is to not publish
  the history.

### Alternative 2: Squash the private repo's history in place, then publish
- **Pros**: keeps one repository.
- **Cons**: still a rewrite of the private repo (explicitly out of scope), and still force-pushes.
- **Why not**: same objection, plus it destroys the private repo's own useful history — the incident
  commits are operationally valuable internally.

## Consequences

### Positive
- Nothing historical can leak, because no history is published.
- The private repository keeps its full incident record intact for internal use.
- The public repository starts clean, with a curated initial commit.

### Negative
- Authorship and rationale history are lost publicly. Mitigation: the incident lessons are rewritten
  as in-code rationale and as `RUNBOOK.md` content, which is more useful to a reader than a commit log.
- The two trees diverge from day one, so changes must be moved deliberately.

### Risks
- **Silent divergence.** Bugs found during the green-field proof (G7) get fixed in the fork and are
  then missing privately. Mitigation — the backport rule: **the private repository is canonical for
  infrastructure behaviour; the public repository is canonical for documentation and packaging.**
  A change to behaviour lands privately first and is copied forward; a change to docs/CI lands
  publicly first and is copied back. Every G7 fix is backported before release is declared done.
- **Unpushed work exists on one machine only** — and that machine crashed on 2026-08-05. Push local
  `main` to `origin` before starting phase 0-B.
