#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly EXPECTED_APP_IDENTIFIER="dev.yilin.Vela"
readonly EXPECTED_HELPER_IDENTIFIER="dev.yilin.Vela.Helper"
readonly EXPECTED_MIHOMO_IDENTIFIER="mihomo"
readonly EXPECTED_HELPER_PROGRAM="Contents/Library/LaunchServices/VelaHelper"
readonly EXPECTED_MIHOMO_VERSION="v1.19.29"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"

STRUCTURE_ONLY=0
DISTRIBUTION=0
POST_NOTARY=0
STATIC_MIHOMO=0
APP_PATH=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--structure-only] [--distribution] [--post-notary] [--static-mihomo] /path/to/Vela.app\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --structure-only)
      STRUCTURE_ONLY=1
      ;;
    --distribution)
      DISTRIBUTION=1
      ;;
    --post-notary)
      DISTRIBUTION=1
      POST_NOTARY=1
      ;;
    --static-mihomo)
      STATIC_MIHOMO=1
      ;;
    -* )
      usage
      fail "Unknown option: $1"
      ;;
    *)
      [[ -z "${APP_PATH}" ]] || {
        usage
        fail "Only one App path may be provided"
      }
      APP_PATH="$1"
      ;;
  esac
  shift
done

[[ -n "${APP_PATH}" ]] || {
  usage
  fail "Missing App path"
}
if [[ "${STRUCTURE_ONLY}" == "1" && ( "${DISTRIBUTION}" == "1" || "${POST_NOTARY}" == "1" ) ]]; then
  fail "--structure-only cannot be combined with distribution or notarization gates"
fi
[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] || fail "App bundle not found or is a symlink: ${APP_PATH}"
APP_REAL_PATH="$(cd "${APP_PATH}" && /bin/pwd -P)"

assert_regular_bundle_file() {
  local path="$1"
  local label="$2"
  local resolved_parent
  [[ -f "${path}" && ! -L "${path}" ]] || fail "Missing regular ${label}: ${path}"
  resolved_parent="$(cd "$(/usr/bin/dirname "${path}")" && /bin/pwd -P)" || \
    fail "Could not resolve ${label} parent"
  case "${resolved_parent}/$(/usr/bin/basename "${path}")" in
    "${APP_REAL_PATH}"/*) ;;
    *) fail "${label} resolves outside the App bundle" ;;
  esac
}

assert_bundle_directory() {
  local path="$1"
  local label="$2"
  local resolved
  [[ -d "${path}" && ! -L "${path}" ]] || fail "Missing regular ${label} directory: ${path}"
  resolved="$(cd "${path}" && /bin/pwd -P)" || fail "Could not resolve ${label} directory"
  case "${resolved}" in
    "${APP_REAL_PATH}"/*) ;;
    *) fail "${label} directory resolves outside the App bundle" ;;
  esac
}

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
assert_regular_bundle_file "${INFO_PLIST}" "Info.plist"
/usr/bin/plutil -lint "${INFO_PLIST}" >/dev/null

APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")"
APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}")"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")" || \
  fail "App Info.plist lacks LSMinimumSystemVersion"
[[ "${APP_IDENTIFIER}" == "${EXPECTED_APP_IDENTIFIER}" ]] || \
  fail "Unexpected App bundle identifier: ${APP_IDENTIFIER}"
[[ "${MINIMUM_SYSTEM_VERSION}" == "15.0" ]] || \
  fail "App minimum macOS must be 15.0, got ${MINIMUM_SYSTEM_VERSION}"
[[ -n "${APP_EXECUTABLE_NAME}" && "${APP_EXECUTABLE_NAME}" != */* ]] || fail "Unsafe App executable name"

APP_EXECUTABLE="${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE_NAME}"
PRIVILEGED_HELPER="${APP_PATH}/${EXPECTED_HELPER_PROGRAM}"
MIHOMO="${APP_PATH}/Contents/Helpers/mihomo"
DAEMON_DIR="${APP_PATH}/Contents/Library/LaunchDaemons"
METADATA_DIR="${APP_PATH}/Contents/Resources/ThirdParty/Mihomo"

assert_regular_bundle_file "${APP_EXECUTABLE}" "App executable"
assert_regular_bundle_file "${PRIVILEGED_HELPER}" "privileged helper"
assert_regular_bundle_file "${MIHOMO}" "Mihomo executable"
[[ -x "${APP_EXECUTABLE}" ]] || fail "App executable is not executable"
[[ -x "${PRIVILEGED_HELPER}" ]] || fail "Privileged helper is not executable"
[[ -x "${MIHOMO}" ]] || fail "Mihomo is not executable"
assert_bundle_directory "${DAEMON_DIR}" "LaunchDaemons"
assert_bundle_directory "${METADATA_DIR}" "Mihomo metadata"

PLIST_COUNT=0
PLIST_SYMLINK_COUNT=0
DAEMON_PLIST=""
for candidate in "${DAEMON_DIR}"/*.plist; do
  [[ -e "${candidate}" || -L "${candidate}" ]] || continue
  if [[ -L "${candidate}" ]]; then
    PLIST_SYMLINK_COUNT=$((PLIST_SYMLINK_COUNT + 1))
  elif [[ -f "${candidate}" ]]; then
    PLIST_COUNT=$((PLIST_COUNT + 1))
    DAEMON_PLIST="${candidate}"
  fi
done
[[ "${PLIST_COUNT}" == "1" ]] || fail "Expected exactly one regular LaunchDaemon plist, found ${PLIST_COUNT}"
[[ "${PLIST_SYMLINK_COUNT}" == "0" ]] || fail "LaunchDaemons directory contains a plist symlink"
[[ "$(/usr/bin/basename "${DAEMON_PLIST}")" == "${EXPECTED_HELPER_IDENTIFIER}.plist" ]] || \
  fail "Unexpected LaunchDaemon plist filename"
"${SCRIPT_DIR}/verify-launch-daemon.sh" "${DAEMON_PLIST}" >/dev/null

for metadata_file in manifest.json LICENSE NOTICE.md; do
  assert_regular_bundle_file "${METADATA_DIR}/${metadata_file}" "Mihomo ${metadata_file}"
  [[ -s "${METADATA_DIR}/${metadata_file}" ]] || fail "Mihomo ${metadata_file} is empty"
done

MIHOMO_MANIFEST="${METADATA_DIR}/manifest.json"
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby -rjson -e \
  'value = JSON.parse(File.binread(ARGV.fetch(0)), create_additions: false); abort unless value.is_a?(Hash)' \
  "${MIHOMO_MANIFEST}" || fail "Bundled Mihomo manifest is not a JSON object"
manifest_value() {
  /usr/bin/plutil -extract "$1" raw -o - "${MIHOMO_MANIFEST}"
}
[[ "$(manifest_value version)" == "${EXPECTED_MIHOMO_VERSION}" ]] || fail "Bundled Mihomo manifest version drifted"
[[ "$(manifest_value platform)" == "darwin" ]] || fail "Bundled Mihomo platform is not darwin"
[[ "$(manifest_value architecture)" == "arm64" ]] || fail "Bundled Mihomo architecture is not arm64"
[[ "$(manifest_value bundleRelativePath)" == "Contents/Helpers/mihomo" ]] || fail "Bundled Mihomo path contract drifted"
[[ "$(manifest_value metadataBundleRelativePath)" == "Contents/Resources/ThirdParty/Mihomo" ]] || \
  fail "Bundled Mihomo metadata path contract drifted"
[[ "$(manifest_value runtimeDownloadAllowed)" == "false" ]] || fail "Bundled Mihomo manifest permits runtime download"

for binary in "${APP_EXECUTABLE}" "${PRIVILEGED_HELPER}" "${MIHOMO}"; do
  archs="$(/usr/bin/lipo -archs "${binary}" 2>/dev/null || true)"
  [[ "${archs}" == "arm64" ]] || fail "${binary} must be thin arm64, got ${archs:-unknown}"
done

VERSION_OUTPUT="not executed (--static-mihomo)"
if [[ "${STATIC_MIHOMO}" != "1" ]]; then
  VERSION_OUTPUT="$(/usr/bin/python3 - "${MIHOMO}" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "-v"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=5,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    )
except subprocess.TimeoutExpired:
    print("error: bundled Mihomo -v timed out", file=sys.stderr)
    raise SystemExit(124)
if result.returncode != 0:
    print(result.stdout, end="", file=sys.stderr)
    raise SystemExit(result.returncode)
print(result.stdout, end="")
PY
)" || fail "Bundled Mihomo version probe failed"
  FIRST_VERSION_LINE="$(printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/awk 'NF { print; exit }')"
  [[ "${FIRST_VERSION_LINE}" =~ ^Mihomo[[:space:]]Meta[[:space:]]v1\.19\.29[[:space:]]darwin[[:space:]]arm64([[:space:]].*)?$ ]] || \
    fail "Unexpected bundled Mihomo version output: ${VERSION_OUTPUT}"
fi

if [[ "${STRUCTURE_ONLY}" == "1" ]]; then
  printf 'Privileged bundle structure verification passed:\n'
  printf '  App:          %s\n' "${APP_EXECUTABLE}"
  printf '  Helper:       %s\n' "${PRIVILEGED_HELPER}"
  printf '  Mihomo:       %s\n' "${MIHOMO}"
  printf '  LaunchDaemon: %s\n' "${DAEMON_PLIST}"
  printf '  Architecture: arm64\n'
  printf '  Minimum macOS: 15.0\n'
  printf '  Version:      %s\n' "${VERSION_OUTPUT}"
  printf '  Signing:      intentionally not checked (--structure-only)\n'
  exit 0
fi

for code_item in "${MIHOMO}" "${PRIVILEGED_HELPER}" "${APP_PATH}"; do
  /usr/bin/codesign --verify --strict --verbose=4 "${code_item}"
done

signing_field() {
  local path="$1"
  local field="$2"
  local value
  value="$(/usr/bin/codesign -dvvv "${path}" 2>&1 | /usr/bin/awk -F= -v key="${field}" '$1 == key { print $2; exit }')"
  [[ "${value}" != "not set" ]] || value=""
  printf '%s' "${value}"
}

has_hardened_runtime() {
  local signing_details
  signing_details="$(/usr/bin/codesign -d --verbose=4 "$1" 2>&1)" || return 1
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "${signing_details}"
}

reject_forbidden_entitlements() {
  local path="$1"
  local label="$2"
  local entitlements
  entitlements="$(/usr/bin/codesign -d --entitlements :- "${path}" 2>/dev/null || true)"
  if printf '%s\n' "${entitlements}" | /usr/bin/grep -Eq \
    'com\.apple\.security\.get-task-allow|com\.apple\.security\.cs\.disable-library-validation|com\.apple\.security\.cs\.allow-unsigned-executable-memory|com\.apple\.developer\.networking\.networkextension'
  then
    fail "${label} contains a forbidden Release entitlement"
  fi
}

APP_TEAM="$(signing_field "${APP_PATH}" TeamIdentifier)"
HELPER_TEAM="$(signing_field "${PRIVILEGED_HELPER}" TeamIdentifier)"
MIHOMO_TEAM="$(signing_field "${MIHOMO}" TeamIdentifier)"
APP_SIGNING_IDENTIFIER="$(signing_field "${APP_PATH}" Identifier)"
HELPER_SIGNING_IDENTIFIER="$(signing_field "${PRIVILEGED_HELPER}" Identifier)"
MIHOMO_SIGNING_IDENTIFIER="$(signing_field "${MIHOMO}" Identifier)"

[[ -n "${APP_TEAM}" ]] || fail "App lacks TeamIdentifier; authenticated privileged XPC requires real signing"
[[ "${APP_TEAM}" == "${HELPER_TEAM}" ]] || fail "App/Helper TeamIdentifier mismatch"
[[ "${APP_TEAM}" == "${MIHOMO_TEAM}" ]] || fail "App/Mihomo TeamIdentifier mismatch"
[[ "${APP_SIGNING_IDENTIFIER}" == "${EXPECTED_APP_IDENTIFIER}" ]] || fail "App signing identifier mismatch"
[[ "${HELPER_SIGNING_IDENTIFIER}" == "${EXPECTED_HELPER_IDENTIFIER}" ]] || fail "Helper signing identifier mismatch"
[[ "${MIHOMO_SIGNING_IDENTIFIER}" == "${EXPECTED_MIHOMO_IDENTIFIER}" ]] || fail "Mihomo signing identifier mismatch"

APP_REQUIREMENT="$(/usr/bin/codesign -d -r- "${APP_PATH}" 2>&1)" || fail "Could not read App designated requirement"
HELPER_REQUIREMENT="$(/usr/bin/codesign -d -r- "${PRIVILEGED_HELPER}" 2>&1)" || \
  fail "Could not read Helper designated requirement"
printf '%s\n' "${APP_REQUIREMENT}" | /usr/bin/grep -Fq "identifier \"${EXPECTED_APP_IDENTIFIER}\"" || \
  fail "App designated requirement lacks the exact identifier"
printf '%s\n' "${HELPER_REQUIREMENT}" | /usr/bin/grep -Fq "identifier \"${EXPECTED_HELPER_IDENTIFIER}\"" || \
  fail "Helper designated requirement lacks the exact identifier"
printf '%s\n' "${APP_REQUIREMENT}" | /usr/bin/grep -Fq 'anchor apple generic' || \
  fail "App designated requirement lacks the Apple generic anchor"
printf '%s\n' "${HELPER_REQUIREMENT}" | /usr/bin/grep -Fq 'anchor apple generic' || \
  fail "Helper designated requirement lacks the Apple generic anchor"

if /usr/bin/codesign -d --entitlements :- "${PRIVILEGED_HELPER}" 2>/dev/null | \
  /usr/bin/grep -Fq 'com.apple.security.app-sandbox'
then
  fail "Privileged helper must not use App Sandbox"
fi

APP_AUTHORITY="$(signing_field "${APP_PATH}" Authority)"
HELPER_AUTHORITY="$(signing_field "${PRIVILEGED_HELPER}" Authority)"
MIHOMO_AUTHORITY="$(signing_field "${MIHOMO}" Authority)"

if [[ "${DISTRIBUTION}" == "1" ]]; then
  for code_item in "${APP_PATH}" "${PRIVILEGED_HELPER}" "${MIHOMO}"; do
    has_hardened_runtime "${code_item}" || fail "Missing Hardened Runtime: ${code_item}"
    reject_forbidden_entitlements "${code_item}" "${code_item}"
    [[ -n "$(signing_field "${code_item}" Timestamp)" ]] || fail "Missing secure timestamp: ${code_item}"
  done
  [[ "${APP_AUTHORITY}" == Developer\ ID\ Application:* ]] || fail "App is not signed with Developer ID Application"
  [[ "${HELPER_AUTHORITY}" == Developer\ ID\ Application:* ]] || fail "Helper is not signed with Developer ID Application"
  [[ "${MIHOMO_AUTHORITY}" == Developer\ ID\ Application:* ]] || fail "Mihomo is not signed with Developer ID Application"
fi

if [[ "${POST_NOTARY}" == "1" ]]; then
  /usr/bin/xcrun stapler validate "${APP_PATH}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${APP_PATH}"
fi

printf 'Privileged bundle verification passed:\n'
printf '  App:          %s\n' "${APP_EXECUTABLE}"
printf '  Helper:       %s\n' "${PRIVILEGED_HELPER}"
printf '  Mihomo:       %s\n' "${MIHOMO}"
printf '  LaunchDaemon: %s\n' "${DAEMON_PLIST}"
printf '  Architecture: arm64\n'
printf '  Minimum macOS: 15.0\n'
printf '  Team ID:      %s\n' "${APP_TEAM}"
printf '  Distribution: %s\n' "$([[ "${DISTRIBUTION}" == "1" ]] && printf 'Developer ID' || printf 'development signed')"
printf '  Notarization: %s\n' "$([[ "${POST_NOTARY}" == "1" ]] && printf 'staple and Gatekeeper passed' || printf 'not requested')"
printf '  Version:      %s\n' "${VERSION_OUTPUT}"
