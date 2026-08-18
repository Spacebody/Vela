#!/bin/bash
set -euo pipefail

SOURCE_ROOT="${1:-}"
APP_PATH="${2:-}"
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd -P)"
MARKERS_FILE="${SCRIPT_DIR}/release-visual-test-markers.txt"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ -d "${SOURCE_ROOT}" && ! -L "${SOURCE_ROOT}" ]] \
  || fail "Usage: $0 /path/to/source-root [/path/to/Vela.app]"
[[ -f "${MARKERS_FILE}" && ! -L "${MARKERS_FILE}" ]] \
  || fail "Release marker registry is missing or unsafe"

marker_args=()
while IFS= read -r marker || [[ -n "${marker}" ]]; do
  [[ -n "${marker}" && "${marker}" != \#* ]] || continue
  marker_args+=( -e "${marker}" )
done < "${MARKERS_FILE}"
[[ ${#marker_args[@]} -gt 0 ]] || fail "Release marker registry is empty"

exclude_args=(
  --exclude-dir=.git
  --exclude-dir=.build
  --exclude-dir=build
  --exclude-dir=Build
  --exclude-dir=DerivedData
  --exclude-dir=.swiftpm
  --exclude-dir=.cache
  --exclude-dir=xcuserdata
  --exclude-dir=Docs
  --exclude-dir=Tests
  --exclude-dir=UITests
  --exclude-dir=VelaTests
  --exclude-dir=VelaUITests
  --exclude-dir=VelaVisualHarness
  --exclude-dir=VisualRecovery
  --exclude-dir=generated
  --exclude-dir=__pycache__
  # This repository-only capture driver must carry the strict Debug launch
  # controls it passes to the dedicated visual bundle. Keep the exception
  # filename-scoped; the built app is still scanned file-by-file below.
  --exclude=capture_visual_review_direct.py
  --exclude='*.template'
)

if /usr/bin/grep -R -n -I -F \
    "${marker_args[@]}" \
    "${exclude_args[@]}" \
    -- "${SOURCE_ROOT}"; then
  fail "Release source contains visual-test controls"
fi

if [[ -n "${APP_PATH}" ]]; then
  [[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] || fail "App not found or unsafe: ${APP_PATH}"
  while IFS= read -r -d '' file; do
    if /usr/bin/strings "${file}" 2>/dev/null \
        | /usr/bin/grep -F "${marker_args[@]}" >/dev/null; then
      fail "${file} contains a visual-test control"
    fi
  done < <(/usr/bin/find "${APP_PATH}" -type f -print0)

  if /usr/bin/find "${APP_PATH}" \
      \( -iname '*target*.png' -o -iname '*diff*.png' -o -iname '*overlay*.png' \) \
      -print -quit | /usr/bin/grep -q .; then
    fail "App bundle contains visual target/diff images"
  fi
fi

printf 'Release visual-test control scan passed.\n'
