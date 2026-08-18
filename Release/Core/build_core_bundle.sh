#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
MODE="dry-run"
SEED=""
CORE_BINARY=""
COMPATIBILITY=""
DEDICATED_EVIDENCE=""
PERFORMANCE_REVIEW=""
LICENSE_FILE=""
OUTPUT=""
BUNDLE_IDENTIFIER=""
REVISION=""
IDENTITY=""
KEYCHAIN=""

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s --dry-run|--execute --seed FILE --compatibility-report FILE --license FILE --bundle-identifier ID --package-revision N [--dedicated-host-evidence FILE --performance-review FILE --core-binary FILE --output PATH --identity NAME --keychain FILE]\n' "$0" >&2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --seed) SEED="${2:-}"; shift 2 ;;
    --core-binary) CORE_BINARY="${2:-}"; shift 2 ;;
    --compatibility-report) COMPATIBILITY="${2:-}"; shift 2 ;;
    --dedicated-host-evidence) DEDICATED_EVIDENCE="${2:-}"; shift 2 ;;
    --performance-review) PERFORMANCE_REVIEW="${2:-}"; shift 2 ;;
    --license) LICENSE_FILE="${2:-}"; shift 2 ;;
    --bundle-identifier) BUNDLE_IDENTIFIER="${2:-}"; shift 2 ;;
    --package-revision) REVISION="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done
[[ -f "${SEED}" && ! -L "${SEED}" ]] || fail "--seed must be a regular file"
[[ -f "${COMPATIBILITY}" && ! -L "${COMPATIBILITY}" ]] || fail "--compatibility-report must be a regular file"
[[ -f "${LICENSE_FILE}" && ! -L "${LICENSE_FILE}" ]] || fail "--license must be a regular file"
[[ -n "${BUNDLE_IDENTIFIER}" && "${REVISION}" =~ ^[1-9][0-9]*$ ]] || fail "bundle identifier/revision are required"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_upstream_seed.py" "${SEED}"
/usr/bin/python3 - "${COMPATIBILITY}" "${BUNDLE_IDENTIFIER}" "${REVISION}" <<'PY'
import json, pathlib, re, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if value.get("schemaVersion") != 1 or value.get("coreID", "").rsplit("-r", 1)[-1] != sys.argv[3]:
    raise SystemExit("error: compatibility report/revision mismatch")
if re.fullmatch(r"[A-Za-z0-9.-]+\.MihomoCore", sys.argv[2]) is None:
    raise SystemExit("error: invalid stable Core bundle identifier")
PY
if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Core Bundle build dry-run passed. No bundle creation, signing, timestamp, or notarization ran.\n'
  exit 0
fi
[[ -f "${DEDICATED_EVIDENCE}" && ! -L "${DEDICATED_EVIDENCE}" ]] || fail "--dedicated-host-evidence must be a regular file"
[[ -f "${PERFORMANCE_REVIEW}" && ! -L "${PERFORMANCE_REVIEW}" ]] || fail "--performance-review must be a regular file"
[[ "${VELA_CORE_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_CORE_RELEASE_EXECUTE=YES and pass --execute"
[[ -f "${CORE_BINARY}" && ! -L "${CORE_BINARY}" && -x "${CORE_BINARY}" ]] || fail "--core-binary must be an executable regular file"
[[ -n "${OUTPUT}" && "${OUTPUT}" == *.bundle && ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || fail "--output must be a new .bundle path"
[[ -n "${IDENTITY}" ]] || fail "--identity must explicitly name a Developer ID Application identity"
[[ "${IDENTITY}" == Developer\ ID\ Application:* ]] || fail "Core signing identity must be Developer ID Application"
[[ -f "${KEYCHAIN}" && ! -L "${KEYCHAIN}" && "$(/usr/bin/stat -f '%Lp' "${KEYCHAIN}")" == "600" ]] || fail "--keychain must be an explicit 0600 ephemeral Keychain"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Core signing requires Apple Silicon"
/usr/bin/env python3 "${SCRIPT_DIR}/CompatibilityLab/validate_compatibility_report.py" \
  "${COMPATIBILITY}" --core-id "$(/usr/bin/python3 - "${COMPATIBILITY}" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["coreID"])
PY
)" --dedicated-host-evidence "${DEDICATED_EVIDENCE}" \
  --performance-review "${PERFORMANCE_REVIEW}" --production
REPORT_CORE_SHA="$(/usr/bin/python3 - "${COMPATIBILITY}" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["artifacts"]["upstreamPayloadSHA256"])
PY
)"
ACTUAL_CORE_SHA="$(/usr/bin/shasum -a 256 "${CORE_BINARY}" | /usr/bin/awk '{print $1}')"
[[ "${REPORT_CORE_SHA}" == "${ACTUAL_CORE_SHA}" ]] || fail "compatibility report upstream payload hash differs from the unsigned Core binary being signed"
/usr/bin/security show-keychain-info "${KEYCHAIN}" >/dev/null 2>&1 || fail "Core signing Keychain is unavailable or locked"
/usr/bin/security find-identity -p codesigning -v "${KEYCHAIN}" | /usr/bin/grep -Fq "\"${IDENTITY}\"" || fail "Core signing identity is unavailable in the explicit Keychain"
[[ "$(/usr/bin/lipo -archs "${CORE_BINARY}")" == "arm64" ]] || fail "Core executable must be thin arm64"

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="$(cd "${TEMP_ROOT}" && /bin/pwd -P)"
WORK="$(/usr/bin/mktemp -d "${TEMP_ROOT}/vela-core-build.XXXXXX")"
cleanup() {
  local status=$?
  case "${WORK}" in "${TEMP_ROOT}"/vela-core-build.*) /bin/rm -rf "${WORK}" ;; esac
  return "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_resources.py" \
  --seed "${SEED}" --compatibility-report "${COMPATIBILITY}" --license "${LICENSE_FILE}" \
  --dedicated-host-evidence "${DEDICATED_EVIDENCE}" --performance-review "${PERFORMANCE_REVIEW}" \
  --bundle-identifier "${BUNDLE_IDENTIFIER}" --package-revision "${REVISION}" \
  --output-directory "${WORK}/metadata" --production
BUNDLE="${WORK}/VelaMihomoCore.bundle"
/bin/mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
/bin/cp -p "${WORK}/metadata/Info.plist" "${BUNDLE}/Contents/Info.plist"
/bin/cp -p "${CORE_BINARY}" "${BUNDLE}/Contents/MacOS/mihomo"
/bin/cp -p "${WORK}/metadata/Resources/"* "${BUNDLE}/Contents/Resources/"
/bin/chmod 0755 "${BUNDLE}/Contents/MacOS/mihomo"
/bin/chmod 0644 "${BUNDLE}/Contents/Info.plist" "${BUNDLE}/Contents/Resources/"*
/usr/bin/codesign --force --options runtime --timestamp --keychain "${KEYCHAIN}" --sign "${IDENTITY}" "${BUNDLE}"
/bin/chmod 0644 "${BUNDLE}/Contents/_CodeSignature/CodeResources"
/usr/bin/codesign --verify --strict --verbose=4 "${BUNDLE}"
/bin/mv -n "${BUNDLE}" "${OUTPUT}"
[[ -d "${OUTPUT}" && ! -e "${BUNDLE}" ]] || fail "Core Bundle output appeared concurrently"
printf 'Built signed Core Bundle: %s\n' "${OUTPUT}"
