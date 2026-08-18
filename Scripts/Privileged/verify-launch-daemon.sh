#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

readonly EXPECTED_LABEL="dev.yilin.Vela.Helper"
readonly EXPECTED_APP_IDENTIFIER="dev.yilin.Vela"
readonly EXPECTED_PROGRAM="Contents/Library/LaunchServices/VelaHelper"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
PLIST="${1:-${PROJECT_ROOT}/Configuration/Privileged/${EXPECTED_LABEL}.plist}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "${PLIST}"
}

plist_key_must_be_absent() {
  if /usr/bin/plutil -extract "$1" raw -o - "${PLIST}" >/dev/null 2>&1; then
    fail "LaunchDaemon plist must not define $1"
  fi
}

[[ "$#" -le 1 ]] || fail "Usage: $0 [/path/to/LaunchDaemon.plist]"
[[ -f "${PLIST}" && ! -L "${PLIST}" ]] || fail "Missing regular LaunchDaemon plist: ${PLIST}"
[[ "$(/usr/bin/stat -f '%z' "${PLIST}")" -le 65536 ]] || fail "LaunchDaemon plist is oversized"
/usr/bin/plutil -lint "${PLIST}" >/dev/null

if /usr/bin/grep -Eq '__[A-Z][A-Z0-9_]*__' "${PLIST}"; then
  fail "LaunchDaemon plist contains an unresolved placeholder"
fi

[[ "$(plist_value Label)" == "${EXPECTED_LABEL}" ]] || fail "Unexpected LaunchDaemon label"
[[ "$(plist_value BundleProgram)" == "${EXPECTED_PROGRAM}" ]] || fail "Unexpected BundleProgram"
MACH_SERVICE_VALUE="$(/usr/libexec/PlistBuddy -c "Print :MachServices:${EXPECTED_LABEL}" "${PLIST}")" || \
  fail "Mach service is missing"
[[ "${MACH_SERVICE_VALUE}" == "true" ]] || fail "Mach service is disabled"
[[ "$(plist_value AssociatedBundleIdentifiers.0)" == "${EXPECTED_APP_IDENTIFIER}" ]] || \
  fail "Associated app identifier is not ${EXPECTED_APP_IDENTIFIER}"
if /usr/bin/plutil -extract AssociatedBundleIdentifiers.1 raw -o - "${PLIST}" >/dev/null 2>&1; then
  fail "LaunchDaemon must have exactly one AssociatedBundleIdentifier"
fi
[[ "$(plist_value ProcessType)" == "Background" ]] || fail "ProcessType must be Background"
[[ "$(plist_value ThrottleInterval)" == "5" ]] || fail "ThrottleInterval must be 5 seconds"
[[ "$(plist_value KeepAlive.SuccessfulExit)" == "false" ]] || fail "KeepAlive.SuccessfulExit must be false"

for forbidden_key in \
  Program \
  ProgramArguments \
  EnvironmentVariables \
  WorkingDirectory \
  RootDirectory \
  UserName \
  GroupName
do
  plist_key_must_be_absent "${forbidden_key}"
done

MACH_SERVICE_COUNT="$(
  /usr/bin/plutil -convert json -o - "${PLIST}" |
    /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby -rjson -e \
      'value = JSON.parse(STDIN.read).fetch("MachServices"); abort unless value.is_a?(Hash); puts value.length'
)" || fail "Could not inspect MachServices"
[[ "${MACH_SERVICE_COUNT}" == "1" ]] || fail "LaunchDaemon must publish exactly one Mach service"

printf 'LaunchDaemon validation passed:\n'
printf '  Plist:       %s\n' "${PLIST}"
printf '  Label:       %s\n' "${EXPECTED_LABEL}"
printf '  Program:     %s\n' "${EXPECTED_PROGRAM}"
printf '  Associated:  %s\n' "${EXPECTED_APP_IDENTIFIER}"
