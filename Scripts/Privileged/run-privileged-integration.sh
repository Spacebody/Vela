#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly TEST_TARGET="VelaPrivilegedIntegrationTests"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
PROJECT_FILE="${PROJECT_ROOT}/Vela.xcodeproj/project.pbxproj"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == "0" ]] || fail "Usage: $0"
[[ "${EUID}" != "0" ]] || fail "Run integration tests as the logged-in user, never with sudo/root"
[[ "${VELA_RUN_PRIVILEGED_TESTS:-0}" == "1" ]] || \
  fail "Privileged tests are disabled. Set VELA_RUN_PRIVILEGED_TESTS=1 explicitly"
[[ "${VELA_PRIVILEGED_TESTS_CONFIRM:-}" == "YES" ]] || \
  fail "Set VELA_PRIVILEGED_TESTS_CONFIRM=YES to acknowledge helper/TUN system changes"
[[ -f "${PROJECT_FILE}" && ! -L "${PROJECT_FILE}" ]] || fail "Missing Xcode project"

if ! /usr/bin/grep -Fq "${TEST_TARGET}" "${PROJECT_FILE}"; then
  fail "${TEST_TARGET} is not configured; refusing to substitute an unscoped test target"
fi

TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-privileged-tests.XXXXXX")"
DERIVED_DATA="${TEMP_ROOT}/DerivedData"
RESULT_BUNDLE="${TEMP_ROOT}/VelaPrivilegedIntegration.xcresult"
BEFORE_PROCESSES="${TEMP_ROOT}/before-processes.txt"
AFTER_PROCESSES="${TEMP_ROOT}/after-processes.txt"
BEFORE_UTUN="${TEMP_ROOT}/before-utun.txt"
AFTER_UTUN="${TEMP_ROOT}/after-utun.txt"
BEFORE_PROXY="${TEMP_ROOT}/before-proxy.txt"
AFTER_PROXY="${TEMP_ROOT}/after-proxy.txt"

snapshot_processes() {
  local process_table
  process_table="$(/bin/ps -axo pid=,uid=,command= 2>/dev/null)" || return 1
  printf '%s\n' "${process_table}" |
    /usr/bin/grep -E '[V]elaHelper|Contents/Helpers/[m]ihomo' |
    /usr/bin/sort || true
}

snapshot_utun() {
  local interfaces
  interfaces="$(/sbin/ifconfig -l 2>/dev/null)" || return 1
  printf '%s\n' "${interfaces}" |
    /usr/bin/tr ' ' '\n' |
    /usr/bin/grep '^utun' |
    /usr/bin/sort -V || true
}

snapshot_proxy() {
  /usr/sbin/scutil --proxy 2>/dev/null
}

if ! snapshot_processes > "${BEFORE_PROCESSES}" ||
  ! snapshot_utun > "${BEFORE_UTUN}" ||
  ! snapshot_proxy > "${BEFORE_PROXY}"
then
  /bin/rm -rf "${TEMP_ROOT}"
  fail "Could not capture the complete pre-test process/utun/proxy baseline"
fi

finalize() {
  local status=$?
  local residue=0
  if ! snapshot_processes > "${AFTER_PROCESSES}" ||
    ! snapshot_utun > "${AFTER_UTUN}" ||
    ! snapshot_proxy > "${AFTER_PROXY}"
  then
    printf 'error: could not capture the complete post-test process/utun/proxy state\n' >&2
    residue=1
  fi

  if ! /usr/bin/cmp -s "${BEFORE_PROCESSES}" "${AFTER_PROCESSES}"; then
    printf 'error: Vela privileged process set changed across integration tests:\n' >&2
    /usr/bin/diff -u "${BEFORE_PROCESSES}" "${AFTER_PROCESSES}" >&2 || true
    residue=1
  fi
  if ! /usr/bin/cmp -s "${BEFORE_UTUN}" "${AFTER_UTUN}"; then
    printf 'error: utun interface set changed across integration tests:\n' >&2
    /usr/bin/diff -u "${BEFORE_UTUN}" "${AFTER_UTUN}" >&2 || true
    residue=1
  fi
  if ! /usr/bin/cmp -s "${BEFORE_PROXY}" "${AFTER_PROXY}"; then
    printf 'error: system proxy state changed across integration tests:\n' >&2
    /usr/bin/diff -u "${BEFORE_PROXY}" "${AFTER_PROXY}" >&2 || true
    residue=1
  fi

  "${SCRIPT_DIR}/check-tun-cleanup.sh" || true

  case "${DERIVED_DATA}" in
    "${TEMP_ROOT}"/DerivedData)
      if [[ "${VELA_PRIVILEGED_KEEP_DERIVED_DATA:-0}" != "1" ]]; then
        /bin/rm -rf "${DERIVED_DATA}" || true
      fi
      ;;
    *)
      printf 'warning: refused to remove unexpected DerivedData path: %s\n' "${DERIVED_DATA}" >&2
      residue=1
      ;;
  esac

  printf 'Privileged test evidence retained at: %s\n' "${TEMP_ROOT}"

  if [[ "${status}" == "0" && "${residue}" != "0" ]]; then
    status=1
  fi
  return "${status}"
}
trap finalize EXIT
trap 'exit 130' HUP INT TERM

printf 'Running explicitly enabled privileged integration target: %s\n' "${TEST_TARGET}"
VELA_RUN_PRIVILEGED_TESTS=1 \
VELA_PRIVILEGED_TESTS_CONFIRM=YES \
/usr/bin/xcodebuild test \
  -project "${PROJECT_ROOT}/Vela.xcodeproj" \
  -scheme Vela \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA}" \
  -resultBundlePath "${RESULT_BUNDLE}" \
  -only-testing:"${TEST_TARGET}"

printf 'Privileged integration tests passed; post-test process, utun, and proxy snapshots match.\n'
