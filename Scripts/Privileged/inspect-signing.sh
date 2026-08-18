#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

APP_PATH="${1:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == "1" ]] || fail "Usage: $0 /path/to/Vela.app"
[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] || fail "App bundle not found or is a symlink: ${APP_PATH}"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[[ -f "${INFO_PLIST}" && ! -L "${INFO_PLIST}" ]] || fail "Missing regular Info.plist"
APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}")"

ITEMS="${APP_PATH}
${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE_NAME}
${APP_PATH}/Contents/Library/LaunchServices/VelaHelper
${APP_PATH}/Contents/Helpers/mihomo"

printf 'Read-only signing inspection for %s\n' "${APP_PATH}"
while IFS= read -r item; do
  [[ -n "${item}" ]] || continue
  printf '\n=== %s ===\n' "${item}"
  if [[ ! -e "${item}" && ! -L "${item}" ]]; then
    printf 'missing\n'
    continue
  fi
  if [[ -f "${item}" ]]; then
    printf 'architectures: %s\n' "$(/usr/bin/lipo -archs "${item}" 2>/dev/null || printf 'not a Mach-O')"
  fi
  if /usr/bin/codesign --verify --strict --verbose=4 "${item}" 2>&1; then
    printf 'strict verification: passed\n'
  else
    printf 'strict verification: failed\n'
  fi
  /usr/bin/codesign -dvvv "${item}" 2>&1 || true
  /usr/bin/codesign -d -r- "${item}" 2>&1 || true
  /usr/bin/codesign -d --entitlements :- "${item}" 2>/dev/null || printf 'entitlements: unavailable\n'
done <<< "${ITEMS}"

printf '\nInspection finished. Use verify-privileged-bundle.sh for a pass/fail gate.\n'
