#!/bin/bash
# Regenerate docs/variant-delta.md from the two variant directories.
#
#   ./tools/gen-variant-delta.sh          # write the file
#   ./tools/gen-variant-delta.sh --check  # fail if the committed copy is stale (CI)
#
# WHY THIS IS A COMMITTED, GENERATED FILE. The two variants duplicate roughly 1700 lines
# (ADR-0007 accepted that on purpose). Duplication is fine while it is visible and fatal
# once it is not: a fix applied to one variant and forgotten in the other is invisible in
# review, because nothing in either diff mentions the other file. Committing the delta
# makes every divergence show up as a change to THIS file, in the same pull request.
#
# The diff is normalised — no timestamps, no absolute paths — or it would differ on every
# run and the staleness check would be noise.

set -euo pipefail
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
OUT="$ROOT/docs/variant-delta.md"
MODE="${1:-write}"

command -v diff >/dev/null || { echo "diff not found" >&2; exit 1; }

generate() {
  cat <<'HEADER'
# Variant delta

**Generated — do not edit.** Regenerate with `./tools/gen-variant-delta.sh`.

The exact difference between `variants/solo` and `variants/ha`. The two directories are
independent copies by design (ADR-0007), so this file is how divergence stays visible: a
change to one variant that should have been made to both shows up here, in the same pull
request that caused it.

Everything below is `diff -ru variants/solo variants/ha`, with timestamps stripped.

```diff
HEADER
  # --no-dereference is not portable; -r is enough here. Build artefacts are excluded so
  # the delta describes the configuration, not whatever someone last ran locally.
  ( cd "$ROOT" && diff -ru \
      -x '.terraform' -x '.terraform.lock.hcl' -x 'backend.hcl' -x 'secrets.auto.tfvars' \
      -x '*.tfstate*' -x '__pycache__' \
      variants/solo variants/ha || true ) \
    | sed -E 's/^(---|\+\+\+) ([^\t]+)\t.*/\1 \2/'
  echo '```'
}

if [ "$MODE" = "--check" ]; then
  TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
  generate > "$TMP"
  if diff -q "$TMP" "$OUT" >/dev/null 2>&1; then
    echo "variant-delta.md is up to date"
  else
    echo "variant-delta.md is STALE — run ./tools/gen-variant-delta.sh and commit the result" >&2
    diff -u "$OUT" "$TMP" | head -40 >&2
    exit 1
  fi
else
  generate > "$OUT"
  echo "wrote $OUT ($(wc -l < "$OUT") lines)"
fi
