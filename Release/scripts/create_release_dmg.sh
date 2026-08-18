#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

APP=""
OUTPUT=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s --app /path/to/Vela.app --output /new/path/Vela-version-arm64.dmg\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done

[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "DMG creation must run on Apple Silicon"
[[ -d "${APP}" && ! -L "${APP}" && "${APP}" == *.app ]] || fail "--app must be a regular App bundle"
[[ -n "${OUTPUT}" && "${OUTPUT}" == *.dmg ]] || fail "--output must end in .dmg"
[[ ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "refusing to overwrite immutable DMG output"

OUTPUT_PARENT="$(/usr/bin/dirname "${OUTPUT}")"
/bin/mkdir -p "${OUTPUT_PARENT}"
[[ -d "${OUTPUT_PARENT}" && ! -L "${OUTPUT_PARENT}" ]] || fail "DMG output parent is unsafe"
OUTPUT_PARENT="$(cd "${OUTPUT_PARENT}" && /bin/pwd -P)"
OUTPUT="${OUTPUT_PARENT}/$(/usr/bin/basename "${OUTPUT}")"

WORK="$(/usr/bin/mktemp -d "${OUTPUT_PARENT}/.vela-dmg.XXXXXX")"
cleanup() {
  local result=$?
  case "${WORK}" in
    "${OUTPUT_PARENT}"/.vela-dmg.*) /bin/rm -rf "${WORK}" ;;
    *) printf 'warning: refused to clean unexpected DMG staging path\n' >&2 ;;
  esac
  return "${result}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

STAGE="${WORK}/stage"
TEMP_DMG="${WORK}/Vela.dmg"
/bin/mkdir -p "${STAGE}"
/usr/bin/ditto "${APP}" "${STAGE}/Vela.app"
/bin/ln -s /Applications "${STAGE}/Applications"

/usr/bin/hdiutil create \
  -fs APFS \
  -format ULFO \
  -volname Vela \
  -srcfolder "${STAGE}" \
  "${TEMP_DMG}"

/usr/bin/hdiutil imageinfo "${TEMP_DMG}" >/dev/null
/bin/ln "${TEMP_DMG}" "${OUTPUT}" || fail "DMG output appeared concurrently; refusing overwrite"
/bin/chmod 0644 "${OUTPUT}"
printf 'Created immutable APFS/LZFSE DMG: %s\n' "${OUTPUT}"
