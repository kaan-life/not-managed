#!/bin/bash
# Shared safety guard for scripts that mutate Hetzner Cloud resources.
#
# WHY THIS EXISTS
# ---------------
# The original remove-protection.sh read the API token out of ./secrets.auto.tfvars
# (relative to the *current working directory*) and then iterated over EVERY floating
# IP, volume and load balancer that token could reach, with no project filter and no
# confirmation. Running it from the wrong directory would strip delete-protection from
# production. destroy.sh had the same cwd-relative credential load followed by four
# `terraform destroy -auto-approve` calls.
#
# A Hetzner API token carries no project name, so a script cannot ask "which project am
# I pointed at?". This guard closes that gap by making the operator *declare* the target
# project and then proving the declaration: the token is fingerprinted (SHA-256, first
# 12 hex characters — never the token itself) and checked against a locally registered
# fingerprint. A token that is not registered, or that belongs to a different project
# than the one named on the command line, aborts before anything is touched.
#
# Registration is a one-time, deliberate act:
#   ./remove-protection.sh --project prod --register
#
# The registry lives in hcloud-projects.conf, which is gitignored and never published.
#
# Every consumer of this library is dry-run by default. Mutating requires --apply AND a
# typed confirmation phrase that names the project and the resource count, so muscle
# memory ("y<enter>") cannot approve it.

set -euo pipefail

GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_REGISTRY="${GUARD_DIR}/hcloud-projects.conf"

GUARD_PROJECT=""
GUARD_APPLY=0
GUARD_REGISTER=0
GUARD_PROTECT=0

# A consuming script sets this to 1 before calling guard_parse_args if it can destroy
# or weaken something. Scripts that only move in the safe direction (restore-protection.sh)
# leave it at 0, so they keep working on projects marked protected.
GUARD_DESTRUCTIVE="${GUARD_DESTRUCTIVE:-0}"

guard_die() { echo "ERROR: $*" >&2; exit 1; }

guard_usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --project <name> [--apply] [--register] [--protect]

  --project <name>  REQUIRED. The Hetzner project this run is allowed to touch.
                    Checked against the token fingerprint in hcloud-projects.conf.
  --apply           Actually make changes. Without it the script only reports (dry run).
  --register        Register the current token's fingerprint under --project and exit.
                    Refuses to overwrite an existing registration.
  --protect         Mark --project as protected and exit. Destructive scripts then refuse
                    it outright, whatever else you type. Combine with --register to
                    register and protect in one go.
                    Removing the mark is deliberately NOT a flag: edit
                    hcloud-projects.conf by hand and delete the leading '!'.
EOF
  exit 2
}

guard_parse_args() {
  [ $# -eq 0 ] && guard_usage
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) [ $# -ge 2 ] || guard_die "--project needs a value"; GUARD_PROJECT="$2"; shift 2 ;;
      --apply)    GUARD_APPLY=1; shift ;;
      --register) GUARD_REGISTER=1; shift ;;
      --protect)  GUARD_PROTECT=1; shift ;;
      -h|--help)  guard_usage ;;
      *) guard_die "unknown argument: $1 (see --help)" ;;
    esac
  done
  [ -n "$GUARD_PROJECT" ] || guard_die "--project is required. This script refuses to guess which project it is pointed at."
  case "$GUARD_PROJECT" in
    *[!A-Za-z0-9_-]*) guard_die "--project may only contain letters, digits, '-' and '_'" ;;
  esac
}

# Load the token from the tfvars file next to THIS script, never from $PWD.
# This alone removes the "wrong cwd" failure mode that motivated the guard.
guard_load_token() {
  local tfvars="${GUARD_DIR}/secrets.auto.tfvars"
  [ -f "$tfvars" ] || guard_die "not found: ${tfvars}"
  HCLOUD_TOKEN=$(sed -n 's/^[[:space:]]*hcloud_token[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$tfvars")
  [ -n "${HCLOUD_TOKEN:-}" ] || guard_die "hcloud_token not found in ${tfvars}"
  export HCLOUD_TOKEN
  command -v hcloud >/dev/null || guard_die "the 'hcloud' CLI is not installed"
}

# SHA-256 of the token, truncated. Enough to tell two projects apart; useless to an
# attacker who obtains the registry file, and safe to print in logs.
guard_fingerprint() {
  printf '%s' "${HCLOUD_TOKEN}" | sha256sum | cut -c1-12
}

# The registry line for --project, with or without the leading '!' protection marker.
guard_registry_line() {
  [ -f "$GUARD_REGISTRY" ] || return 1
  grep -E "^!?${GUARD_PROJECT}:" "$GUARD_REGISTRY" | head -1
}

guard_is_protected() {
  case "$(guard_registry_line 2>/dev/null)" in ('!'*) return 0 ;; (*) return 1 ;; esac
}

guard_register() {
  local fp line existing; fp=$(guard_fingerprint)
  if line=$(guard_registry_line) && [ -n "$line" ]; then
    existing=$(printf '%s' "$line" | cut -d: -f2)
    if [ "$existing" = "$fp" ]; then
      echo "Project '${GUARD_PROJECT}' is already registered with this token (${fp})."
      [ "$GUARD_PROTECT" -eq 1 ] && guard_protect
      exit 0
    fi
    guard_die "project '${GUARD_PROJECT}' is already registered to a DIFFERENT token (${existing}, current ${fp}).
Refusing to overwrite. If the token was rotated, edit ${GUARD_REGISTRY} by hand and know why."
  fi
  umask 077
  printf '%s%s:%s\n' "$([ "$GUARD_PROTECT" -eq 1 ] && printf '!')" "$GUARD_PROJECT" "$fp" >> "$GUARD_REGISTRY"
  echo "Registered project '${GUARD_PROJECT}' with token fingerprint ${fp}."
  [ "$GUARD_PROTECT" -eq 1 ] && echo "Marked PROTECTED: destructive scripts will refuse it outright."
  echo "Registry: ${GUARD_REGISTRY} (gitignored — never commit it)."
  exit 0
}

# Marking a project protected is easy on purpose. Un-marking is not: it needs a hand
# edit. Safety rails you can remove with a flag are safety rails you remove by accident.
guard_protect() {
  guard_registry_line >/dev/null 2>&1 || guard_die "project '${GUARD_PROJECT}' is not registered — register it first."
  if guard_is_protected; then
    echo "Project '${GUARD_PROJECT}' is already protected."
  else
    sed -i "s/^${GUARD_PROJECT}:/!${GUARD_PROJECT}:/" "$GUARD_REGISTRY"
    echo "Project '${GUARD_PROJECT}' is now PROTECTED."
    echo "Destructive scripts will refuse it outright. To undo, edit ${GUARD_REGISTRY}"
    echo "by hand and remove the leading '!' — there is deliberately no flag for that."
  fi
  exit 0
}

# Abort unless the declared project matches the token actually loaded, and unless the
# project tolerates what this script does.
guard_assert_project() {
  local fp line expected; fp=$(guard_fingerprint)
  [ -f "$GUARD_REGISTRY" ] || guard_die "no project registry at ${GUARD_REGISTRY}.
Register this token first:  $(basename "$0") --project ${GUARD_PROJECT} --register"
  line=$(guard_registry_line) && [ -n "$line" ] || guard_die "project '${GUARD_PROJECT}' is not registered.
Registered projects: $(sed 's/:.*//' "$GUARD_REGISTRY" | paste -sd', ' -)
Register it with:  $(basename "$0") --project ${GUARD_PROJECT} --register"
  expected=$(printf '%s' "$line" | cut -d: -f2)
  [ "$expected" = "$fp" ] || guard_die "TOKEN/PROJECT MISMATCH — aborting before touching anything.
  --project says : ${GUARD_PROJECT} (registered fingerprint ${expected})
  token loaded is: fingerprint ${fp}
The token in ${GUARD_DIR}/secrets.auto.tfvars does not belong to '${GUARD_PROJECT}'.
This is exactly the accident this guard exists to prevent."

  if [ "$GUARD_DESTRUCTIVE" -eq 1 ] && guard_is_protected; then
    guard_die "project '${GUARD_PROJECT}' is marked PROTECTED in ${GUARD_REGISTRY}.
$(basename "$0") destroys or weakens resources, so it refuses this project outright —
there is no flag, no --force and no --apply that overrides this.
If you genuinely mean to run it here, edit the registry by hand and remove the leading
'!' from the '${GUARD_PROJECT}' line. That edit is the confirmation."
  fi

  echo "Project guard OK: '${GUARD_PROJECT}' (token fingerprint ${fp}$(guard_is_protected && printf ', PROTECTED — read-only operations only'))"
}

# Typed confirmation naming both the project and the resource count, so an operator
# cannot approve by reflex and cannot approve a larger blast radius than they read.
guard_confirm() {
  local verb="$1" count="$2"
  local phrase="${verb} ${count} in ${GUARD_PROJECT}"
  echo
  echo "About to ${verb} ${count} resource(s) in project '${GUARD_PROJECT}'."
  echo "Type exactly the following to proceed (anything else aborts):"
  echo "  ${phrase}"
  local typed=""
  read -r -p "> " typed || true
  [ "$typed" = "$phrase" ] || guard_die "confirmation did not match — nothing was changed."
}

guard_is_dry_run() { [ "$GUARD_APPLY" -eq 0 ]; }

guard_dry_run_notice() {
  echo
  echo "DRY RUN — nothing was changed. Re-run with --apply to actually do this."
}
