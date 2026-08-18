#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
PACK_ROOT="${ROOT}/Docs/Vela-Visual-Recovery-v2-Codex-Pack"
VISUAL_ROOT="${ROOT}/VisualRecovery"
VISUAL_TEST_BUNDLE_IDENTIFIER="dev.yilin.Vela.VisualTests"
MODE=""
CAPTURE_CURRENT=0
WORK_ROOT=""
TEMP_PARENT_CANONICAL=""
READINESS_BLOCKERS=()

usage() {
  cat >&2 <<EOF
Usage: $0 audit [--capture-current]
       $0 release-readiness [--capture-current]

audit verifies the complete visual-recovery infrastructure but may exit 0 with
targetApprovalPending. release-readiness fails unless every release gate and
approved-target review gate is ready. UI capture is opt-in and requires an
unlocked console session.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

add_readiness_blocker() {
  READINESS_BLOCKERS+=("$1")
  printf 'release-readiness blocker: %s\n' "$1" >&2
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "${WORK_ROOT}" ]]; then
    case "${WORK_ROOT}" in
      "${TEMP_PARENT_CANONICAL}"/VelaVisualRecoveryCI.*)
        if [[ -d "${WORK_ROOT}" && ! -L "${WORK_ROOT}" ]]; then
          /bin/rm -rf "${WORK_ROOT}"
        fi
        ;;
      *)
        printf 'error: refusing to remove unexpected work root: %s\n' \
          "${WORK_ROOT}" >&2
        status=1
        ;;
    esac
  fi
  exit "${status}"
}

case "${1:-}" in
  audit|--audit)
    MODE="audit"
    ;;
  release-readiness|--release-readiness)
    MODE="release-readiness"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
shift

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --capture-current)
      CAPTURE_CURRENT=1
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "visual recovery CI requires arm64"
[[ -d "${PACK_ROOT}" && ! -L "${PACK_ROOT}" ]] || fail "visual recovery pack is missing or unsafe"
[[ -d "${VISUAL_ROOT}" && ! -L "${VISUAL_ROOT}" ]] || fail "VisualRecovery is missing or unsafe"
[[ -f "${ROOT}/Vela.xcodeproj/project.pbxproj" ]] || fail "Vela.xcodeproj is missing"

LEGACY_UI_TEST_MARKER='--vela''-ui-testing'
if /usr/bin/grep -R -n -I -F -- "${LEGACY_UI_TEST_MARKER}" "${ROOT}/VelaUITests"; then
  fail "legacy UI-test launch controls remain; tests could fall through to production dependencies"
fi

PYTHON="${VELA_VISUAL_PYTHON:-$(command -v python3 || true)}"
[[ -n "${PYTHON}" && -x "${PYTHON}" ]] || fail "python3 is required"
PILLOW_VERSION="$("${PYTHON}" -c 'import PIL; print(PIL.__version__)' 2>/dev/null || true)"
[[ "${PILLOW_VERSION}" == "12.2.0" ]] || \
  fail "Pillow 12.2.0 is required (found ${PILLOW_VERSION:-none})"

TEMP_PARENT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[[ -d "${TEMP_PARENT}" ]] || fail "temporary parent does not exist: ${TEMP_PARENT}"
TEMP_PARENT_CANONICAL="$(cd "${TEMP_PARENT}" && /bin/pwd -P)"
umask 077
WORK_ROOT="$(/usr/bin/mktemp -d "${TEMP_PARENT_CANONICAL}/VelaVisualRecoveryCI.XXXXXX")"
WORK_ROOT="$(cd "${WORK_ROOT}" && /bin/pwd -P)"
/bin/chmod 0700 "${WORK_ROOT}"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -n "$(/usr/bin/find "${PACK_ROOT}" -type l -print -quit)" ]]; then
  fail "visual recovery pack contains a symlink"
fi
PACK_COPY="${WORK_ROOT}/pack"
/usr/bin/ditto "${PACK_ROOT}" "${PACK_COPY}"
VELA_PACK_VALIDATION_ISOLATED=1 PYTHONDONTWRITEBYTECODE=1 \
  "${PYTHON}" "${PACK_COPY}/scripts/validate_visual_recovery_pack.py"

if [[ -n "$(/usr/bin/find "${VISUAL_ROOT}" -type l -print -quit)" ]]; then
  fail "VisualRecovery contains a symlink"
fi
TEST_REPOSITORY_ROOT="${WORK_ROOT}/test-repository"
/bin/mkdir -p "${TEST_REPOSITORY_ROOT}/VisualRecovery"
/usr/bin/ditto \
  "${VISUAL_ROOT}/Fixtures" \
  "${TEST_REPOSITORY_ROOT}/VisualRecovery/Fixtures"
/usr/bin/ditto \
  "${VISUAL_ROOT}/Contracts" \
  "${TEST_REPOSITORY_ROOT}/VisualRecovery/Contracts"
JSON_FILES=()
while IFS= read -r -d '' path; do
  [[ -f "${path}" && ! -L "${path}" ]] || fail "unsafe JSON document: ${path}"
  JSON_FILES+=("${path}")
done < <(/usr/bin/find "${VISUAL_ROOT}" -type f -name '*.json' -print0)
[[ "${#JSON_FILES[@]}" -gt 0 ]] || fail "VisualRecovery contains no JSON documents"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON}" \
  "${PACK_ROOT}/scripts/validate_json_documents.py" "${JSON_FILES[@]}"

CONTRACTS=()
while IFS= read -r -d '' path; do
  CONTRACTS+=("${path}")
done < <(/usr/bin/find "${VISUAL_ROOT}/Contracts" -maxdepth 1 -type f -name '*.json' -print0)
[[ "${#CONTRACTS[@]}" -gt 0 ]] || fail "no visual page contracts were found"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON}" \
  "${PACK_ROOT}/scripts/validate_json_schema.py" \
  "${PACK_ROOT}/schemas/page-contract.schema.json" "${CONTRACTS[@]}"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON}" \
  "${PACK_ROOT}/scripts/validate_json_schema.py" \
  "${PACK_ROOT}/schemas/fixture-registry.schema.json" \
  "${VISUAL_ROOT}/Fixtures/fixture-registry.json"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON}" -m unittest discover \
  -s "${ROOT}/script/tests" \
  -p 'test_*.py'
PYTHONDONTWRITEBYTECODE=1 "${PYTHON}" \
  "${ROOT}/script/validate_visual_recovery_contracts.py" \
  --root "${ROOT}"
PYTHONDONTWRITEBYTECODE=1 "${PYTHON}" \
  "${PACK_ROOT}/scripts/validate_target_status.py" \
  "${VISUAL_ROOT}/Targets/target-status.json" \
  "${VISUAL_ROOT}/Targets/visual-baseline-manifest.json" \
  --root "${ROOT}"

TARGET_STATUS="$("${PYTHON}" -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["status"])' \
  "${VISUAL_ROOT}/Targets/target-status.json")"
APPROVED_TARGET_COUNT="$("${PYTHON}" -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["approvedTargetCount"])' \
  "${VISUAL_ROOT}/Targets/target-status.json")"
[[ "${APPROVED_TARGET_COUNT}" =~ ^[0-9]+$ ]] || fail "approvedTargetCount is not an integer"
printf 'targetStatus=%s\napprovedTargetCount=%s\n' \
  "${TARGET_STATUS}" "${APPROVED_TARGET_COUNT}"

BUG_VALIDATOR=(
  "${PYTHON}"
  "${PACK_ROOT}/scripts/validate_bug_registry.py"
  "${VISUAL_ROOT}/Audit/bugs.json"
)
if [[ "${MODE}" == "release-readiness" ]]; then
  if ! PYTHONDONTWRITEBYTECODE=1 "${BUG_VALIDATOR[@]}" --require-clear P0,P1; then
    add_readiness_blocker "unresolved P0/P1 visual bugs"
  fi
else
  PYTHONDONTWRITEBYTECODE=1 "${BUG_VALIDATOR[@]}"
fi

if [[ "${TARGET_STATUS}" == "targetApprovalPending" ]]; then
  add_readiness_blocker "targetApprovalPending"
fi
if [[ "${APPROVED_TARGET_COUNT}" == "0" ]]; then
  printf 'targetApprovalPending: no approved pixel targets; matrix/review acceptance is intentionally skipped.\n'
else
  BASELINE_MANIFEST="${VISUAL_ROOT}/Targets/visual-baseline-manifest.json"
  CURRENT_ROOT="${VISUAL_ROOT}/Current"
  MATRIX_ROOT="${WORK_ROOT}/matrix"
  if ! PYTHONDONTWRITEBYTECODE=1 "${PYTHON}" \
    "${PACK_ROOT}/scripts/validate_visual_baseline.py" \
    "${BASELINE_MANIFEST}" --root "${ROOT}" --require-approved; then
    add_readiness_blocker "visual baseline manifest is not fully approved"
  fi
  if [[ ! -d "${CURRENT_ROOT}" || -L "${CURRENT_ROOT}" ]]; then
    add_readiness_blocker "current visual capture root is missing or unsafe"
  else
    MATRIX_COMMAND=(
      "${PYTHON}"
      "${PACK_ROOT}/scripts/run_visual_matrix.py"
      "${BASELINE_MANIFEST}"
      --root "${ROOT}"
      --current-root "${CURRENT_ROOT}"
      --output-root "${MATRIX_ROOT}"
    )
    if [[ "${MODE}" == "release-readiness" ]]; then
      MATRIX_COMMAND+=(--require-approved)
    fi
    if ! PYTHONDONTWRITEBYTECODE=1 "${MATRIX_COMMAND[@]}"; then
      add_readiness_blocker "approved-target visual matrix failed"
    fi
    if [[ -f "${MATRIX_ROOT}/matrix-summary.json" ]]; then
      REVIEWS=()
      while IFS= read -r -d '' path; do
        [[ ! -L "${path}" ]] || fail "visual review cannot be a symlink: ${path}"
        REVIEWS+=("${path}")
      done < <(/usr/bin/find "${VISUAL_ROOT}/Reviews" -maxdepth 1 -type f -name '*.json' -print0)
      SUMMARY_COMMAND=(
        "${PYTHON}"
        "${PACK_ROOT}/scripts/generate_visual_summary.py"
        --bugs "${VISUAL_ROOT}/Audit/bugs.json"
        --matrix "${MATRIX_ROOT}/matrix-summary.json"
      )
      if [[ "${#REVIEWS[@]}" -gt 0 ]]; then
        SUMMARY_COMMAND+=(--reviews "${REVIEWS[@]}")
      fi
      SUMMARY_COMMAND+=(
        --output-json "${WORK_ROOT}/readiness.json"
        --output-md "${WORK_ROOT}/readiness.md"
      )
      PYTHONDONTWRITEBYTECODE=1 "${SUMMARY_COMMAND[@]}"
      SUMMARY_READY="$("${PYTHON}" -c \
        'import json,sys; print("1" if json.load(open(sys.argv[1], encoding="utf-8"))["ready"] else "0")' \
        "${WORK_ROOT}/readiness.json")"
      if [[ "${SUMMARY_READY}" != "1" ]]; then
        add_readiness_blocker "visual matrix and human review summary is not ready"
      fi
    else
      add_readiness_blocker "visual matrix produced no summary"
    fi
  fi
fi

DERIVED_DATA="${WORK_ROOT}/DerivedData"
XCODE_COMMON=(
  -project "${ROOT}/Vela.xcodeproj"
  -scheme Vela
  -derivedDataPath "${DERIVED_DATA}"
)
if [[ -n "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR:-}" ]]; then
  [[ -d "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}" && ! -L "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}" ]] || \
    fail "VELA_CI_CLONED_SOURCE_PACKAGES_DIR must be a regular directory"
  XCODE_COMMON+=( -clonedSourcePackagesDirPath "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}" )
fi
XCODE_COMMON+=(
  -disableAutomaticPackageResolution
  ARCHS=arm64
  ENABLE_CODE_COVERAGE=NO
)

FOCUSED_TESTS=(
  -only-testing:VelaTests/VisualUITestConfigurationTests
  -only-testing:VelaTests/VisualFixtureDeterminismTests
  -only-testing:VelaTests/VisualRuntimeIsolationTests
  -only-testing:VelaTests/VelaDesignSystemContractTests
  -only-testing:VelaTests/VelaPreviewFixtureTests
  -only-testing:VelaTests/AppShellTests
)
# The ad-hoc signed macOS unit-test host can block indefinitely when it opens
# repository fixtures under Documents and macOS routes the request through its
# protected-folder access path. The source JSON is validated above; run the
# focused tests against the exact private staging copy instead.
VELA_TEST_REPOSITORY_ROOT="${TEST_REPOSITORY_ROOT}" /usr/bin/xcodebuild \
  "${XCODE_COMMON[@]}" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  "${FOCUSED_TESTS[@]}" \
  test

if [[ "${CAPTURE_CURRENT}" == "1" ]]; then
  CONSOLE_STATE="$(/usr/sbin/ioreg -n Root -d1)"
  CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console)"
  [[ -n "${CONSOLE_USER}" && "${CONSOLE_USER}" != "root" && "${CONSOLE_USER}" != "loginwindow" ]] || \
    fail "UI capture requires a logged-in console user"
  [[ "${CONSOLE_STATE}" == *'"kCGSSessionOnConsoleKey"=Yes'* ]] || \
    fail "UI capture requires an on-console session"
  if [[ "${CONSOLE_STATE}" == *'"CGSSessionScreenIsLocked"=Yes'* ]]; then
    fail "UI capture requires an unlocked console session"
  fi
  CAPTURE_RESULT="${VELA_VISUAL_CAPTURE_RESULT_BUNDLE:-${TEMP_PARENT_CANONICAL}/VelaVisualRecoveryCurrent.$$.xcresult}"
  [[ "${CAPTURE_RESULT}" == /* && ! -e "${CAPTURE_RESULT}" && ! -L "${CAPTURE_RESULT}" ]] || \
    fail "capture result path must be an absent absolute path: ${CAPTURE_RESULT}"
  VELA_TEST_REPOSITORY_ROOT="${TEST_REPOSITORY_ROOT}" /usr/bin/xcodebuild \
    "${XCODE_COMMON[@]}" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    -resultBundlePath "${CAPTURE_RESULT}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    VELA_APP_BUNDLE_IDENTIFIER="${VISUAL_TEST_BUNDLE_IDENTIFIER}" \
    VELA_VISUAL_TEST_BUILD=YES \
    -only-testing:VelaUITests/VelaVisualSystemUITests \
    test
  printf 'currentCaptureResult=%s\n' "${CAPTURE_RESULT}"
else
  printf 'Current UI capture skipped; pass --capture-current on an unlocked host to run it.\n'
fi

/usr/bin/xcodebuild \
  "${XCODE_COMMON[@]}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_BUNDLE="${DERIVED_DATA}/Build/Products/Release/Vela.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/Vela"
[[ -d "${APP_BUNDLE}" && ! -L "${APP_BUNDLE}" ]] || fail "Release Vela.app was not built"
[[ -f "${APP_BINARY}" && -x "${APP_BINARY}" && ! -L "${APP_BINARY}" ]] || \
  fail "Release Vela executable is missing or unsafe"
ARCHITECTURES="$(/usr/bin/lipo -archs "${APP_BINARY}")"
[[ "${ARCHITECTURES}" == "arm64" ]] || fail "Release Vela architecture is ${ARCHITECTURES}, expected arm64"
"${PACK_ROOT}/scripts/scan_release_visual_test_controls.sh" \
  "${ROOT}" "${APP_BUNDLE}"

printf '\nvisualRecoveryMode=%s\nauditInfrastructure=passed\ntargetStatus=%s\n' \
  "${MODE}" "${TARGET_STATUS}"
if [[ "${#READINESS_BLOCKERS[@]}" -gt 0 ]]; then
  printf 'releaseReadiness=false\n'
  for blocker in "${READINESS_BLOCKERS[@]}"; do
    printf 'blocker=%s\n' "${blocker}"
  done
else
  printf 'releaseReadiness=true\n'
fi

if [[ "${MODE}" == "release-readiness" && "${#READINESS_BLOCKERS[@]}" -gt 0 ]]; then
  printf 'error: release-readiness failed with %s blocker(s)\n' \
    "${#READINESS_BLOCKERS[@]}" >&2
  exit 3
fi

if [[ "${MODE}" == "audit" && "${#READINESS_BLOCKERS[@]}" -gt 0 ]]; then
  printf 'Audit mode passed infrastructure checks without claiming release readiness.\n'
fi
