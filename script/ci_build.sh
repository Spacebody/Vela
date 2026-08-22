#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
DERIVED_DATA="${VELA_CI_BUILD_DERIVED_DATA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/Vela-CI-Build}"
CONFIGURATIONS=(Debug Release)

if [[ "${1:-}" == "--configuration" ]]; then
  [[ "$#" == "2" ]] || {
    printf 'error: Usage: %s [--configuration Debug|Release]\n' "$0" >&2
    exit 1
  }
  case "$2" in
    Debug|Release) CONFIGURATIONS=("$2") ;;
    *)
      printf 'error: configuration must be Debug or Release\n' >&2
      exit 1
      ;;
  esac
  shift 2
fi
[[ "$#" == "0" ]] || {
  printf 'error: Usage: %s [--configuration Debug|Release]\n' "$0" >&2
  exit 1
}
if [[ -n "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR:-}" ]]; then
  [[ -d "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}" && ! -L "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}" ]] || {
    printf 'error: VELA_CI_CLONED_SOURCE_PACKAGES_DIR must be a regular directory\n' >&2
    exit 1
  }
fi

[[ "$(/usr/bin/uname -m)" == "arm64" ]] || {
  printf 'error: Vela CI build requires arm64\n' >&2
  exit 1
}
[[ -f "${ROOT}/Vela.xcodeproj/project.pbxproj" ]] || {
  printf 'error: Vela.xcodeproj is missing\n' >&2
  exit 1
}

COMMON=(
  -project "${ROOT}/Vela.xcodeproj"
  -scheme Vela
  -destination 'generic/platform=macOS'
  -derivedDataPath "${DERIVED_DATA}"
)
if [[ -n "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR:-}" ]]; then
  COMMON+=(
    -clonedSourcePackagesDirPath "${VELA_CI_CLONED_SOURCE_PACKAGES_DIR}"
  )
fi
COMMON+=(
  -disableAutomaticPackageResolution
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  ENABLE_CODE_COVERAGE=NO
)

for configuration in "${CONFIGURATIONS[@]}"; do
  printf 'Building Vela %s (unsigned CI artifact)...\n' "${configuration}"
  /usr/bin/xcodebuild "${COMMON[@]}" -configuration "${configuration}" build
done

printf 'Vela %s CI build passed. Artifacts are unsigned and are not distributable.\n' \
  "$(IFS=,; printf '%s' "${CONFIGURATIONS[*]}")"
