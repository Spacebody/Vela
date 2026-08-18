#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"

EXECUTE=0
STATIC_MIHOMO=0
APP_PATH=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--execute] [--static-mihomo] /path/to/Vela.app\n' "$0" >&2
  printf '  Default: distribution preflight only; no upload or staple.\n' >&2
  printf '  Execute: VELA_RUN_NOTARIZATION=1 NOTARY_PROFILE=name %s --execute /path/to/Vela.app\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --execute)
      EXECUTE=1
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
[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] || fail "App bundle not found or is a symlink: ${APP_PATH}"

VERIFY_ARGUMENTS=(--distribution)
if [[ "${STATIC_MIHOMO}" == "1" ]]; then
  VERIFY_ARGUMENTS+=(--static-mihomo)
fi
VERIFY_ARGUMENTS+=("${APP_PATH}")
"${SCRIPT_DIR}/verify-privileged-bundle.sh" "${VERIFY_ARGUMENTS[@]}"

if [[ "${EXECUTE}" != "1" ]]; then
  printf '\nNotarization preflight passed. No upload or bundle mutation was performed.\n'
  printf 'To submit and staple explicitly:\n'
  printf '  VELA_RUN_NOTARIZATION=1 NOTARY_PROFILE=<keychain-profile> %q --execute %q\n' "$0" "${APP_PATH}"
  exit 0
fi

[[ "${STATIC_MIHOMO}" != "1" ]] || fail "--static-mihomo is not allowed for a notarization submission"
[[ "${VELA_RUN_NOTARIZATION:-0}" == "1" ]] || \
  fail "Refusing notarization: set VELA_RUN_NOTARIZATION=1 and pass --execute"
[[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to an xcrun notarytool Keychain profile"

WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-notary.XXXXXX")"
cleanup() {
  local status=$?
  case "${WORK_DIR}" in
    "${TMPDIR:-/tmp}"/vela-notary.*|/tmp/vela-notary.*)
      /bin/rm -rf "${WORK_DIR}" || true
      ;;
    *)
      printf 'warning: refused to remove unexpected temporary path: %s\n' "${WORK_DIR}" >&2
      ;;
  esac
  return "${status}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

ZIP_PATH="${WORK_DIR}/Vela-notary-upload.zip"
RESULT_PATH="${WORK_DIR}/notary-result.json"
/usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

SUBMIT_EXIT=0
/usr/bin/xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait \
  --output-format json > "${RESULT_PATH}" || SUBMIT_EXIT=$?

if ! /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby -rjson -e \
  'value = JSON.parse(File.binread(ARGV.fetch(0)), create_additions: false); abort unless value.is_a?(Hash)' \
  "${RESULT_PATH}"
then
  fail "notarytool failed with exit ${SUBMIT_EXIT} and did not return a JSON result"
fi
NOTARY_STATUS="$(/usr/bin/plutil -extract status raw -o - "${RESULT_PATH}" 2>/dev/null || true)"
NOTARY_ID="$(/usr/bin/plutil -extract id raw -o - "${RESULT_PATH}" 2>/dev/null || true)"
printf 'notarytool result: id=%s status=%s exit=%s\n' \
  "${NOTARY_ID:-unknown}" "${NOTARY_STATUS:-unknown}" "${SUBMIT_EXIT}"
if [[ "${SUBMIT_EXIT}" != "0" || "${NOTARY_STATUS}" != "Accepted" ]]; then
  if [[ -n "${NOTARY_ID}" ]]; then
    printf 'Notarization log for %s:\n' "${NOTARY_ID}" >&2
    /usr/bin/xcrun notarytool log "${NOTARY_ID}" \
      --keychain-profile "${NOTARY_PROFILE}" >&2 || true
  fi
  fail "Notarization was not Accepted (status=${NOTARY_STATUS:-unknown}, id=${NOTARY_ID:-unknown}, exit=${SUBMIT_EXIT})"
fi

/usr/bin/xcrun stapler staple "${APP_PATH}"
"${SCRIPT_DIR}/verify-privileged-bundle.sh" --post-notary "${APP_PATH}"

printf 'Notarization gate passed:\n'
printf '  Submission ID: %s\n' "${NOTARY_ID}"
printf '  Status:        %s\n' "${NOTARY_STATUS}"
printf '  Staple:        validated\n'
printf '  Gatekeeper:    accepted\n'
