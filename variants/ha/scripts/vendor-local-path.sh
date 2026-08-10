#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Regenerate extra-manifests/local-path-provisioner.yaml.tpl from k3s upstream.
#
#   ./scripts/vendor-local-path.sh v1.33.13+k3s2          # write the template
#   ./scripts/vendor-local-path.sh v1.33.13+k3s2 --check  # fail if the committed copy is stale
#
# WHY THIS REPOSITORY VENDORS A k3s ADDON AT ALL.
#
# k3s ships local-path-provisioner as a "packaged component" and re-applies it on every
# start. That re-apply resets storageclass.kubernetes.io/is-default-class back to "true",
# which gives the cluster TWO default StorageClasses. Kubernetes tolerates that — it uses
# the most recently created one — but "which volume you get depends on object creation
# order" is not a property to run storage on, and the repair-on-apply approach means
# `terraform plan` is dirty after every reboot, which teaches people to stop reading plans.
#
# k3s' maintainers' own answer (k3s-io/k3s#4083) is to stop letting k3s own it and provide
# your own copy of the manifest. This script is that copy, generated rather than hand-
# edited, so that re-syncing after a k3s upgrade is one command and a diff.
#
# THE COST, STATED PLAINLY: k3s no longer updates local-path-provisioner. This repository
# does. Run this script after a k3s minor upgrade, diff the result, and decide.

set -euo pipefail

VERSION="${1:-}"
MODE="${2:-write}"
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
OUT="$ROOT/extra-manifests/local-path-provisioner.yaml.tpl"

# k3s substitutes this at deploy time; it is the default and it must match the path the
# existing volumes were provisioned into. Changing it strands nothing (a PV records its own
# hostPath) but sends NEW volumes somewhere else, which is a confusing way to run out of
# disk on one filesystem while another is empty.
STORAGE_PATH="${LOCAL_PATH_STORAGE_DIR:-/var/lib/rancher/k3s/storage}"

if [ -z "$VERSION" ]; then
  echo "usage: $0 <k3s-version> [--check]" >&2
  echo "       e.g. $0 \$(kubectl version -o json | jq -r .serverVersion.gitVersion)" >&2
  exit 2
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ENC=${VERSION//+/%2B}
URL="https://raw.githubusercontent.com/k3s-io/k3s/${ENC}/manifests/local-storage.yaml"

curl -fsSL "$URL" -o "$TMP/upstream.yaml" \
  || { echo "could not fetch $URL — is $VERSION a real k3s tag?" >&2; exit 1; }

# ── The transformation, in full. Every step is here so the diff against a new upstream
#    version is reproducible rather than a memory test. ─────────────────────────────────
python3 - "$TMP/upstream.yaml" "$TMP/out.tpl" "$VERSION" "$STORAGE_PATH" <<'PY'
import sys, re
src, dst, version, storage_path = sys.argv[1:5]
s = open(src).read()

# 1. k3s templating placeholders. These are substituted by k3s' own deploy controller,
#    which is exactly the thing we are removing from the path, so they must be resolved
#    here. They are also %{...}, which is Terraform DIRECTIVE syntax and would not parse.
s = s.replace('%{SYSTEM_DEFAULT_REGISTRY}%', '')
s = s.replace('%{DEFAULT_LOCAL_STORAGE_PATH}%', storage_path)
assert '%{' not in s, "an unhandled k3s placeholder remains — it would break templatefile()"

# 2. The whole point: this class must not claim to be the default. The cluster's default is
#    a CSI class that survives losing a node; local-path does not.
before = s
s = s.replace('storageclass.kubernetes.io/is-default-class: "true"',
              'storageclass.kubernetes.io/is-default-class: "false"')
assert s != before, "the is-default-class annotation was not found — upstream changed shape"

# 3. Escape shell interpolation for Terraform's templatefile(). The teardown script uses
#    ${VOL_DIR}; unescaped, Terraform tries to resolve it as a template variable and the
#    apply fails with "There is no variable named VOL_DIR".
s = s.replace('${', '$${')

header = f"""# GENERATED — DO NOT EDIT. Regenerate with:
#     ./scripts/vendor-local-path.sh {version}
#
# Vendored copy of k3s' packaged local-storage manifest, from
#     https://github.com/k3s-io/k3s/blob/{version}/manifests/local-storage.yaml
#
# Transformed in exactly four ways, all of them in the generator:
#   1. k3s' %-placeholders resolved (registry prefix removed, storage path = {storage_path})
#   2. is-default-class flipped to "false" — the cluster default is a replicated CSI class
#   3. shell interpolation escaped for Terraform's templatefile()
#   4. this header
#
# WHY IT IS HERE: k3s re-applies its packaged copy on every start, which resets the
# default-class annotation and leaves the cluster with two defaults. A .skip file (existing
# clusters) or --disable (fresh ones) stops that, and this file takes over the six objects
# k3s would otherwise own. See docs/RUNBOOK.md and k3s-io/k3s#4083.
#
# CONSEQUENCE: k3s upgrades no longer move local-path-provisioner. This file does.
"""
out = header + s

# The header is prose, and prose is where an unescaped interpolation sneaks back in — the
# first draft of this generator described the escaping using the very syntax it escapes,
# and templatefile() would have failed on the generator's own comment. Assert on the whole
# output, not just the manifest body.
import re as _re
bad = [m.start() for m in _re.finditer(r'(?<!\$)\$\{', out)]
assert not bad, (
    f"{len(bad)} unescaped ${{ in the output — templatefile() would fail to render it. "
    "Every literal dollar-brace must be doubled."
)
open(dst, 'w').write(out)
PY

if [ "$MODE" = "--check" ]; then
  if diff -q "$TMP/out.tpl" "$OUT" >/dev/null 2>&1; then
    echo "local-path-provisioner.yaml.tpl matches upstream $VERSION"
  else
    echo "STALE: the committed template does not match upstream $VERSION" >&2
    diff -u "$OUT" "$TMP/out.tpl" | head -60 >&2
    exit 1
  fi
else
  mkdir -p "$(dirname "$OUT")"
  cp "$TMP/out.tpl" "$OUT"
  echo "wrote $OUT"
  echo "  source  : $VERSION"
  echo "  image   : $(grep -oE 'local-path-provisioner:[^"]+' "$OUT" | head -1)"
  echo "  helper  : $(grep -oE 'mirrored-library-busybox:[^"]+' "$OUT" | head -1)"
  echo "  storage : $STORAGE_PATH"
fi
