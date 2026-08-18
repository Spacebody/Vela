#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

PROCESS="${1:-Vela}"
OUTPUT="${2:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This script requires macOS"
[[ "${PROCESS}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid exact process name"
[[ -n "${OUTPUT}" ]] || fail "Usage: $0 ProcessName /path/to/output.json"
[[ ! -e "${OUTPUT}" ]] || fail "refusing to overwrite ${OUTPUT}"
[[ -d "$(dirname "${OUTPUT}")" ]] || fail "output parent does not exist"

PIDS="$(/usr/bin/pgrep -x "${PROCESS}" || true)"
[[ -n "${PIDS}" ]] || fail "No process named ${PROCESS}"

TMP="$(/usr/bin/mktemp "$(dirname "${OUTPUT}")/.vela-resource.XXXXXX")"
trap '/bin/rm -f "${TMP}"' EXIT
/bin/chmod 0600 "${TMP}"

{
  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "processName": "%s",\n' "${PROCESS}"
  printf '  "snapshots": [\n'
  first=1
  while IFS= read -r selected_pid; do
    [[ "${selected_pid}" =~ ^[0-9]+$ ]] || continue
    PS_LINE="$(/bin/ps -o pid=,ppid=,uid=,%cpu=,rss=,thcount=,etime= -p "${selected_pid}" 2>/dev/null || true)"
    [[ -n "${PS_LINE}" ]] || continue
    # Deliberately override the script's newline-only IFS for the fixed seven
    # whitespace-delimited ps columns. This fixes the pack template's parsing bug.
    IFS=$' \t' read -r pid_value ppid_value uid_value cpu_value rss_value thread_value elapsed_value <<< "${PS_LINE}"
    [[ "${pid_value}" =~ ^[0-9]+$ && "${ppid_value}" =~ ^[0-9]+$ && "${uid_value}" =~ ^[0-9]+$ ]] || fail "unexpected ps output"
    [[ "${cpu_value}" =~ ^[0-9]+([.][0-9]+)?$ && "${rss_value}" =~ ^[0-9]+$ && "${thread_value}" =~ ^[0-9]+$ ]] || fail "unexpected resource fields"
    [[ "${elapsed_value}" =~ ^[0-9:-]+$ ]] || fail "unexpected elapsed field"

    FD_COUNT="$(/usr/sbin/lsof -nP -p "${pid_value}" -Fn 2>/dev/null | /usr/bin/grep -c '^f' || true)"
    SOCKET_COUNT="$(/usr/sbin/lsof -nP -a -p "${pid_value}" -i -Fn 2>/dev/null | /usr/bin/grep -c '^f' || true)"
    [[ "${FD_COUNT}" =~ ^[0-9]+$ && "${SOCKET_COUNT}" =~ ^[0-9]+$ ]] || fail "unexpected lsof count"

    if [[ "${first}" -eq 0 ]]; then printf ',\n'; fi
    first=0
    printf '    {"pid": %s, "ppid": %s, "uid": %s, "cpuPercent": %s, ' \
      "${pid_value}" "${ppid_value}" "${uid_value}" "${cpu_value}"
    printf '"rssKB": %s, "threadCount": %s, "elapsed": "%s", ' \
      "${rss_value}" "${thread_value}" "${elapsed_value}"
    printf '"fileDescriptorCount": %s, "socketCount": %s}' \
      "${FD_COUNT}" "${SOCKET_COUNT}"
  done <<< "${PIDS}"
  printf '\n  ]\n}\n'
} > "${TMP}"

/bin/mv "${TMP}" "${OUTPUT}"
trap - EXIT
printf 'Resource snapshot saved to %s\n' "${OUTPUT}"
