#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

readonly EXPECTED_VERSION="v1.19.29"
readonly EXPECTED_PLATFORM="darwin"
readonly EXPECTED_ARCHITECTURE="arm64"
readonly EXPECTED_ASSET_NAME="mihomo-darwin-arm64-v1.19.29.gz"
readonly EXPECTED_ASSET_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-darwin-arm64-v1.19.29.gz"
readonly EXPECTED_ARCHIVE_SHA256="4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca"
readonly EXPECTED_REPOSITORY_URL="https://github.com/MetaCubeX/mihomo"
readonly EXPECTED_RELEASE_URL="https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.29"
readonly EXPECTED_SOURCE_URL="https://github.com/MetaCubeX/mihomo/tree/v1.19.29"
readonly EXPECTED_SOURCE_ARCHIVE_URL="https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.29.tar.gz"

DISTRIBUTION=0
POST_NOTARY=0
STATIC_ONLY=0
APP_PATH=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--distribution] [--post-notary] [--static] /path/to/Vela.app\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --distribution)
      DISTRIBUTION=1
      ;;
    --post-notary)
      POST_NOTARY=1
      DISTRIBUTION=1
      ;;
    --static)
      STATIC_ONLY=1
      ;;
    -*)
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
[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] || fail "App bundle not found or is a symlink: ${APP_PATH}"
APP_REAL_PATH="$(cd "${APP_PATH}" && /bin/pwd -P)"

assert_bundle_containment() {
  local path="$1"
  local label="$2"
  local resolved_parent
  local resolved_path
  resolved_parent="$(cd "$(/usr/bin/dirname "${path}")" && /bin/pwd -P)" ||
    fail "Could not resolve ${label} parent directory"
  resolved_path="${resolved_parent}/$(/usr/bin/basename "${path}")"
  case "${resolved_path}" in
    "${APP_REAL_PATH}"/*) ;;
    *) fail "${label} resolves outside the App bundle: ${resolved_path}" ;;
  esac
}

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[[ -f "${INFO_PLIST}" && ! -L "${INFO_PLIST}" ]] || fail "Missing regular Info.plist"
assert_bundle_containment "${INFO_PLIST}" "Info.plist"
APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}")"
APP_EXECUTABLE="${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE_NAME}"
HELPER="${APP_PATH}/Contents/Helpers/mihomo"
FORBIDDEN_RESOURCE_HELPER="${APP_PATH}/Contents/Resources/mihomo"
META_DIR="${APP_PATH}/Contents/Resources/ThirdParty/Mihomo"
MANIFEST="${META_DIR}/manifest.json"

[[ -f "${APP_EXECUTABLE}" && ! -L "${APP_EXECUTABLE}" ]] || fail "Missing regular App executable"
[[ -f "${HELPER}" && ! -L "${HELPER}" ]] || fail "Missing regular Contents/Helpers/mihomo"
[[ -x "${HELPER}" ]] || fail "Bundled helper is not executable"
[[ ! -e "${FORBIDDEN_RESOURCE_HELPER}" && ! -L "${FORBIDDEN_RESOURCE_HELPER}" ]] ||
  fail "Mihomo must not be copied to Contents/Resources/mihomo"
[[ -s "${MANIFEST}" && ! -L "${MANIFEST}" ]] || fail "Missing or empty regular bundled Mihomo manifest"
[[ -s "${META_DIR}/LICENSE" && ! -L "${META_DIR}/LICENSE" ]] || fail "Missing or empty regular bundled Mihomo LICENSE"
[[ -s "${META_DIR}/NOTICE.md" && ! -L "${META_DIR}/NOTICE.md" ]] || fail "Missing or empty regular bundled Mihomo NOTICE"

assert_bundle_containment "${APP_EXECUTABLE}" "App executable"
assert_bundle_containment "${HELPER}" "Mihomo helper"
assert_bundle_containment "${MANIFEST}" "Mihomo manifest"
assert_bundle_containment "${META_DIR}/LICENSE" "Mihomo LICENSE"
assert_bundle_containment "${META_DIR}/NOTICE.md" "Mihomo NOTICE"

read_manifest() {
  /usr/bin/plutil -extract "$1" raw -o - "${MANIFEST}"
}

[[ "$(read_manifest version)" == "${EXPECTED_VERSION}" ]] || fail "Bundled manifest version mismatch"
[[ "$(read_manifest platform)" == "${EXPECTED_PLATFORM}" ]] || fail "Bundled manifest platform mismatch"
[[ "$(read_manifest architecture)" == "${EXPECTED_ARCHITECTURE}" ]] || fail "Bundled manifest architecture mismatch"
[[ "$(read_manifest assetName)" == "${EXPECTED_ASSET_NAME}" ]] || fail "Bundled manifest asset mismatch"
[[ "$(read_manifest assetURL)" == "${EXPECTED_ASSET_URL}" ]] || fail "Bundled manifest asset URL mismatch"
[[ "$(read_manifest archiveSHA256)" == "${EXPECTED_ARCHIVE_SHA256}" ]] || fail "Bundled manifest SHA-256 mismatch"
[[ "$(read_manifest upstreamRepositoryURL)" == "${EXPECTED_REPOSITORY_URL}" ]] || fail "Bundled manifest repository URL mismatch"
[[ "$(read_manifest upstreamReleaseURL)" == "${EXPECTED_RELEASE_URL}" ]] || fail "Bundled manifest release URL mismatch"
[[ "$(read_manifest upstreamSourceURL)" == "${EXPECTED_SOURCE_URL}" ]] || fail "Bundled manifest source URL mismatch"
[[ "$(read_manifest upstreamSourceArchiveURL)" == "${EXPECTED_SOURCE_ARCHIVE_URL}" ]] || fail "Bundled manifest source archive URL mismatch"
[[ "$(read_manifest bundleRelativePath)" == "Contents/Helpers/mihomo" ]] || fail "Bundled helper path mismatch"
[[ "$(read_manifest metadataBundleRelativePath)" == "Contents/Resources/ThirdParty/Mihomo" ]] || fail "Bundled metadata path mismatch"
[[ "$(read_manifest runtimeDownloadAllowed)" == "false" ]] || fail "Bundled manifest enables runtime download"

APP_ARCHS="$(/usr/bin/lipo -archs "${APP_EXECUTABLE}" 2>/dev/null || true)"
HELPER_ARCHS="$(/usr/bin/lipo -archs "${HELPER}" 2>/dev/null || true)"
[[ "${APP_ARCHS}" == "arm64" ]] || fail "Vela must be thin arm64; got ${APP_ARCHS:-unknown}"
[[ "${HELPER_ARCHS}" == "arm64" ]] || fail "Mihomo must be thin arm64; got ${HELPER_ARCHS:-unknown}"

/usr/bin/codesign --verify --strict --verbose=4 "${HELPER}"
/usr/bin/codesign --verify --strict --verbose=4 "${APP_PATH}"

signing_field() {
  local path="$1"
  local field="$2"
  local value
  value="$(/usr/bin/codesign -dvvv "${path}" 2>&1 | /usr/bin/awk -F= -v key="${field}" '$1 == key { print $2; exit }')"
  if [[ "${value}" == "not set" ]]; then
    value=""
  fi
  printf '%s' "${value}"
}

APP_TEAM="$(signing_field "${APP_PATH}" TeamIdentifier)"
HELPER_TEAM="$(signing_field "${HELPER}" TeamIdentifier)"
APP_AUTHORITY="$(signing_field "${APP_PATH}" Authority)"
HELPER_AUTHORITY="$(signing_field "${HELPER}" Authority)"

if [[ -n "${APP_TEAM}" || -n "${HELPER_TEAM}" ]]; then
  [[ -n "${APP_TEAM}" && -n "${HELPER_TEAM}" ]] || fail "Only one component has a Team Identifier"
  [[ "${APP_TEAM}" == "${HELPER_TEAM}" ]] ||
    fail "Team Identifier mismatch: app=${APP_TEAM}, helper=${HELPER_TEAM}"
fi

has_hardened_runtime() {
  local signing_details
  signing_details="$(/usr/bin/codesign -d --verbose=4 "$1" 2>&1)" || return 1
  /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "${signing_details}"
}

if [[ "${DISTRIBUTION}" == "1" ]]; then
  [[ -n "${APP_TEAM}" ]] || fail "Distribution build must have a Team Identifier"
  [[ "${APP_AUTHORITY}" == Developer\ ID\ Application:* ]] ||
    fail "App is not signed with a Developer ID Application identity: ${APP_AUTHORITY:-none}"
  [[ "${HELPER_AUTHORITY}" == Developer\ ID\ Application:* ]] ||
    fail "Helper is not signed with a Developer ID Application identity: ${HELPER_AUTHORITY:-none}"
  has_hardened_runtime "${APP_PATH}" || fail "Distribution App is missing Hardened Runtime"
  has_hardened_runtime "${HELPER}" || fail "Distribution helper is missing Hardened Runtime"
fi

VERSION_OUTPUT="not executed (--static)"
if [[ "${STATIC_ONLY}" != "1" ]]; then
  VERSION_OUTPUT="$("${HELPER}" -v 2>&1)" || fail "Bundled mihomo -v failed"
  FIRST_VERSION_LINE="$(printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/awk 'NF { print; exit }')"
  [[ "${FIRST_VERSION_LINE}" =~ ^Mihomo[[:space:]]Meta[[:space:]]v1\.19\.29[[:space:]]darwin[[:space:]]arm64([[:space:]].*)?$ ]] ||
    fail "Unexpected bundled Mihomo version output: ${VERSION_OUTPUT}"
fi

if [[ "${POST_NOTARY}" == "1" ]]; then
  /usr/bin/xcrun stapler validate "${APP_PATH}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${APP_PATH}"
fi

printf 'Vela bundle verification passed:\n'
printf '  App architecture:    %s\n' "${APP_ARCHS}"
printf '  Helper architecture: %s\n' "${HELPER_ARCHS}"
printf '  App Team ID:         %s\n' "${APP_TEAM:-ad-hoc/not-set}"
printf '  Helper Team ID:      %s\n' "${HELPER_TEAM:-ad-hoc/not-set}"
printf '  Version check:       %s\n' "${VERSION_OUTPUT}"
printf '  Gatekeeper check:    %s\n' "$([[ "${POST_NOTARY}" == "1" ]] && printf 'passed' || printf 'not requested')"
