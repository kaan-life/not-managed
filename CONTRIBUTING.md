# Contributing

Before anything else: **this repository is meant to be forked, not depended on.** It is a
reference architecture, not a module with a stable input API (`docs/adr/0002-reference-architecture-not-module.md`).
The most useful thing you can do with it is copy a variant directory, edit it until it
describes your cluster, and never speak to this repository again. That is success, not
avoidance.

Contributions are still welcome. They are just a smaller category than usual.

## Developer Certificate of Origin

Every commit must carry a `Signed-off-by:` line. Git writes it for you:

```bash
git commit -s -m "your message"
```

That line is your assertion of the [Developer Certificate of Origin](https://developercertificate.org/)
version 1.1 — in short, that you wrote the change or otherwise have the right to submit it
under the licenses below. There is no CLA, no bot to sign up with and no document to
countersign; the decision and its reasoning are in
`docs/adr/0006-dco-contribution-model.md`.

CI checks the sign-off on every commit in a pull request. If you forget it:

```bash
git commit --amend -s          # last commit only
git rebase --signoff main      # every commit on your branch
git push --force-with-lease
```

`--force-with-lease` rather than `--force`, so a push that would clobber someone else's
work fails instead of succeeding.

## Which license your contribution is under

This repository has **two**, and which one applies depends on the file you touched.

**The rule: Apache-2.0 unless the file's own `SPDX-License-Identifier` header says
otherwise.** `LICENSE` sets the default, so a file with no header is Apache-2.0.

Exactly one file is the exception, in each variant:

- `variants/*/packer/hcloud-microos-snapshots.pkr.hcl` — **MIT**, because it is
  effectively a copy of upstream's template with one change. A patch to it is a
  contribution under MIT.

`main.tf` is attributed in `NOTICE` but is **Apache-2.0**: it shares 30 of 249 substantive
unique lines with upstream's `kube.tf.example`, which is derivation at the level of
configuration rather than copying. The attribution is there out of caution; the licence is
the project's own. Its header says so, with the reasoning.

Two files carry no header at all — `scripts/apply-argocd-appset.py` and
`scripts/apply-github-secrets.py`. Their content is hashed into Terraform state, so adding
a comment to either one re-runs it against a live cluster. They are Apache-2.0 by the
default rule above, and the comment beside the hash in `github.tf` explains it.

The reasoning behind all of this is in `docs/adr/0001-apache-2-0-license.md` and the
measurements are in `docs/adr/0005-attribution-matrix.md`.

## Two variants, one repository

`variants/solo` and `variants/ha` are independent copies on purpose
(`docs/adr/0007-two-forkable-variants-one-repository.md`). There is no shared base module,
and there will not be one.

This means a fix in one variant is very often a fix in both, and forgetting the second one
is invisible in review — the diff of `solo/main.tf` says nothing about `ha/main.tf`.
`docs/variant-delta.md` is the guard against exactly that: it is a committed, generated
diff between the two directories, and CI fails when it is stale.

If you change a variant:

```bash
./tools/gen-variant-delta.sh          # regenerate
git add docs/variant-delta.md         # commit it in the same pull request
```

If your change belongs in only one variant, the delta will grow and that is correct. Say
why in the commit message, so the divergence is a decision on the record instead of an
omission somebody has to reconstruct later.

## The comments are the deliverable

Most of the value in this repository is not the HCL. It is why each line is the way it is:
a pinned CSI version because an older one reformatted a production volume during a node
failover; a cordon instead of a drain because a drain with nowhere to put the pods cordoned
a node for two and a half hours.

So:

- **A change that removes a comment needs to justify itself more than one that adds code.**
- **A pin without a reason is a bug report waiting to happen.** If you bump a version, say
  what you verified — not "should be compatible".
- Prefer a measurement to an adjective. "2m47s, measured with synthetic Pending pods" is
  worth ten times "fast".

## Before you open a pull request

```bash
cd variants/solo   # and again for variants/ha
terraform fmt -check *.tf
terraform init -backend=false
terraform validate
```

`-backend=false` is not a convenience. CI runs without cloud credentials of any kind, and
that is a hard requirement: a reference architecture whose CI needs secrets is one a forker
cannot run. If your change makes CI need a credential, it needs a different design.

From the repository root:

```bash
./tools/gen-variant-delta.sh --check
```

## Documentation changes

Some files under `docs/` are maintained outside this repository and copied in; some are
generated. `docs/README.md` says which is which and why. Read it before editing a document
— not because your edit is unwelcome, but because it may need to land somewhere else to
survive.

Editing a generated file (`docs/variant-delta.md`) is always wrong: regenerate it instead.

## Security issues

Do not open a pull request or an issue for a vulnerability. `SECURITY.md` has the private
reporting channel.

## What is unlikely to be merged

Stated up front so you do not spend an evening on it:

- **Refactoring the variants into a shared module.** Rejected twice, with reasons, in
  ADR-0002 and ADR-0007.
- **Adding an abstraction so this can be consumed as a dependency.** Same two ADRs. Fork it.
- **Upgrading `kube-hetzner` past 2.19.2 in `variants/solo`** without addressing the two
  competing constraints documented at the top of its `main.tf`. A proposal that engages
  with them is welcome; a version bump that does not will be sent back with a pointer to
  that comment.
- **Claiming OpenTofu compatibility** without a CI job that proves it (ADR-0004 chose to
  document it as untested rather than assert it).
