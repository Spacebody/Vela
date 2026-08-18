#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
CONFIG="${SCRIPT_DIR}/config/core-release.json"
MODE="dry-run"
OUTPUT=""

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Usage: %s --dry-run [--config FILE] | --execute --output FILE [--config FILE]\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -f "${CONFIG}" && ! -L "${CONFIG}" ]] || fail "Core release config is missing or unsafe"
SEQUENCE="$(/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${CONFIG}" --production --emit sequence)"
if [[ "${SEQUENCE}" -le 1 ]]; then
  [[ -z "${OUTPUT}" || ! -e "${OUTPUT}" ]] || fail "sequence 1 may not create a prior Catalog output"
  printf 'Catalog sequence 1 requires no prior Catalog acquisition.\n'
  exit 0
fi

URL="$(/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${CONFIG}" --production --emit priorCatalogURL)"
EXPECTED_SHA256="$(/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${CONFIG}" --production --emit priorCatalogSHA256)"
PRIOR_SEQUENCE="$(/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${CONFIG}" --production --emit priorCatalogSequence)"
if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Prior Catalog acquisition plan: sequence=%s url=%s expectedSHA256=%s\n' \
    "${PRIOR_SEQUENCE}" "${URL}" "${EXPECTED_SHA256}"
  printf 'Dry-run performed no network request and created no file.\n'
  exit 0
fi

[[ "${VELA_CORE_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_CORE_RELEASE_EXECUTE=YES and pass --execute"
[[ -n "${OUTPUT}" && ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "--output must be a new immutable file path"
PARENT="$(/usr/bin/dirname "${OUTPUT}")"
[[ -d "${PARENT}" && ! -L "${PARENT}" ]] || fail "prior Catalog output parent is missing or unsafe"
PARENT="$(cd "${PARENT}" && /bin/pwd -P)"
OUTPUT="${PARENT}/$(/usr/bin/basename "${OUTPUT}")"
TEMP="$(/usr/bin/mktemp "${PARENT}/.vela-prior-catalog.XXXXXX")"
cleanup() { local status=$?; /bin/rm -f "${TEMP}"; return "${status}"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/curl --disable --fail --silent --show-error --proto '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 120 --max-filesize 2097152 \
  --output "${TEMP}" "${URL}"
[[ -s "${TEMP}" && "$(( $(/usr/bin/stat -f '%z' "${TEMP}") ))" -le 2097152 ]] || fail "downloaded prior Catalog is empty or oversized"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_prior_core_catalog.py" "${TEMP}" --config "${CONFIG}"
ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "${TEMP}" | /usr/bin/awk '{print $1}')"
[[ "${ACTUAL_SHA256}" == "${EXPECTED_SHA256}" ]] || fail "prior Catalog SHA-256 changed after verification"
/bin/chmod 0600 "${TEMP}"
/bin/mv -n "${TEMP}" "${OUTPUT}"
[[ -f "${OUTPUT}" && ! -e "${TEMP}" ]] || fail "prior Catalog output appeared concurrently"
printf 'Acquired immutable prior Core Catalog: %s\n' "${OUTPUT}"
