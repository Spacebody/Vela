#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

OUTPUT="${1:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This script requires macOS"
[[ -n "${OUTPUT}" ]] || fail "Usage: $0 /path/to/cleanup-evidence.txt"
[[ ! -e "${OUTPUT}" ]] || fail "refusing to overwrite ${OUTPUT}"
[[ -d "$(dirname "${OUTPUT}")" ]] || fail "output parent does not exist"

TMP="$(/usr/bin/mktemp "$(dirname "${OUTPUT}")/.vela-cleanup.XXXXXX")"
trap '/bin/rm -f "${TMP}"' EXIT
/bin/chmod 0600 "${TMP}"

{
  printf '=== timestamp UTC ===\n'
  /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'

  printf '\n=== Vela-related process identities (read-only) ===\n'
  /bin/ps -axo pid=,ppid=,uid=,comm= | /usr/bin/grep -E '[V]ela|[m]ihomo' || true

  printf '\n=== utun interface names (ownership is not inferred) ===\n'
  /sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/grep '^utun' || true

  printf '\n=== default IPv4 route (private lab evidence; redact before export) ===\n'
  /sbin/route -n get default 2>/dev/null || true

  printf '\n=== default IPv6 route (private lab evidence; redact before export) ===\n'
  /sbin/route -n get -inet6 default 2>/dev/null || true

  printf '\n=== system proxy state (private lab evidence; redact before export) ===\n'
  /usr/sbin/scutil --proxy || true

  printf '\nThis command is read-only. Vela internal ownership checks remain authoritative.\n'
} > "${TMP}"

/bin/mv "${TMP}" "${OUTPUT}"
trap - EXIT
printf 'Cleanup evidence saved to %s\n' "${OUTPUT}"
