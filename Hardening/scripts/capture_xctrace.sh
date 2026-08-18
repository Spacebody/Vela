#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

TEMPLATE="${1:-}"
PROCESS="${2:-}"
DURATION="${3:-60s}"
OUTPUT="${4:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "xctrace requires macOS"
[[ -n "${TEMPLATE}" && -n "${PROCESS}" && -n "${OUTPUT}" ]] || fail "Usage: $0 'Time Profiler' Vela 60s /path/to/output.trace"
[[ "${PROCESS}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid exact process name"
[[ "${DURATION}" =~ ^[1-9][0-9]*[smh]$ ]] || fail "duration must be an integer followed by s, m, or h"
[[ ! -e "${OUTPUT}" ]] || fail "refusing to overwrite ${OUTPUT}"

AVAILABLE="$(/usr/bin/xcrun xctrace list templates 2>&1)"
printf '%s\n' "${AVAILABLE}" | /usr/bin/grep -Fq "${TEMPLATE}" || {
  printf '%s\n' "${AVAILABLE}" >&2
  fail "template not available in this Xcode: ${TEMPLATE}"
}
/usr/bin/pgrep -x "${PROCESS}" >/dev/null || fail "process is not running: ${PROCESS}"

printf 'Recording template=%s process=%s duration=%s\n' "${TEMPLATE}" "${PROCESS}" "${DURATION}"
/usr/bin/xcrun xctrace record \
  --template "${TEMPLATE}" \
  --attach "${PROCESS}" \
  --time-limit "${DURATION}" \
  --output "${OUTPUT}"
printf 'Trace saved to %s; keep it private and redact any export.\n' "${OUTPUT}"
