#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

[[ "$#" == "0" ]] || {
  printf 'error: Usage: %s\n' "$0" >&2
  exit 1
}

printf 'Vela privileged cleanup diagnostic (read-only)\n'
printf 'This report never signals processes, unregisters services, or changes routes/proxies.\n'

printf '\n=== Vela-related processes ===\n'
if PROCESS_TABLE="$(/bin/ps -axo pid=,uid=,ppid=,lstart=,command= 2>/dev/null)"; then
  printf '%s\n' "${PROCESS_TABLE}" |
    /usr/bin/grep -E '[V]elaHelper|Contents/Helpers/[m]ihomo|Vendor/Mihomo/bin/[m]ihomo' || true
else
  printf 'unavailable: process inspection was denied\n'
fi

printf '\n=== utun interfaces (ownership cannot be inferred) ===\n'
/sbin/ifconfig -l |
  /usr/bin/tr ' ' '\n' |
  /usr/bin/grep '^utun' |
  /usr/bin/sort -V || true

printf '\n=== default IPv4 route ===\n'
/sbin/route -n get default 2>/dev/null || printf 'unavailable\n'

printf '\n=== default IPv6 route ===\n'
/sbin/route -n get -inet6 default 2>/dev/null || printf 'unavailable\n'

printf '\n=== system proxy state ===\n'
/usr/sbin/scutil --proxy 2>/dev/null || printf 'unavailable\n'

printf '\nNo cleanup was performed. An existing utun may belong to macOS or another app.\n'
