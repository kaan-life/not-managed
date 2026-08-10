#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Re-enable Hetzner delete-protection on floating IPs, volumes and load balancers.
#
# The counterpart to remove-protection.sh. Before this existed, the only script in the
# repository could take protection off and nothing could put it back, so an aborted
# teardown left every resource unprotected indefinitely — including in production, if
# the script had been run from the wrong directory.
#
#   ./restore-protection.sh --project prod            # dry run
#   ./restore-protection.sh --project prod --apply    # actually restores protection
#
# Note: unlike removal, restoring protection is a safe direction. It is still gated on
# --project so that it cannot silently protect resources in a project you did not mean
# to touch (which would make a later legitimate destroy fail in a confusing way).

set -euo pipefail
# shellcheck source=scripts/hcloud-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/hcloud-guard.sh"

guard_parse_args "$@"
guard_load_token
[ "$GUARD_REGISTER" -eq 1 ] && guard_register
[ "$GUARD_PROTECT" -eq 1 ] && guard_protect
guard_assert_project

RESOURCE_KINDS=(floating-ip volume load-balancer)

declare -a TARGETS=()
echo
echo "Unprotected resources visible to this token:"
for kind in "${RESOURCE_KINDS[@]}"; do
  # NB: read with the DEFAULT IFS, not IFS=$'\t'. Tab is IFS-whitespace, so a tab-only
  # IFS collapses leading empty fields — an empty line then parses as id="false" and a
  # phantom resource enters the target list. hcloud emits exactly one empty line when a
  # resource kind has no members, so that path is reached every time. Hetzner resource
  # names cannot contain whitespace, so default-IFS splitting is safe here.
  # The protection column prints the literal "delete" when set, and nothing when not.
  while read -r id name protection; do
    [ -z "${id:-}" ] && continue
    if [ "${protection:-}" != "delete" ]; then
      printf '  %-14s %-12s %s\n' "$kind" "$id" "$name"
      TARGETS+=("${kind}"$'\t'"${id}"$'\t'"${name}")
    fi
  done < <(hcloud "$kind" list -o noheader -o columns=id,name,protection 2>/dev/null)
done

COUNT=${#TARGETS[@]}
if [ "$COUNT" -eq 0 ]; then
  echo "  (none — everything is already protected)"
  exit 0
fi

echo
echo "Total: ${COUNT} unprotected resource(s) in project '${GUARD_PROJECT}'."

if guard_is_dry_run; then
  guard_dry_run_notice
  exit 0
fi

guard_confirm "protect" "$COUNT"

for entry in "${TARGETS[@]}"; do
  IFS=$'\t' read -r kind id name <<<"$entry"
  hcloud "$kind" enable-protection "$id" delete
  echo "  protected ${kind} ${id} (${name})"
done

echo
echo "Done. ${COUNT} resource(s) protected in '${GUARD_PROJECT}'."
