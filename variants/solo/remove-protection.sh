#!/bin/bash
# Remove Hetzner delete-protection from floating IPs, volumes and load balancers so that
# `terraform destroy` can complete. main.tf sets enable_delete_protection on all three,
# which is deliberate: it is what stops an accidental destroy. This script is the
# deliberate counterpart, and restore-protection.sh puts it back.
#
# ONLY run this against a throwaway project. See scripts/hcloud-guard.sh for why this
# script now demands --project and a typed confirmation: its previous form iterated over
# every resource the token could reach, with no project filter and no prompt.
#
#   ./remove-protection.sh --project test            # dry run, lists what it would do
#   ./remove-protection.sh --project test --apply    # actually removes protection

set -euo pipefail
GUARD_DESTRUCTIVE=1   # this script destroys or weakens resources
# shellcheck source=scripts/hcloud-guard.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/hcloud-guard.sh"

guard_parse_args "$@"
guard_load_token
[ "$GUARD_REGISTER" -eq 1 ] && guard_register
[ "$GUARD_PROTECT" -eq 1 ] && guard_protect
guard_assert_project

RESOURCE_KINDS=(floating-ip volume load-balancer)

# Collect everything that is currently protected, and show it by NAME before asking.
# The old script printed only IDs, after the fact.
declare -a TARGETS=()
echo
echo "Protected resources visible to this token:"
for kind in "${RESOURCE_KINDS[@]}"; do
  # NB: read with the DEFAULT IFS, not IFS=$'\t'. Tab is IFS-whitespace, so a tab-only
  # IFS collapses leading empty fields — an empty line then parses as id="false" and a
  # phantom resource enters the target list. hcloud emits exactly one empty line when a
  # resource kind has no members, so that path is reached every time. Hetzner resource
  # names cannot contain whitespace, so default-IFS splitting is safe here.
  # The protection column prints the literal "delete" when set, and nothing when not.
  while read -r id name protection; do
    [ -z "${id:-}" ] && continue
    if [ "${protection:-}" = "delete" ]; then
      printf '  %-14s %-12s %s\n' "$kind" "$id" "$name"
      TARGETS+=("${kind}"$'\t'"${id}"$'\t'"${name}")
    fi
  done < <(hcloud "$kind" list -o noheader -o columns=id,name,protection 2>/dev/null)
done

COUNT=${#TARGETS[@]}
if [ "$COUNT" -eq 0 ]; then
  echo "  (none — nothing to do)"
  exit 0
fi

echo
echo "Total: ${COUNT} protected resource(s) in project '${GUARD_PROJECT}'."

if guard_is_dry_run; then
  guard_dry_run_notice
  exit 0
fi

guard_confirm "unprotect" "$COUNT"

for entry in "${TARGETS[@]}"; do
  IFS=$'\t' read -r kind id name <<<"$entry"
  hcloud "$kind" disable-protection "$id" delete
  echo "  unprotected ${kind} ${id} (${name})"
done

echo
echo "Done. ${COUNT} resource(s) unprotected in '${GUARD_PROJECT}'."
echo "Run ./restore-protection.sh --project ${GUARD_PROJECT} --apply to put protection back."
