#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

MODE="dry-run"
BUNDLE=""
EXPECTED_TEAM=""
EXPECTED_IDENTIFIER=""
EXPECTED_VERSION=""
EXPECTED_REVISION=""
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s --dry-run|--production --bundle PATH --team TEAM --identifier ID --version vX.Y.Z --revision N\n' "$0" >&2; }
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --production) MODE="production"; shift ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --team) EXPECTED_TEAM="${2:-}"; shift 2 ;;
    --identifier) EXPECTED_IDENTIFIER="${2:-}"; shift 2 ;;
    --version) EXPECTED_VERSION="${2:-}"; shift 2 ;;
    --revision) EXPECTED_REVISION="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done
if [[ "${MODE}" == "dry-run" && -z "${BUNDLE}" ]]; then
  printf 'Core Bundle verification dry-run passed. Production requires a real signed bundle, Team ID, identifier, version, and revision.\n'
  exit 0
fi
[[ -d "${BUNDLE}" && ! -L "${BUNDLE}" && "${BUNDLE}" == *.bundle ]] || fail "--bundle must be a regular .bundle directory"
[[ -n "${EXPECTED_TEAM}" && -n "${EXPECTED_IDENTIFIER}" && "${EXPECTED_VERSION}" == v* && "${EXPECTED_REVISION}" =~ ^[1-9][0-9]*$ ]] || fail "expected Team/identifier/version/revision are required"
EXPECTED_FILES=(
  "Contents/Info.plist"
  "Contents/MacOS/mihomo"
  "Contents/_CodeSignature/CodeResources"
  "Contents/Resources/LICENSE"
  "Contents/Resources/NOTICE.md"
  "Contents/Resources/source.json"
  "Contents/Resources/compatibility.json"
)
if /usr/bin/find -P "${BUNDLE}" -type l -print -quit | /usr/bin/grep -q .; then fail "Core Bundle may not contain symlinks"; fi
ACTUAL_FILES=()
while IFS= read -r relative; do ACTUAL_FILES+=("${relative}"); done < <(cd "${BUNDLE}" && /usr/bin/find . -type f | /usr/bin/sed 's#^\./##' | /usr/bin/sort)
EXPECTED_SORTED=()
while IFS= read -r relative; do EXPECTED_SORTED+=("${relative}"); done < <(printf '%s\n' "${EXPECTED_FILES[@]}" | /usr/bin/sort)
[[ "${#ACTUAL_FILES[@]}" == "${#EXPECTED_SORTED[@]}" ]] || fail "Core Bundle contains missing or unexpected files"
for ((index=0; index<${#EXPECTED_SORTED[@]}; index++)); do
  [[ "${ACTUAL_FILES[$index]}" == "${EXPECTED_SORTED[$index]}" ]] || fail "Core Bundle fixed file set mismatch"
done
for relative in "${EXPECTED_FILES[@]}"; do
  path="${BUNDLE}/${relative}"
  [[ -f "${path}" && ! -L "${path}" ]] || fail "missing fixed Core file: ${relative}"
  expected_mode="644"; [[ "${relative}" == "Contents/MacOS/mihomo" ]] && expected_mode="755"
  [[ "$(/usr/bin/stat -f '%Lp' "${path}")" == "${expected_mode}" ]] || fail "Core file mode mismatch: ${relative}"
done
/usr/bin/plutil -lint "${BUNDLE}/Contents/Info.plist" >/dev/null
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "${BUNDLE}/Contents/Info.plist"; }
[[ "$(plist_value CFBundleIdentifier)" == "${EXPECTED_IDENTIFIER}" ]] || fail "Core Bundle identifier mismatch"
[[ "$(plist_value CFBundlePackageType)" == "BNDL" && "$(plist_value CFBundleExecutable)" == "mihomo" ]] || fail "Core Bundle type/executable mismatch"
[[ "$(plist_value VelaCoreVersion)" == "${EXPECTED_VERSION}" ]] || fail "Core Bundle version mismatch"
[[ "$(plist_value VelaCorePackageRevision)" == "${EXPECTED_REVISION}" ]] || fail "Core Bundle package revision mismatch"
[[ "$(plist_value VelaCoreArchitecture)" == "arm64" && "$(plist_value LSMinimumSystemVersion)" == "15.0" ]] || fail "Core Bundle platform metadata mismatch"
/usr/bin/codesign --verify --strict --verbose=4 "${BUNDLE}"
TEAM="$(/usr/bin/codesign -dvvv "${BUNDLE}" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
[[ "${TEAM}" == "${EXPECTED_TEAM}" ]] || fail "Core Bundle TeamIdentifier mismatch"
AUTHORITY="$(/usr/bin/codesign -dvvv "${BUNDLE}" 2>&1 | /usr/bin/awk -F= '$1 == "Authority" {print $2; exit}')"
[[ "${AUTHORITY}" == Developer\ ID\ Application:* ]] || fail "Core Bundle is not Developer ID Application signed"
/usr/bin/codesign -d --verbose=4 "${BUNDLE}" 2>&1 | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' || fail "Core Bundle lacks Hardened Runtime"
/usr/bin/codesign -dvvv "${BUNDLE}" 2>&1 | /usr/bin/grep -Eq '^Timestamp=' || fail "Core Bundle lacks a secure timestamp"
ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements - "${BUNDLE}" 2>/dev/null || true)"
if printf '%s' "${ENTITLEMENTS}" | /usr/bin/grep -q '<key>'; then fail "Core Bundle must not contain entitlements"; fi
CORE="${BUNDLE}/Contents/MacOS/mihomo"
[[ "$(/usr/bin/lipo -archs "${CORE}")" == "arm64" ]] || fail "Core executable must be thin arm64"
VERSION_OUTPUT="$("${CORE}" -v 2>&1)"
printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/grep -Fq "${EXPECTED_VERSION}" || fail "Core executable version mismatch"
printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/grep -Fq 'darwin arm64' || fail "Core executable platform mismatch"
/usr/bin/python3 - "${BUNDLE}" "${EXPECTED_VERSION}" "${EXPECTED_REVISION}" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
source = json.loads((root / "Contents/Resources/source.json").read_text(encoding="utf-8"))
compat = json.loads((root / "Contents/Resources/compatibility.json").read_text(encoding="utf-8"))
core_id = f"{sys.argv[2]}-r{sys.argv[3]}"
if source.get("coreID") != core_id or source.get("velaModifiedUpstreamSource") is not False:
    raise SystemExit("error: Core source provenance mismatch")
if source.get("license") != "GPL-3.0-only" or compat.get("coreID") != core_id:
    raise SystemExit("error: Core license/compatibility metadata mismatch")
PY
printf 'Strict Core Bundle verification passed: team=%s version=%s revision=%s\n' "${EXPECTED_TEAM}" "${EXPECTED_VERSION}" "${EXPECTED_REVISION}"
