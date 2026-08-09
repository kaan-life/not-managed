# How these documents are maintained

Three kinds of file live in `docs/`, and they are edited in three different places. Editing
one in the wrong place loses the edit silently, so the rule is written here rather than
learned the hard way.

## 1. Authored upstream, copied here verbatim

`RUNBOOK.md` · `cost-comparison.md` · `managed-k8s-parity.md` · `adr/*.md` · this file

These are written in the maintainer's source repository and copied into the published tree
by an export script (ADR-0003 describes that relationship, and why the published repository
has its own clean history). The copy is byte-for-byte, and it **overwrites**. A paragraph
written directly into the published tree survives exactly until the next export.

If you are the maintainer: edit them at the source.

If you are a contributor: edit them here and open a pull request as normal. Documentation
changes are backported to the source by hand — that is the maintainer's problem, not yours,
and it is the reason a docs pull request may take an extra beat to land.

## 2. Generated

`variant-delta.md` — produced by `tools/gen-variant-delta.sh`, committed on purpose, and
checked for staleness in CI.

It carries a `Generated — do not edit` banner of its own. Regenerate it; do not hand-edit
it. It exists because the two variants are independent copies (ADR-0007), and a fix applied
to one and forgotten in the other is invisible in review unless something makes divergence
show up as a diff. This file is that something.

## 3. Written here and nowhere else

Everything at the repository root that exists *because* this tree is published rather than
because of anything the architecture does: `README.md`, `LICENSE`, `NOTICE`,
`THIRD_PARTY.md`, `CONTRIBUTING.md`, `SECURITY.md`, and `.github/`.

These have no meaning in a private source repository — it has no contributors, no security
reporting channel and nothing to attribute to anyone. They are authored in the published
tree, which is the only place they mean anything.

---

**The test, when it is unclear which category a new file is in:** does the file describe the
*system*, or the *publication of the system*? The system is documented upstream and exported.
The publication is documented here.
