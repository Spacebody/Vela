#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFEST="${PROJECT_ROOT}/Vendor/Mihomo/manifest.json"
PROJECT_FILE="${PROJECT_ROOT}/Vela.xcodeproj/project.pbxproj"
CONTROLLER_GATE="${SCRIPT_DIR}/real-core-controller-gate.py"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_regular_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "Missing regular file: $1"
}

require_project_text() {
  /usr/bin/grep -Fq "$1" "${PROJECT_FILE}" || fail "Missing Xcode project setting: $1"
}

require_regular_file "${MANIFEST}"
require_regular_file "${PROJECT_ROOT}/Vendor/Mihomo/LICENSE"
require_regular_file "${PROJECT_ROOT}/Vendor/Mihomo/NOTICE.md"
require_regular_file "${PROJECT_FILE}"

for script in \
  "${SCRIPT_DIR}/fetch-mihomo.sh" \
  "${SCRIPT_DIR}/verify-mihomo.sh" \
  "${SCRIPT_DIR}/sign-embedded-mihomo.sh" \
  "${SCRIPT_DIR}/verify-app-bundle.sh" \
  "${SCRIPT_DIR}/clean-mihomo.sh" \
  "${SCRIPT_DIR}/test-real-core.sh" \
  "${SCRIPT_DIR}/test-static-integration.sh"
do
  require_regular_file "${script}"
  [[ -x "${script}" ]] || fail "Script is not executable: ${script}"
  /bin/bash -n "${script}"
done

require_regular_file "${CONTROLLER_GATE}"
[[ -x "${CONTROLLER_GATE}" ]] || fail "Script is not executable: ${CONTROLLER_GATE}"
/usr/bin/python3 -c \
  'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
  "${CONTROLLER_GATE}" || fail "Controller integration probe has invalid Python syntax"

for required_contract in \
  '/configs?force=false' \
  '/providers/proxies' \
  '/providers/rules' \
  '/rules' \
  '/rules/disable' \
  '/connections?interval=1000' \
  'method="DELETE"'
do
  /usr/bin/grep -Fq "${required_contract}" "${CONTROLLER_GATE}" ||
    fail "Controller integration probe is missing contract: ${required_contract}"
done

read_manifest() {
  /usr/bin/plutil -extract "$1" raw -o - "${MANIFEST}"
}

[[ "$(read_manifest version)" == "v1.19.29" ]] || fail "Manifest version is not pinned"
[[ "$(read_manifest platform)" == "darwin" ]] || fail "Manifest platform is not darwin"
[[ "$(read_manifest architecture)" == "arm64" ]] || fail "Manifest architecture is not arm64"
[[ "$(read_manifest assetName)" == "mihomo-darwin-arm64-v1.19.29.gz" ]] || fail "Manifest asset is not pinned"
[[ "$(read_manifest assetURL)" == "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-darwin-arm64-v1.19.29.gz" ]] || fail "Manifest URL is not the complete pinned URL"
[[ "$(read_manifest archiveSHA256)" == "4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca" ]] || fail "Manifest SHA-256 is not pinned"
[[ "$(read_manifest archiveSizeBytes)" == "15858351" ]] || fail "Manifest archive size is not pinned"
[[ "$(read_manifest upstreamRepositoryURL)" == "https://github.com/MetaCubeX/mihomo" ]] || fail "Manifest repository URL is not pinned"
[[ "$(read_manifest upstreamReleaseURL)" == "https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.29" ]] || fail "Manifest release URL is not pinned"
[[ "$(read_manifest upstreamSourceURL)" == "https://github.com/MetaCubeX/mihomo/tree/v1.19.29" ]] || fail "Manifest source URL is not pinned"
[[ "$(read_manifest upstreamSourceArchiveURL)" == "https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.29.tar.gz" ]] || fail "Manifest source archive URL is not pinned"
[[ "$(read_manifest bundleRelativePath)" == "Contents/Helpers/mihomo" ]] || fail "Manifest helper path is incorrect"
[[ "$(read_manifest metadataBundleRelativePath)" == "Contents/Resources/ThirdParty/Mihomo" ]] || fail "Manifest metadata path is incorrect"
[[ "$(read_manifest runtimeDownloadAllowed)" == "false" ]] || fail "Manifest permits runtime download"

if /usr/bin/grep -E '/releases/latest|mihomo-alpha|darwin-amd64' \
  "${MANIFEST}" \
  "${SCRIPT_DIR}/fetch-mihomo.sh" \
  "${SCRIPT_DIR}/verify-mihomo.sh" \
  "${SCRIPT_DIR}/verify-app-bundle.sh" >/dev/null
then
  fail "Floating, Alpha, or Intel Mihomo reference found"
fi

if /usr/bin/git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  /usr/bin/git -C "${PROJECT_ROOT}" check-ignore -q Vendor/Mihomo/cache/probe ||
    fail "Vendor/Mihomo/cache is not ignored"
  /usr/bin/git -C "${PROJECT_ROOT}" check-ignore -q Vendor/Mihomo/bin/mihomo ||
    fail "Vendor/Mihomo/bin is not ignored"
  if /usr/bin/git -C "${PROJECT_ROOT}" ls-files Vendor/Mihomo/cache Vendor/Mihomo/bin | /usr/bin/grep -q .; then
    fail "Generated Mihomo artifacts are tracked by Git"
  fi
fi

require_project_text "/* Verify Mihomo Core */"
require_project_text "/* Embed and Sign Mihomo Core */"
require_project_text "/* Embed Mihomo Metadata */"
require_project_text 'Scripts/Mihomo/sign-embedded-mihomo.sh'
require_project_text '"$(SRCROOT)/Vendor/Mihomo/bin/mihomo",'
require_project_text '"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/mihomo",'
require_project_text 'dstPath = ThirdParty/Mihomo;'
require_project_text 'dstSubfolderSpec = 7;'
require_project_text 'CodeSignOnCopy'

if /usr/bin/grep -Fq '/* Sign Embedded Mihomo Core */' "${PROJECT_FILE}"; then
  fail "Mihomo copy and signing must have exactly one build-phase producer"
fi

ARCH_SETTING_COUNT="$(/usr/bin/grep -c 'ARCHS = arm64;' "${PROJECT_FILE}")"
[[ "${ARCH_SETTING_COUNT}" -ge "6" ]] || fail "App, Unit Test, and UI Test targets are not all arm64-only"

APP_RELEASE_BLOCK="$(/usr/bin/awk '
  /^\t\tC43CFA1E3001FF9A00936665 \/\* Release \*\/ = \{/ { found = 1 }
  found { print }
  found && /^\t\t};$/ { exit }
' "${PROJECT_FILE}")"
printf '%s\n' "${APP_RELEASE_BLOCK}" | /usr/bin/grep -Fq 'ENABLE_HARDENED_RUNTIME = YES;' ||
  fail "Vela Release is missing Hardened Runtime"

VELA_TARGET_BLOCK="$(/usr/bin/awk '
  /^\t\tC43CF9FA3001FF9700936665 \/\* Vela \*\/ = \{/ { found = 1 }
  found { print }
  found && /^\t\t};$/ { exit }
' "${PROJECT_FILE}")"
VERIFY_LINE="$(printf '%s\n' "${VELA_TARGET_BLOCK}" | /usr/bin/grep -n 'Verify Mihomo Core' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
EMBED_SIGN_LINE="$(printf '%s\n' "${VELA_TARGET_BLOCK}" | /usr/bin/grep -n 'Embed and Sign Mihomo Core' | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)"
[[ -n "${VERIFY_LINE}" && -n "${EMBED_SIGN_LINE}" && "${VERIFY_LINE}" -lt "${EMBED_SIGN_LINE}" ]] ||
  fail "Verify Mihomo Core must run before its single embed-and-sign producer"

/usr/bin/grep -Fq -- '--identifier "${EXPECTED_IDENTIFIER}"' \
  "${SCRIPT_DIR}/sign-embedded-mihomo.sh" ||
  fail "Embedded Mihomo signing must set an explicit identifier"
/usr/bin/grep -Fq 'EXPECTED_IDENTIFIER="mihomo"' \
  "${SCRIPT_DIR}/sign-embedded-mihomo.sh" ||
  fail "Embedded Mihomo signing identifier must remain exactly mihomo"
/usr/bin/grep -Fq 'TARGET_TEMP_DIR' \
  "${SCRIPT_DIR}/sign-embedded-mihomo.sh" ||
  fail "Embedded Mihomo signing must stage codesign scratch files outside the sandboxed Helpers directory"

printf 'Static Mihomo integration checks passed without downloading or executing Mihomo.\n'
