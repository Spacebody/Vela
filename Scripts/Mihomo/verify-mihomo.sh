#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

readonly EXPECTED_VERSION="v1.19.29"
readonly EXPECTED_PLATFORM="darwin"
readonly EXPECTED_ARCHITECTURE="arm64"
readonly EXPECTED_ASSET_NAME="mihomo-darwin-arm64-v1.19.29.gz"
readonly EXPECTED_ASSET_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-darwin-arm64-v1.19.29.gz"
readonly EXPECTED_ARCHIVE_SHA256="4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca"
readonly EXPECTED_ARCHIVE_SIZE="15858351"

STATIC_ONLY=0
if [[ "${1:-}" == "--static" ]]; then
  STATIC_ONLY=1
  shift
fi
[[ "$#" == "0" ]] || {
  printf 'error: Usage: %s [--static]\n' "$0" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MANIFEST="${PROJECT_ROOT}/Vendor/Mihomo/manifest.json"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

read_manifest() {
  /usr/bin/plutil -extract "$1" raw -o - "${MANIFEST}"
}

assert_version_output() {
  local output="$1"
  local first_line
  first_line="$(printf '%s\n' "${output}" | /usr/bin/awk 'NF { print; exit }')"
  [[ "${first_line}" =~ ^Mihomo[[:space:]]Meta[[:space:]]v1\.19\.29[[:space:]]darwin[[:space:]]arm64([[:space:]].*)?$ ]] ||
    fail "Unexpected Mihomo version output: ${output}"
}

[[ -f "${MANIFEST}" && ! -L "${MANIFEST}" ]] || fail "Missing regular manifest: ${MANIFEST}"

VERSION="$(read_manifest version)"
PLATFORM="$(read_manifest platform)"
ARCHITECTURE="$(read_manifest architecture)"
ASSET_NAME="$(read_manifest assetName)"
ASSET_URL="$(read_manifest assetURL)"
EXPECTED_SHA256="$(read_manifest archiveSHA256)"
EXPECTED_SIZE="$(read_manifest archiveSizeBytes)"
RUNTIME_DOWNLOAD_ALLOWED="$(read_manifest runtimeDownloadAllowed)"

[[ "${VERSION}" == "${EXPECTED_VERSION}" ]] || fail "Unexpected version: ${VERSION}"
[[ "${PLATFORM}" == "${EXPECTED_PLATFORM}" ]] || fail "Unexpected platform: ${PLATFORM}"
[[ "${ARCHITECTURE}" == "${EXPECTED_ARCHITECTURE}" ]] || fail "Unexpected architecture: ${ARCHITECTURE}"
[[ "${ASSET_NAME}" == "${EXPECTED_ASSET_NAME}" ]] || fail "Unexpected asset: ${ASSET_NAME}"
[[ "${ASSET_URL}" == "${EXPECTED_ASSET_URL}" ]] || fail "Unexpected asset URL: ${ASSET_URL}"
[[ "${EXPECTED_SHA256}" == "${EXPECTED_ARCHIVE_SHA256}" ]] || fail "Unexpected archive SHA-256"
[[ "${EXPECTED_SIZE}" == "${EXPECTED_ARCHIVE_SIZE}" ]] || fail "Unexpected archive size"
[[ "${RUNTIME_DOWNLOAD_ALLOWED}" == "false" ]] || fail "Runtime download must remain disabled"

ARCHIVE="${PROJECT_ROOT}/Vendor/Mihomo/cache/${ASSET_NAME}"
BINARY="${PROJECT_ROOT}/Vendor/Mihomo/bin/mihomo"
LICENSE="${PROJECT_ROOT}/Vendor/Mihomo/LICENSE"
NOTICE="${PROJECT_ROOT}/Vendor/Mihomo/NOTICE.md"

[[ -f "${ARCHIVE}" && ! -L "${ARCHIVE}" ]] ||
  fail "Missing regular archive. Run ./Scripts/Mihomo/fetch-mihomo.sh first"
[[ -f "${BINARY}" && ! -L "${BINARY}" ]] ||
  fail "Missing regular binary. Run ./Scripts/Mihomo/fetch-mihomo.sh first"
[[ -x "${BINARY}" ]] || fail "Binary is not executable"
[[ -f "${LICENSE}" && ! -L "${LICENSE}" ]] || fail "Missing regular Vendor/Mihomo/LICENSE"
[[ -f "${NOTICE}" && ! -L "${NOTICE}" ]] || fail "Missing regular Vendor/Mihomo/NOTICE.md"

ACTUAL_SIZE="$(/usr/bin/stat -f '%z' "${ARCHIVE}")"
[[ "${ACTUAL_SIZE}" == "${EXPECTED_SIZE}" ]] ||
  fail "Archive size mismatch. Expected ${EXPECTED_SIZE}, got ${ACTUAL_SIZE}"

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "${ARCHIVE}" | /usr/bin/awk '{print $1}')"
[[ "${ACTUAL_SHA256}" == "${EXPECTED_SHA256}" ]] ||
  fail "Archive SHA-256 mismatch. Expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}"

/usr/bin/gzip -t "${ARCHIVE}" || fail "Archive gzip validation failed"
ARCHIVE_CONTENT_SHA="$(
  /usr/bin/gzip -dc "${ARCHIVE}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
)"
BINARY_SHA="$(/usr/bin/shasum -a 256 "${BINARY}" | /usr/bin/awk '{print $1}')"
[[ "${ARCHIVE_CONTENT_SHA}" == "${BINARY_SHA}" ]] ||
  fail "Binary does not match the verified archive content"

ARCHS="$(/usr/bin/lipo -archs "${BINARY}" 2>/dev/null || true)"
[[ "${ARCHS}" == "arm64" ]] || fail "Expected thin arm64 Mach-O, got: ${ARCHS:-unknown}"
/usr/bin/file "${BINARY}" | /usr/bin/grep -Eq 'Mach-O 64-bit executable arm64' ||
  fail "Binary is not a Mach-O 64-bit arm64 executable"

VERSION_OUTPUT="not executed (--static)"
if [[ "${STATIC_ONLY}" != "1" ]]; then
  VERSION_OUTPUT="$("${BINARY}" -v 2>&1)" || fail "mihomo -v failed"
  assert_version_output "${VERSION_OUTPUT}"
fi

printf 'Mihomo verification passed:\n'
printf '  Version check:       %s\n' "${VERSION_OUTPUT}"
printf '  Archive SHA-256:     %s\n' "${ACTUAL_SHA256}"
printf '  Binary SHA-256:      %s\n' "${BINARY_SHA}"
printf '  Architecture:        %s\n' "${ARCHS}"
