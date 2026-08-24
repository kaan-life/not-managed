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
# if/else, not `A && B`. Safe as written -- bash exempts a failing non-final member of an
# && list from errexit, so a zero flag does not abort -- but it is the same shape this
# sweep converted in scripts/assert-isolation.sh, and appending anything after it (or a
# `|| ...`) turns it into the silent-guard form.
if [ "$GUARD_REGISTER" -eq 1 ]; then guard_register; fi
if [ "$GUARD_PROTECT" -eq 1 ]; then guard_protect; fi
guard_assert_project

RESOURCE_KINDS=(floating-ip volume load-balancer)

declare -a TARGETS=()
declare -a FAILED_KINDS=()
echo
echo "Unprotected resources visible to this token:"
for kind in "${RESOURCE_KINDS[@]}"; do
  # NB: read with the DEFAULT IFS, not IFS=$'\t'. Tab is IFS-whitespace, so a tab-only
  # IFS collapses leading empty fields — an empty line then parses as id="false" and a
  # phantom resource enters the target list. The empty row still occurs, but no longer for
  # the reason this comment used to give: `$(...)` strips ALL trailing newlines, so
  # hcloud's own empty line is gone before `read` sees it, and it is `<<<` -- which always
  # presents at least one line -- that synthesises it. Either way the
  # `[ -z "${id:-}" ] && continue` below is what covers it.
  #
  # COLUMN ORDER IS LOAD-BEARING: the possibly-empty column must be LAST. Default IFS
  # collapses runs of whitespace anywhere, not only leading ones, so an empty INTERIOR
  # field shifts every later field left. Measured:
  #   id,name,protection  "42 web-01 "  -> id=42  name=web-01  protection=""   correct
  #   id,protection,name  "42  web-01"  -> id=42  protection=web-01  name=""   WRONG
  # A review proposed reordering to id,protection,name. That is the wrong direction:
  # `protection` is empty for every UNprotected resource, so making it interior breaks the
  # common case. `name` is the interior field today, and Hetzner auto-generates a name for
  # every kind listed here, so the hazard is real in principle and unreachable in practice.
  # Do not reorder these columns without re-deriving this.
  # The protection column prints the literal "delete" when set, and nothing when not.
  # The listing is captured FIRST so its exit status can be checked. It used to be a
  # process substitution with stderr discarded, and nothing consulted the status: a
  # failing `hcloud` (expired token, API blip, wrong project) produced an empty list,
  # COUNT stayed 0, and the script printed "(none -- nothing to do)" and exited 0.
  # Reproduced 2026-08-24 with a stub `hcloud` that fails on every call.
  #
  # In remove-protection.sh that silence is fail-SAFE -- doing nothing leaves protection
  # on. Here it is fail-DANGEROUS: the operator is told protection was restored when
  # nothing was protected, and the resources stay deletable. Same code, opposite
  # consequence, which is why "it is the same in both, so it is fine" is the wrong read.
  # stderr is deliberately NOT captured into $listing. Merging it with 2>&1 makes any
  # warning hcloud prints on a SUCCESSFUL call parse as a resource row -- measured: a
  # "warning: new hcloud version available" line became a phantom target whose id was
  # "warning:". Leaving stderr on the terminal keeps $listing to real rows and still puts
  # the error in front of the operator.
  # DELIBERATELY NOT guard_die HERE, and this is the one place the two scripts must
  # differ. guard_die exits immediately, so a failure on the second of three kinds would
  # discard the first kind's targets and protect NOTHING -- leaving those resources
  # deletable, which is the exact outcome this script exists to prevent. Aborting before
  # touching anything is right for remove-protection.sh, whose incomplete list is a reason
  # not to unprotect at all; it is wrong here, where the job is to leave as little
  # unprotected as possible. So: record the kind, carry on, protect everything that could
  # be listed, and fail at the end so the operator knows the pass was partial.
  if ! listing=$(hcloud "$kind" list -o noheader -o columns=id,name,protection); then
    echo "  WARNING: hcloud ${kind} list failed (its error is above) — skipping this kind" >&2
    FAILED_KINDS+=("$kind")
    continue
  fi
  while read -r id name protection; do
    [ -z "${id:-}" ] && continue
    if [ "${protection:-}" != "delete" ]; then
      printf '  %-14s %-12s %s\n' "$kind" "$id" "$name"
      TARGETS+=("${kind}"$'\t'"${id}"$'\t'"${name}")
    fi
  done <<<"$listing"
done

COUNT=${#TARGETS[@]}
if [ "$COUNT" -eq 0 ]; then
  if [ ${#FAILED_KINDS[@]} -gt 0 ]; then
    guard_die "nothing to protect among the kinds that listed, but these could not be listed at all: ${FAILED_KINDS[*]}"
  fi
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
if [ ${#FAILED_KINDS[@]} -gt 0 ]; then
  guard_die "PARTIAL: these kinds could not be listed and were NOT protected: ${FAILED_KINDS[*]}. Re-run once the listing works."
fi
