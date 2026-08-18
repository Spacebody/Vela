#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

APP="${1:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Release binary scan requires macOS"
[[ -d "${APP}" && ! -L "${APP}" && "${APP}" == *.app ]] || fail "Usage: $0 /path/to/Vela.app"
[[ ! -L "${APP}/Contents/MacOS/Vela" && -f "${APP}/Contents/MacOS/Vela" ]] || fail "Vela binary is missing or unsafe"
FORBIDDEN='VELA_TEST_FAULT_PLAN|FaultInjectionPoint|FaultInjector|FaultRule|testInsufficientDisk|tun.waitForController|support.export.write'
scanned=0
while IFS= read -r -d '' candidate; do
  if ! /usr/bin/file -b "${candidate}" | /usr/bin/grep -q 'Mach-O'; then
    continue
  fi
  scanned=$((scanned + 1))
  if /usr/bin/strings -a "${candidate}" | /usr/bin/grep -Eq "${FORBIDDEN}"; then
    fail "Release Mach-O contains a fault-control string: ${candidate#"${APP}"/}"
  fi
  if /usr/bin/nm -j "${candidate}" 2>/dev/null | /usr/bin/grep -Eq 'FaultInject|FaultRule'; then
    fail "Release Mach-O contains a fault-control symbol: ${candidate#"${APP}"/}"
  fi
done < <(/usr/bin/find "${APP}" -type f -print0)
[[ "${scanned}" -gt 0 ]] || fail "Release bundle contains no scannable Mach-O files"
printf 'Scanned %s Release Mach-O files; no known V0.8 fault controls found.\n' "${scanned}"
