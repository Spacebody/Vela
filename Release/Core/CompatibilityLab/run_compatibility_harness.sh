#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && /bin/pwd -P)"
CORE_BUNDLE="${1:-}"
UPSTREAM_PAYLOAD="${2:-}"
FACTORY_EXECUTABLE="${3:-}"
OUTPUT="${4:-}"

if [[ ! -d "${CORE_BUNDLE}" || -L "${CORE_BUNDLE}" || ! -f "${UPSTREAM_PAYLOAD}" || -L "${UPSTREAM_PAYLOAD}" || ! -f "${FACTORY_EXECUTABLE}" || -L "${FACTORY_EXECUTABLE}" || -z "${OUTPUT}" ]]; then
  printf 'Usage: %s CANDIDATE_BUNDLE UNSIGNED_UPSTREAM_MIHOMO FACTORY_MIHOMO OUTPUT_REPORT [DEDICATED_EVIDENCE PERFORMANCE_REVIEW]\n' "$0" >&2
  exit 1
fi

DERIVED_DATA="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-core-compat-dd.XXXXXX")"
cleanup() { local status=$?; /bin/rm -rf "${DERIVED_DATA}"; return "${status}"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

CLANG_MODULE_CACHE_PATH="${DERIVED_DATA}/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${DERIVED_DATA}/swiftpm-cache" \
/usr/bin/xcodebuild test \
  -project "${REPO_ROOT}/Vela.xcodeproj" \
  -scheme VelaCoreCompatibility \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA}" \
  -only-testing:VelaTests/CoreCompatibilitySchemeTests \
  CODE_SIGNING_ALLOWED=NO \
  VELA_TEST_CORE_BUNDLE="${CORE_BUNDLE}"

LAB_ARGS=(
  --candidate-executable "${UPSTREAM_PAYLOAD}"
  --upstream-payload "${UPSTREAM_PAYLOAD}"
  --factory-executable "${FACTORY_EXECUTABLE}"
  --core-id v1.19.28-r1
  --output "${OUTPUT}"
  --host-class dedicated-release-lab
)
if [[ -n "${5:-}" ]]; then LAB_ARGS+=(--dedicated-host-evidence "$5"); fi
if [[ -n "${6:-}" ]]; then LAB_ARGS+=(--performance-review "$6"); fi
"${REPO_ROOT}/Release/Core/run_core_compatibility.sh" "${LAB_ARGS[@]}"
