#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
MODE="dry-run"
SEED=""
OUTPUT=""

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s --dry-run|--execute --seed FILE [--output DIR]\n' "$0" >&2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --seed) SEED="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done
[[ -f "${SEED}" && ! -L "${SEED}" ]] || fail "--seed must be a regular non-symlink file"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_upstream_seed.py" "${SEED}"
if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Upstream Core fetch dry-run passed. No network request or filesystem mutation ran.\n'
  exit 0
fi
[[ "${VELA_CORE_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_CORE_RELEASE_EXECUTE=YES and pass --execute"
[[ -n "${OUTPUT}" && ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "--output must be a new path"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Core release fetching requires Apple Silicon"

json_value() {
  /usr/bin/python3 - "${SEED}" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]]
print(value)
PY
}
ASSET_NAME="$(json_value assetName)"
ASSET_URL="$(json_value assetURL)"
EXPECTED_SHA="$(json_value archiveSHA256)"
EXPECTED_SIZE="$(json_value archiveSizeBytes)"
VERSION="$(json_value version)"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="$(cd "${TEMP_ROOT}" && /bin/pwd -P)"
WORK="$(/usr/bin/mktemp -d "${TEMP_ROOT}/vela-core-fetch.XXXXXX")"
cleanup() {
  local status=$?
  case "${WORK}" in "${TEMP_ROOT}"/vela-core-fetch.*) /bin/rm -rf "${WORK}" ;; esac
  return "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ARCHIVE="${WORK}/${ASSET_NAME}"
/usr/bin/curl --disable --fail --location --silent --show-error --retry 3 \
  --proto '=https' --proto-redir '=https' --output "${ARCHIVE}" "${ASSET_URL}"
[[ "$(/usr/bin/stat -f '%z' "${ARCHIVE}")" == "${EXPECTED_SIZE}" ]] || fail "upstream archive size mismatch"
[[ "$(/usr/bin/shasum -a 256 "${ARCHIVE}" | /usr/bin/awk '{print $1}')" == "${EXPECTED_SHA}" ]] || fail "upstream archive SHA-256 mismatch"
/usr/bin/gzip -t "${ARCHIVE}"
/usr/bin/gzip -dc "${ARCHIVE}" >"${WORK}/mihomo"
/bin/chmod 0755 "${WORK}/mihomo"
[[ "$(/usr/bin/lipo -archs "${WORK}/mihomo")" == "arm64" ]] || fail "upstream executable must be thin arm64"
VERSION_OUTPUT="$("${WORK}/mihomo" -v 2>&1)"
printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/grep -Fq "${VERSION}" || fail "upstream executable version mismatch"
printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/grep -Fq 'darwin arm64' || fail "upstream executable platform mismatch"
/bin/mkdir -m 0700 "${OUTPUT}"
/bin/mv "${ARCHIVE}" "${OUTPUT}/${ASSET_NAME}"
/bin/mv "${WORK}/mihomo" "${OUTPUT}/mihomo"
/bin/chmod 0600 "${OUTPUT}/${ASSET_NAME}"
/bin/chmod 0755 "${OUTPUT}/mihomo"
printf 'Fetched exact verified upstream Core: version=%s output=%s\n' "${VERSION}" "${OUTPUT}"
