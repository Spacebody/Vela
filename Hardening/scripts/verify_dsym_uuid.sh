#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

BINARY="${1:-}"
DSYM="${2:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "dSYM verification requires macOS"
[[ -f "${BINARY}" && ! -L "${BINARY}" && -d "${DSYM}" && ! -L "${DSYM}" ]] || fail "Usage: $0 /path/to/binary /path/to/binary.dSYM"

BINARY_UUIDS="$(/usr/bin/dwarfdump --uuid "${BINARY}" | /usr/bin/awk '{print toupper($2) ":" $3}' | /usr/bin/sort -u)"
DSYM_UUIDS="$(/usr/bin/dwarfdump --uuid "${DSYM}" | /usr/bin/awk '{print toupper($2) ":" $3}' | /usr/bin/sort -u)"
[[ -n "${BINARY_UUIDS}" && "${BINARY_UUIDS}" == "${DSYM_UUIDS}" ]] || fail "binary and dSYM UUID/architecture sets do not match"
printf '%s\n' "${BINARY_UUIDS}"
