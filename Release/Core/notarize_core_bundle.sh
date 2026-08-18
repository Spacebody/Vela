#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

MODE="dry-run"
BUNDLE=""
RECEIPT_DIR=""
ARCHIVE_OUTPUT=""
KEYCHAIN=""
PROFILE=""
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s --dry-run|--execute [--bundle PATH --receipt-dir DIR --archive-output ZIP --keychain FILE --profile NAME]\n' "$0" >&2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --receipt-dir) RECEIPT_DIR="${2:-}"; shift 2 ;;
    --archive-output) ARCHIVE_OUTPUT="${2:-}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done
/usr/bin/xcrun notarytool --version >/dev/null
if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Core notarization dry-run passed. No ZIP, upload, receipt, staple, or simulated acceptance was produced.\n'
  exit 0
fi
[[ "${VELA_CORE_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_CORE_RELEASE_EXECUTE=YES and pass --execute"
[[ -d "${BUNDLE}" && ! -L "${BUNDLE}" && "${BUNDLE}" == *.bundle ]] || fail "--bundle must be a regular signed Core Bundle"
[[ -n "${RECEIPT_DIR}" && ! -L "${RECEIPT_DIR}" ]] || fail "--receipt-dir is required and must not be a symlink"
[[ "${ARCHIVE_OUTPUT}" == *.zip && ! -e "${ARCHIVE_OUTPUT}" && ! -L "${ARCHIVE_OUTPUT}" ]] || fail "--archive-output must be a new ZIP path"
[[ -f "${KEYCHAIN}" && ! -L "${KEYCHAIN}" && "$(/usr/bin/stat -f '%Lp' "${KEYCHAIN}")" == "600" ]] || fail "--keychain must be an explicit 0600 ephemeral Keychain"
[[ "${PROFILE}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--profile must name a protected notarytool profile"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Core notarization requires Apple Silicon"
/usr/bin/security show-keychain-info "${KEYCHAIN}" >/dev/null 2>&1 || fail "notary Keychain is unavailable or locked"
/usr/bin/codesign --verify --strict --verbose=4 "${BUNDLE}"
/bin/mkdir -p "${RECEIPT_DIR}" "$(/usr/bin/dirname "${ARCHIVE_OUTPUT}")"
[[ -d "${RECEIPT_DIR}" && ! -L "${RECEIPT_DIR}" ]] || fail "receipt directory is unsafe"
RESULT="${RECEIPT_DIR}/notary-core-result.json"
LOG="${RECEIPT_DIR}/notary-core-log.json"
[[ ! -e "${RESULT}" && ! -L "${RESULT}" && ! -e "${LOG}" && ! -L "${LOG}" ]] || fail "notary evidence output already exists"

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="$(cd "${TEMP_ROOT}" && /bin/pwd -P)"
WORK="$(/usr/bin/mktemp -d "${TEMP_ROOT}/vela-core-notary.XXXXXX")"
cleanup() {
  local status=$?
  case "${WORK}" in "${TEMP_ROOT}"/vela-core-notary.*) /bin/rm -rf "${WORK}" ;; esac
  return "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
TEMP_ZIP="${WORK}/VelaMihomoCore-notary.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${BUNDLE}" "${TEMP_ZIP}"
/bin/ln "${TEMP_ZIP}" "${ARCHIVE_OUTPUT}" || fail "notary ZIP output appeared concurrently"
/bin/chmod 0600 "${ARCHIVE_OUTPUT}"
TEMP_RESULT="${WORK}/result.json"
SUBMIT_EXIT=0
/usr/bin/xcrun notarytool submit "${ARCHIVE_OUTPUT}" \
  --keychain-profile "${PROFILE}" --keychain "${KEYCHAIN}" --wait --output-format json \
  >"${TEMP_RESULT}" || SUBMIT_EXIT=$?
[[ -s "${TEMP_RESULT}" ]] || fail "notarytool returned no receipt"
/usr/bin/plutil -lint "${TEMP_RESULT}" >/dev/null || fail "notarytool receipt is invalid"
/bin/chmod 0600 "${TEMP_RESULT}"
/bin/ln "${TEMP_RESULT}" "${RESULT}" || fail "notary receipt appeared concurrently"
STATUS="$(/usr/bin/plutil -extract status raw -o - "${RESULT}" 2>/dev/null || true)"
IDENTIFIER="$(/usr/bin/plutil -extract id raw -o - "${RESULT}" 2>/dev/null || true)"
if [[ "${SUBMIT_EXIT}" != "0" || "${STATUS}" != "Accepted" ]]; then
  if [[ -n "${IDENTIFIER}" ]]; then
    /usr/bin/xcrun notarytool log "${IDENTIFIER}" \
      --keychain-profile "${PROFILE}" --keychain "${KEYCHAIN}" --output-format json >"${LOG}" || true
    /bin/chmod 0600 "${LOG}" 2>/dev/null || true
  fi
  fail "Core notarization was not Accepted (status=${STATUS:-unknown}, id=${IDENTIFIER:-unknown})"
fi
[[ -n "${IDENTIFIER}" ]] || fail "accepted Core notarization receipt lacks an identifier"
/usr/bin/xcrun notarytool log "${IDENTIFIER}" \
  --keychain-profile "${PROFILE}" --keychain "${KEYCHAIN}" --output-format json >"${LOG}"
[[ -s "${LOG}" ]] || fail "accepted Core notarization log is empty"
/usr/bin/plutil -lint "${LOG}" >/dev/null || fail "accepted Core notarization log is invalid"
/bin/chmod 0600 "${LOG}"
# Generic code bundles do not have a reliable stapling target. Preserve the
# immutable accepted ticket plus strict signature evidence with the release.
printf 'Core notarization accepted: id=%s receipt=%s archive=%s\n' "${IDENTIFIER}" "${RESULT}" "${ARCHIVE_OUTPUT}"
