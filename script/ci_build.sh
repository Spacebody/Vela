#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
DERIVED_DATA="${VELA_CI_BUILD_DERIVED_DATA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/Vela-CI-Build}"
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

for configuration in Debug Release; do
  printf 'Building Vela %s (unsigned CI artifact)...\n' "${configuration}"
  /usr/bin/xcodebuild "${COMMON[@]}" -configuration "${configuration}" build
done

printf 'Vela Debug and Release CI builds passed. Artifacts are unsigned and are not distributable.\n'
