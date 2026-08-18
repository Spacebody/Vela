#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

MODE="structure"
APP=""
DMG=""
CONFIG="Release/config/release.json"
CORE_CONFIG="Release/Core/config/core-release.json"
DOCUMENTATION_CONFIG="Release/config/documentation.json"
EXPECTED_VERSION=""
EXPECTED_BUILD=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--structure-only|--production|--post-notary] --app Vela.app [--dmg Vela.dmg] [--config FILE] [--core-config FILE] [--expected-version X --expected-build N]\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --structure-only) MODE="structure"; shift ;;
    --production) MODE="production"; shift ;;
    --post-notary) MODE="post-notary"; shift ;;
    --app) APP="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --core-config) CORE_CONFIG="${2:-}"; shift 2 ;;
    --expected-version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
    --expected-build) EXPECTED_BUILD="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -d "${APP}" && ! -L "${APP}" && "${APP}" == *.app ]] || fail "--app must be a regular App bundle"
[[ -f "${CONFIG}" && ! -L "${CONFIG}" ]] || fail "release config is missing"
[[ -f "${CORE_CONFIG}" && ! -L "${CORE_CONFIG}" ]] || fail "Core release config is missing"
if [[ -n "${DMG}" ]]; then
  [[ -f "${DMG}" && ! -L "${DMG}" && "${DMG}" == *.dmg ]] || fail "--dmg must be a regular disk image"
fi

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
CONFIG="$(cd "$(/usr/bin/dirname "${CONFIG}")" && /bin/pwd -P)/$(/usr/bin/basename "${CONFIG}")"
CORE_CONFIG="$(cd "$(/usr/bin/dirname "${CORE_CONFIG}")" && /bin/pwd -P)/$(/usr/bin/basename "${CORE_CONFIG}")"

if [[ "${MODE}" == "structure" ]]; then
  /usr/bin/env python3 "${SCRIPT_DIR}/validate_release_config.py" \
    --repository-root "${REPO_ROOT}" --config "${CONFIG}" --skip-toolchain
  "${REPO_ROOT}/Scripts/Privileged/verify-privileged-bundle.sh" \
    --structure-only --static-mihomo "${APP}"
else
  /usr/bin/env python3 "${SCRIPT_DIR}/validate_release_config.py" \
    --repository-root "${REPO_ROOT}" --config "${CONFIG}" --production
  if [[ "${MODE}" == "post-notary" ]]; then
    "${REPO_ROOT}/Scripts/Privileged/verify-privileged-bundle.sh" --post-notary "${APP}"
  else
    "${REPO_ROOT}/Scripts/Privileged/verify-privileged-bundle.sh" --distribution "${APP}"
  fi
fi

INFO="${APP}/Contents/Info.plist"
[[ -f "${INFO}" && ! -L "${INFO}" ]] || fail "App Info.plist is missing or unsafe"
/usr/bin/plutil -lint "${INFO}" >/dev/null
CORE_CATALOG_ARGS=(--config "${CORE_CONFIG}" --info-plist "${INFO}")
if [[ "${MODE}" != "structure" ]]; then CORE_CATALOG_ARGS+=(--production); fi
/usr/bin/env python3 "${REPO_ROOT}/Release/Core/core_catalog_distribution.py" \
  "${CORE_CATALOG_ARGS[@]}"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "${INFO}" 2>/dev/null || fail "Info.plist is missing $1"
}

BUNDLE_ID="$(plist_value CFBundleIdentifier)"
VERSION="$(plist_value CFBundleShortVersionString)"
BUILD="$(plist_value CFBundleVersion)"
MINIMUM="$(plist_value LSMinimumSystemVersion)"
[[ "${BUNDLE_ID}" == "dev.yilin.Vela" ]] || fail "unexpected App bundle identifier"
[[ "${MINIMUM}" == "15.0" ]] || fail "LSMinimumSystemVersion must be 15.0"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid CFBundleShortVersionString"
[[ "${BUILD}" =~ ^[1-9][0-9]*$ ]] || fail "CFBundleVersion must be a positive integer"
[[ -z "${EXPECTED_VERSION}" || "${VERSION}" == "${EXPECTED_VERSION}" ]] || fail "App version differs from release request"
[[ -z "${EXPECTED_BUILD}" || "${BUILD}" == "${EXPECTED_BUILD}" ]] || fail "App build differs from release request"

/usr/bin/env python3 "${SCRIPT_DIR}/validate_v07_acceptance.py" --archive "${APP}" \
  --repository-root "${REPO_ROOT}" --config "${DOCUMENTATION_CONFIG}" \
  --app-version "${VERSION}" --app-build "${BUILD}"

FEED="$(plist_value SUFeedURL)"
PUBLIC_KEY="$(plist_value SUPublicEDKey)"
VERIFY_FIRST="$(plist_value SUVerifyUpdateBeforeExtraction)"
SIGNED_FEED="$(plist_value SURequireSignedFeed)"
JAVASCRIPT="$(plist_value SUEnableJavaScript)"
PROFILING="$(plist_value SUEnableSystemProfiling)"
AUTOMATIC_UPDATE="$(plist_value SUAutomaticallyUpdate)"
ALLOWS_AUTOMATIC="$(plist_value SUAllowsAutomaticUpdates)"
[[ "${VERIFY_FIRST}" == "true" ]] || fail "SUVerifyUpdateBeforeExtraction must be true"
[[ "${SIGNED_FEED}" == "true" ]] || fail "SURequireSignedFeed must be true"
[[ "${JAVASCRIPT}" == "false" ]] || fail "SUEnableJavaScript must be false"
[[ "${PROFILING}" == "false" ]] || fail "SUEnableSystemProfiling must be false"
[[ "${AUTOMATIC_UPDATE}" == "false" ]] || fail "SUAutomaticallyUpdate must be false for V0.7"
[[ "${ALLOWS_AUTOMATIC}" == "true" ]] || fail "SUAllowsAutomaticUpdates must be true"

/usr/bin/python3 - "${FEED}" "${PUBLIC_KEY}" "${MODE}" "${INFO}" <<'PY'
import base64
import plistlib
import sys
from urllib.parse import urlparse

feed, key, mode, info_path = sys.argv[1:]
parsed = urlparse(feed)
if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
    raise SystemExit("error: SUFeedURL must be fixed HTTPS without credentials/query/fragment")
placeholder = "__" in feed or parsed.hostname.endswith(".invalid")
if mode != "structure" and placeholder:
    raise SystemExit("error: production SUFeedURL contains a placeholder")
if "__" in key:
    if mode != "structure":
        raise SystemExit("error: production SUPublicEDKey contains a placeholder")
else:
    try:
        decoded = base64.b64decode(key, validate=True)
    except ValueError as error:
        raise SystemExit("error: SUPublicEDKey is not valid base64") from error
    if len(decoded) != 32:
        raise SystemExit("error: SUPublicEDKey must decode to 32 bytes")
with open(info_path, "rb") as handle:
    info = plistlib.load(handle)
if info.get("SUAllowedURLSchemes") != ["https"]:
    raise SystemExit("error: SUAllowedURLSchemes must contain only https")
if info.get("VelaReleaseManifestRequired") != "YES":
    raise SystemExit("error: release bundles must require their bundled release manifest")
PY

CLI="${APP}/Contents/Helpers/vela"
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"
MANIFEST="${APP}/Contents/Resources/VelaReleaseManifest.json"
SPARKLE_LICENSE="${APP}/Contents/Resources/ThirdParty/Sparkle/LICENSE"
YAMS_LICENSE="${APP}/Contents/Resources/ThirdParty/Yams/LICENSE"
THIRD_PARTY_NOTICES="${APP}/Contents/Resources/ThirdParty/THIRD_PARTY_NOTICES.md"
for required in "${CLI}" "${MANIFEST}" "${SPARKLE_LICENSE}" "${YAMS_LICENSE}" "${THIRD_PARTY_NOTICES}"; do
  [[ -f "${required}" && ! -L "${required}" ]] || fail "required release component is missing or unsafe: ${required}"
done
for expected_and_embedded in \
  "${REPO_ROOT}/Release/licenses/Sparkle-2.9.4-LICENSE.txt|${SPARKLE_LICENSE}" \
  "${REPO_ROOT}/Release/licenses/Yams-6.2.2-LICENSE.txt|${YAMS_LICENSE}" \
  "${REPO_ROOT}/Release/THIRD_PARTY_NOTICES.md|${THIRD_PARTY_NOTICES}"; do
  expected="${expected_and_embedded%%|*}"
  embedded="${expected_and_embedded#*|}"
  /usr/bin/cmp -s "${expected}" "${embedded}" || fail "embedded release notice differs from repository source: ${embedded}"
done
[[ -d "${SPARKLE}" && ! -L "${SPARKLE}" ]] || fail "Sparkle.framework is missing or unsafe"
[[ -x "${CLI}" ]] || fail "bundled vela CLI is not executable"
SPARKLE_INFO="${SPARKLE}/Versions/Current/Resources/Info.plist"
[[ -f "${SPARKLE_INFO}" ]] || SPARKLE_INFO="${SPARKLE}/Resources/Info.plist"
[[ -f "${SPARKLE_INFO}" && ! -L "${SPARKLE_INFO}" ]] || fail "Sparkle.framework Info.plist is missing"
SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SPARKLE_INFO}" 2>/dev/null || true)"
[[ "${SPARKLE_VERSION}" == "2.9.4" ]] || fail "Sparkle.framework must be exactly 2.9.4"

/usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
  "${MANIFEST}" --kind bundle --app-info "${INFO}" \
  --package-resolved "${REPO_ROOT}/Vela.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  $([[ "${MODE}" == "structure" ]] || printf '%s' '--production')

[[ "$(/usr/bin/lipo -archs "${CLI}")" == "arm64" ]] || fail "vela CLI must be thin arm64"

if [[ "${MODE}" != "structure" ]]; then
  APP_TEAM="$(/usr/bin/codesign -dvvv "${APP}" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
  [[ -n "${APP_TEAM}" ]] || fail "App lacks a TeamIdentifier"

  verify_nested_code() {
    local item="$1"
    local label="$2"
    local binary archs team authority entitlements
    /usr/bin/codesign --verify --strict --verbose=4 "${item}"
    binary="${item}"
    if [[ -d "${item}" ]]; then
      if [[ "${item}" == *.framework && -f "${item}/Versions/Current/$(/usr/bin/basename "${item}" .framework)" ]]; then
        binary="${item}/Versions/Current/$(/usr/bin/basename "${item}" .framework)"
      else
        local bundle_info executable candidate
        bundle_info="${item}/Contents/Info.plist"
        [[ -f "${bundle_info}" ]] || bundle_info="${item}/Resources/Info.plist"
        [[ -f "${bundle_info}" && ! -L "${bundle_info}" ]] || fail "cannot resolve Info.plist for ${label}"
        executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${bundle_info}" 2>/dev/null || true)"
        [[ -n "${executable}" && "${executable}" != */* ]] || fail "cannot resolve executable name for ${label}"
        binary=""
        for candidate in "${item}/Contents/MacOS/${executable}" "${item}/Contents/${executable}" "${item}/${executable}"; do
          if [[ -f "${candidate}" && ! -L "${candidate}" ]]; then
            binary="${candidate}"
            break
          fi
        done
        [[ -n "${binary}" ]] || fail "cannot resolve the executable for ${label}"
      fi
    fi
    archs="$(/usr/bin/lipo -archs "${binary}" 2>/dev/null || true)"
    [[ "${archs}" == "arm64" ]] || fail "${label} must be thin arm64"
    team="$(/usr/bin/codesign -dvvv "${item}" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
    [[ "${team}" == "${APP_TEAM}" ]] || fail "${label} TeamIdentifier differs from the App"
    authority="$(/usr/bin/codesign -dvvv "${item}" 2>&1 | /usr/bin/awk -F= '$1 == "Authority" {print $2; exit}')"
    [[ "${authority}" == Developer\ ID\ Application:* ]] || fail "${label} is not Developer ID Application signed"
    /usr/bin/codesign -d --verbose=4 "${item}" 2>&1 | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' || fail "${label} lacks Hardened Runtime"
    /usr/bin/codesign -dvvv "${item}" 2>&1 | /usr/bin/grep -Eq '^Timestamp=' || fail "${label} lacks a secure timestamp"
    entitlements="$(/usr/bin/codesign -d --entitlements - "${item}" 2>/dev/null || true)"
    if printf '%s\n' "${entitlements}" | /usr/bin/grep -Eq 'com\.apple\.security\.get-task-allow|com\.apple\.security\.cs\.disable-library-validation|com\.apple\.security\.cs\.allow-unsigned-executable-memory|com\.apple\.security\.automation\.apple-events|com\.apple\.developer\.networking\.networkextension'; then
      fail "${label} contains a forbidden Release entitlement"
    fi
  }

  verify_nested_code "${CLI}" "vela CLI"
  verify_nested_code "${SPARKLE}" "Sparkle.framework"
  while IFS= read -r -d '' bundle; do
    verify_nested_code "${bundle}" "Sparkle nested bundle"
  done < <(/usr/bin/find -P "${SPARKLE}" -type d \( -name '*.app' -o -name '*.xpc' \) -print0)
  NESTED_COUNT=0
  while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "${candidate}" | /usr/bin/grep -Fq 'Mach-O'; then
      verify_nested_code "${candidate}" "Sparkle nested code"
      NESTED_COUNT=$((NESTED_COUNT + 1))
    fi
  done < <(/usr/bin/find -P "${SPARKLE}" -type f -perm -111 -print0)
  [[ "${NESTED_COUNT}" -gt 0 ]] || fail "Sparkle.framework contains no verifiable nested executable"
fi

if [[ "${MODE}" == "post-notary" ]]; then
  /usr/bin/xcrun stapler validate "${APP}"
  /usr/sbin/spctl --assess --type execute --verbose=4 "${APP}"
  if [[ -n "${DMG}" ]]; then
    /usr/bin/xcrun stapler validate "${DMG}"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG}"
  fi
fi

printf 'Vela V0.7 release bundle verification passed (%s): version=%s build=%s\n' "${MODE}" "${VERSION}" "${BUILD}"
