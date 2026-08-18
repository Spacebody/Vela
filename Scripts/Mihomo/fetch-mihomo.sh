#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 022

readonly EXPECTED_VERSION="v1.19.29"
readonly EXPECTED_PLATFORM="darwin"
readonly EXPECTED_ARCHITECTURE="arm64"
readonly EXPECTED_ASSET_NAME="mihomo-darwin-arm64-v1.19.29.gz"
readonly EXPECTED_ASSET_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-darwin-arm64-v1.19.29.gz"
readonly EXPECTED_ARCHIVE_SHA256="4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca"
readonly EXPECTED_ARCHIVE_SIZE="15858351"

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

[[ "$#" == "0" ]] || fail "Usage: $0"
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

CACHE_DIR="${PROJECT_ROOT}/Vendor/Mihomo/cache"
BIN_DIR="${PROJECT_ROOT}/Vendor/Mihomo/bin"
ARCHIVE_PATH="${CACHE_DIR}/${ASSET_NAME}"
BINARY_PATH="${BIN_DIR}/mihomo"

/bin/mkdir -p "${CACHE_DIR}" "${BIN_DIR}"

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-mihomo.XXXXXX")"
TEMP_ARCHIVE="${TEMP_DIR}/${ASSET_NAME}"
TEMP_BINARY="${TEMP_DIR}/mihomo"
STAGED_ARCHIVE="${CACHE_DIR}/.${ASSET_NAME}.new.$$"
STAGED_BINARY="${BIN_DIR}/.mihomo.new.$$"
BACKUP_ARCHIVE="${CACHE_DIR}/.${ASSET_NAME}.backup.$$"
BACKUP_BINARY="${BIN_DIR}/.mihomo.backup.$$"
ARCHIVE_BACKED_UP=0
BINARY_BACKED_UP=0
ARCHIVE_INSTALLED=0
BINARY_INSTALLED=0
COMMITTED=0

cleanup() {
  local status=$?
  if [[ "${COMMITTED}" != "1" ]]; then
    if [[ "${ARCHIVE_INSTALLED}" == "1" ]]; then
      /bin/rm -f "${ARCHIVE_PATH}" || true
    fi
    if [[ "${BINARY_INSTALLED}" == "1" ]]; then
      /bin/rm -f "${BINARY_PATH}" || true
    fi
    if [[ "${ARCHIVE_BACKED_UP}" == "1" && ( -e "${BACKUP_ARCHIVE}" || -L "${BACKUP_ARCHIVE}" ) ]]; then
      /bin/mv -f "${BACKUP_ARCHIVE}" "${ARCHIVE_PATH}" || true
    fi
    if [[ "${BINARY_BACKED_UP}" == "1" && ( -e "${BACKUP_BINARY}" || -L "${BACKUP_BINARY}" ) ]]; then
      /bin/mv -f "${BACKUP_BINARY}" "${BINARY_PATH}" || true
    fi
  fi
  /bin/rm -rf "${TEMP_DIR}" || true
  /bin/rm -f "${STAGED_ARCHIVE}" "${STAGED_BINARY}" "${BACKUP_ARCHIVE}" "${BACKUP_BINARY}" || true
  return "${status}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

printf 'Downloading pinned Mihomo asset:\n  %s\n' "${ASSET_URL}"
/usr/bin/curl \
  --fail \
  --location \
  --silent \
  --show-error \
  --retry 3 \
  --connect-timeout 20 \
  --max-time 900 \
  --proto '=https' \
  --proto-redir '=https' \
  --output "${TEMP_ARCHIVE}" \
  "${EXPECTED_ASSET_URL}"

[[ -f "${TEMP_ARCHIVE}" && ! -L "${TEMP_ARCHIVE}" ]] || fail "Downloaded archive is not a regular file"
ACTUAL_SIZE="$(/usr/bin/stat -f '%z' "${TEMP_ARCHIVE}")"
[[ "${ACTUAL_SIZE}" == "${EXPECTED_SIZE}" ]] ||
  fail "Archive size mismatch. Expected ${EXPECTED_SIZE}, got ${ACTUAL_SIZE}"

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "${TEMP_ARCHIVE}" | /usr/bin/awk '{print $1}')"
[[ "${ACTUAL_SHA256}" == "${EXPECTED_SHA256}" ]] ||
  fail "Archive SHA-256 mismatch. Expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}"

/usr/bin/gzip -t "${TEMP_ARCHIVE}" || fail "Archive gzip validation failed"
/usr/bin/gzip -dc "${TEMP_ARCHIVE}" > "${TEMP_BINARY}"
[[ -s "${TEMP_BINARY}" && -f "${TEMP_BINARY}" && ! -L "${TEMP_BINARY}" ]] ||
  fail "Decompressed binary is not a non-empty regular file"

/bin/chmod 0755 "${TEMP_BINARY}"
/usr/bin/xattr -c "${TEMP_BINARY}" 2>/dev/null || true

ARCHS="$(/usr/bin/lipo -archs "${TEMP_BINARY}" 2>/dev/null || true)"
[[ "${ARCHS}" == "arm64" ]] || fail "Expected thin arm64 Mach-O, got: ${ARCHS:-unknown}"
/usr/bin/file "${TEMP_BINARY}" | /usr/bin/grep -Eq 'Mach-O 64-bit executable arm64' ||
  fail "Decompressed file is not a Mach-O 64-bit arm64 executable"

VERSION_OUTPUT="$("${TEMP_BINARY}" -v 2>&1)" || fail "mihomo -v failed"
assert_version_output "${VERSION_OUTPUT}"

/bin/cp -f "${TEMP_ARCHIVE}" "${STAGED_ARCHIVE}"
/bin/cp -f "${TEMP_BINARY}" "${STAGED_BINARY}"
/bin/chmod 0644 "${STAGED_ARCHIVE}"
/bin/chmod 0755 "${STAGED_BINARY}"

if [[ -e "${ARCHIVE_PATH}" || -L "${ARCHIVE_PATH}" ]]; then
  [[ -f "${ARCHIVE_PATH}" && ! -L "${ARCHIVE_PATH}" ]] ||
    fail "Existing archive is not a regular file: ${ARCHIVE_PATH}"
  /bin/mv "${ARCHIVE_PATH}" "${BACKUP_ARCHIVE}"
  ARCHIVE_BACKED_UP=1
fi
if [[ -e "${BINARY_PATH}" || -L "${BINARY_PATH}" ]]; then
  [[ -f "${BINARY_PATH}" && ! -L "${BINARY_PATH}" ]] ||
    fail "Existing binary is not a regular file: ${BINARY_PATH}"
  /bin/mv "${BINARY_PATH}" "${BACKUP_BINARY}"
  BINARY_BACKED_UP=1
fi

/bin/mv "${STAGED_ARCHIVE}" "${ARCHIVE_PATH}"
ARCHIVE_INSTALLED=1
/bin/mv "${STAGED_BINARY}" "${BINARY_PATH}"
BINARY_INSTALLED=1
/bin/chmod 0644 "${ARCHIVE_PATH}"
/bin/chmod 0755 "${BINARY_PATH}"
COMMITTED=1

/bin/rm -f "${BACKUP_ARCHIVE}" "${BACKUP_BINARY}"

printf 'Installed verified Mihomo core:\n'
printf '  Version:      %s\n' "${VERSION_OUTPUT}"
printf '  Archive:      %s\n' "${ARCHIVE_PATH}"
printf '  Binary:       %s\n' "${BINARY_PATH}"
printf '  Archive SHA:  %s\n' "${ACTUAL_SHA256}"
printf '  Architecture: %s\n' "${ARCHS}"
