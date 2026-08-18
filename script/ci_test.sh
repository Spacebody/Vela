#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
VISUAL_TEST_BUNDLE_IDENTIFIER="dev.yilin.Vela.VisualTests"
STATIC_ONLY=0
if [[ "${1:-}" == "--static-only" ]]; then
  STATIC_ONLY=1
  shift
fi
[[ "$#" == "0" ]] || {
  printf 'error: Usage: %s [--static-only]\n' "$0" >&2
  exit 1
}

"${ROOT}/Scripts/Mihomo/test-static-integration.sh"
"${ROOT}/Scripts/Privileged/test-static-integration.sh"
"${ROOT}/Release/scripts/validate_release_tooling.sh"
"${ROOT}/ReleaseCandidate/scripts/validate_release_candidate_tooling.sh"
/usr/bin/python3 -m unittest discover \
  -s "${ROOT}/ReleaseCandidate/tests" \
  -p 'test_*.py'

if [[ "${STATIC_ONLY}" == "1" ]]; then
  printf 'Vela static CI gates passed. Xcode/Swift tests were intentionally skipped.\n'
  exit 0
fi

[[ "$(/usr/bin/uname -m)" == "arm64" ]] || {
  printf 'error: Vela CI tests require arm64\n' >&2
  exit 1
}

PACKAGE_SCRATCH="${VELA_CI_PACKAGE_SCRATCH:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/VelaIPC-CI}"
MODULE_CACHE="${VELA_CI_MODULE_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/Vela-CI-ModuleCache}"
/bin/mkdir -p "${MODULE_CACHE}/swiftpm" "${MODULE_CACHE}/clang"
SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}/swiftpm" \
CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}/clang" \
/usr/bin/swift test \
  --package-path "${ROOT}/VelaIPC" \
  --scratch-path "${PACKAGE_SCRATCH}"

DERIVED_DATA="${VELA_CI_TEST_DERIVED_DATA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/Vela-CI-Tests}"
TEST_ASSET_ROOT="${DERIVED_DATA%/}/Vela-CI-TestAssets"
/bin/rm -rf "${TEST_ASSET_ROOT}"
/bin/mkdir -p "${TEST_ASSET_ROOT}"
/bin/chmod 700 "${TEST_ASSET_ROOT}"
cleanup_test_assets() {
  local status=$?
  trap - EXIT
  /usr/bin/pkill -TERM -f "${TEST_ASSET_ROOT}/VelaTests/Fixtures/Subscriptions/scripts/local_subscription_server.py" >/dev/null 2>&1 || :
  /bin/rm -rf "${TEST_ASSET_ROOT}"
  exit "${status}"
}
trap cleanup_test_assets EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

stage_read_only_fixture_tree() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local source_count=0
  local staged_count=0
  local source_path relative staged_path mode

  [[ -d "${source}" && ! -L "${source}" ]] || \
    fail "${label} source must be a regular non-symlink directory"
  /bin/mkdir -p "${destination}"
  while IFS= read -r -d '' source_path; do
    [[ ! -L "${source_path}" ]] || fail "${label} source contains a symlink: ${source_path}"
    [[ -d "${source_path}" || -f "${source_path}" ]] || \
      fail "${label} source contains a special file: ${source_path}"
    relative="${source_path#"${source}/"}"
    staged_path="${destination}/${relative}"

    # Finder metadata is not a repository fixture and may carry attributes that
    # cannot be reproduced in a hermetic test root. Ignore only this regular
    # metadata file; every source/resource byte used by tests is inventoried.
    if [[ "${source_path}" == */.DS_Store ]]; then
      [[ -f "${source_path}" ]] || fail "${label} has an unsafe .DS_Store entry"
      continue
    fi

    if [[ -d "${source_path}" ]]; then
      /bin/mkdir -p "${staged_path}"
      continue
    fi

    /bin/mkdir -p "${staged_path%/*}"
    /bin/cp -X "${source_path}" "${staged_path}"
    [[ -f "${staged_path}" && ! -L "${staged_path}" ]] || \
      fail "${label} staged file is missing or unsafe: ${relative}"
    /usr/bin/cmp -s "${source_path}" "${staged_path}" || \
      fail "${label} staged bytes differ from source: ${relative}"
    source_count=$((source_count + 1))
  done < <(/usr/bin/find "${source}" -mindepth 1 -print0)
  [[ "${source_count}" -gt 0 ]] || fail "${label} source is empty"

  while IFS= read -r -d '' staged_path; do
    [[ ! -L "${staged_path}" ]] || fail "${label} staged tree contains a symlink: ${staged_path}"
    [[ -d "${staged_path}" || -f "${staged_path}" ]] || \
      fail "${label} staged tree contains a special file: ${staged_path}"
    if [[ -f "${staged_path}" ]]; then
      /bin/chmod 444 "${staged_path}"
      mode="$(/usr/bin/stat -f '%Lp' "${staged_path}")"
      [[ "${mode}" == "444" ]] || fail "${label} fixture is not read-only: ${staged_path}"
      staged_count=$((staged_count + 1))
    fi
  done < <(/usr/bin/find "${destination}" -mindepth 1 -print0)
  [[ "${staged_count}" == "${source_count}" ]] || \
    fail "${label} staged inventory is incomplete (${staged_count}/${source_count})"
}

/bin/mkdir -p \
  "${TEST_ASSET_ROOT}/Contracts/v1" \
  "${TEST_ASSET_ROOT}/Hardening/config" \
  "${TEST_ASSET_ROOT}/ReleaseCandidate/config" \
  "${TEST_ASSET_ROOT}/Vendor/Mihomo/bin"
stage_read_only_fixture_tree \
  "${ROOT}/VelaTests/Fixtures" \
  "${TEST_ASSET_ROOT}/VelaTests/Fixtures" \
  "Vela test fixtures"
/bin/cp -p \
  "${ROOT}/Contracts/v1/hashes.json" \
  "${TEST_ASSET_ROOT}/Contracts/v1/hashes.json"
/bin/cp -p \
  "${ROOT}/Contracts/v1/public-contract-freeze.json" \
  "${TEST_ASSET_ROOT}/Contracts/v1/public-contract-freeze.json"
/bin/cp -p \
  "${ROOT}/Hardening/config/architecture-freeze.json" \
  "${TEST_ASSET_ROOT}/Hardening/config/architecture-freeze.json"
/bin/cp -p \
  "${ROOT}/ReleaseCandidate/config/known-limitations.json" \
  "${TEST_ASSET_ROOT}/ReleaseCandidate/config/known-limitations.json"
stage_read_only_fixture_tree \
  "${ROOT}/Vela" \
  "${TEST_ASSET_ROOT}/Vela" \
  "Vela source and resources"
stage_read_only_fixture_tree \
  "${ROOT}/VelaVisualHarness" \
  "${TEST_ASSET_ROOT}/VelaVisualHarness" \
  "Vela visual harness source"
stage_read_only_fixture_tree \
  "${ROOT}/VisualRecovery/Contracts" \
  "${TEST_ASSET_ROOT}/VisualRecovery/Contracts" \
  "Visual Recovery contracts"
stage_read_only_fixture_tree \
  "${ROOT}/VisualRecovery/Fixtures" \
  "${TEST_ASSET_ROOT}/VisualRecovery/Fixtures" \
  "Visual Recovery fixture registry"
/bin/chmod 444 \
  "${TEST_ASSET_ROOT}/Contracts/v1/hashes.json" \
  "${TEST_ASSET_ROOT}/Contracts/v1/public-contract-freeze.json" \
  "${TEST_ASSET_ROOT}/Hardening/config/architecture-freeze.json" \
  "${TEST_ASSET_ROOT}/ReleaseCandidate/config/known-limitations.json"
/bin/cp -p "${ROOT}/Vendor/Mihomo/bin/mihomo" "${TEST_ASSET_ROOT}/Vendor/Mihomo/bin/mihomo"
export VELA_TEST_REPOSITORY_ROOT="${TEST_ASSET_ROOT}"

if [[ -n "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR:-}" ]]; then
  [[ -d "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}" && ! -L "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}" ]] || {
    printf 'error: VELA_CI_CLONED_SOURCE_PACKAGES_DIR must be a regular directory\n' >&2
    exit 1
  }
fi
COMMON=(
  -project "${ROOT}/Vela.xcodeproj"
  -scheme Vela
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "${DERIVED_DATA}"
)
if [[ -n "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR:-}" ]]; then
  COMMON+=(
    -clonedSourcePackagesDirPath "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}"
  )
fi
COMMON+=(
  -disableAutomaticPackageResolution
  # Swift Testing otherwise runs every suite concurrently in one host process.
  # That makes wall-clock performance gates compete for CPU and can starve
  # MainActor scheduling tests until their one-minute safety limit expires.
  -parallel-testing-enabled NO
  ARCHS=arm64
  ENABLE_CODE_COVERAGE=NO
  VELA_TEST_REPOSITORY_ROOT="${TEST_ASSET_ROOT}"
)

/usr/bin/xcodebuild "${COMMON[@]}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  -skip-testing:VelaUITests \
  -skip-testing:VelaPrivilegedIntegrationTests \
  test

if [[ "${VELA_CI_RUN_UI_TESTS:-0}" == "1" ]]; then
  /usr/bin/xcodebuild "${COMMON[@]}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    VELA_APP_BUNDLE_IDENTIFIER="${VISUAL_TEST_BUNDLE_IDENTIFIER}" \
    VELA_VISUAL_TEST_BUILD=YES \
    -only-testing:VelaUITests \
    test
else
  printf 'UI tests skipped; set VELA_CI_RUN_UI_TESTS=1 on an unlocked CI session.\n'
fi

printf 'Vela non-privileged CI tests passed. Real SMAppService/TUN mutation remains a protected Mac gate.\n'
