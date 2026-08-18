#!/bin/bash

set -euo pipefail

SOURCE_CORE_PATH="${SRCROOT:?}/Vendor/Mihomo/bin/mihomo"
CORE_PATH="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers/mihomo"
EXPECTED_IDENTIFIER="mihomo"

if [[ ! -f "${SOURCE_CORE_PATH}" || -L "${SOURCE_CORE_PATH}" ]]; then
  echo "error: verified Mihomo source is missing or is a symbolic link: ${SOURCE_CORE_PATH}" >&2
  exit 1
fi

if [[ -e "${CORE_PATH}" && ( ! -f "${CORE_PATH}" || -L "${CORE_PATH}" ) ]]; then
  echo "error: embedded Mihomo output is not a regular file: ${CORE_PATH}" >&2
  exit 1
fi

# Xcode's CodeSignOnCopy derives an unstable identifier for a raw Mach-O.
# Re-sign the embedded Factory Core explicitly with the same identity as the
# outer App. Unsigned test builds use a deterministic ad-hoc signature so the
# production preflight exercises the same identifier contract.
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" || -z "${SIGNING_IDENTITY}" ]]; then
  SIGNING_IDENTITY="-"
fi

SIGN_ARGUMENTS=(
  --force
  --sign "${SIGNING_IDENTITY}"
  --identifier "${EXPECTED_IDENTIFIER}"
)

if [[ "${SIGNING_IDENTITY}" != "-" && "${CONFIGURATION:-Debug}" == "Release" ]]; then
  SIGN_ARGUMENTS+=(--options runtime --timestamp)
else
  SIGN_ARGUMENTS+=(--timestamp=none)
fi

# This phase is the sole producer of the embedded Core. Keeping copy and sign
# together avoids a mutable-output cycle between a Copy Files phase, codesign,
# and the App's final CodeSign task. codesign performs its atomic replacement
# beside a private staging file under TARGET_TEMP_DIR, where Xcode's User Script
# Sandbox permits scratch writes.
STAGED_CORE="$(/usr/bin/mktemp "${TARGET_TEMP_DIR:?}/vela-mihomo-sign.XXXXXX")"
cleanup() {
  /bin/rm -f "${STAGED_CORE}"
}
trap cleanup EXIT

/bin/cp -p "${SOURCE_CORE_PATH}" "${STAGED_CORE}"
if /usr/bin/codesign --display "${STAGED_CORE}" >/dev/null 2>&1; then
  /usr/bin/codesign --remove-signature "${STAGED_CORE}"
fi
/usr/bin/codesign "${SIGN_ARGUMENTS[@]}" "${STAGED_CORE}"

STAGED_IDENTIFIER=$(
  /usr/bin/codesign --display --verbose=4 "${STAGED_CORE}" 2>&1 \
    | /usr/bin/sed -n 's/^Identifier=//p'
)
if [[ "${STAGED_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]]; then
  echo "error: staged Mihomo signing identifier is '${STAGED_IDENTIFIER}', expected '${EXPECTED_IDENTIFIER}'" >&2
  exit 1
fi

/bin/mkdir -p "$(/usr/bin/dirname "${CORE_PATH}")"
/usr/bin/install -m 0755 "${STAGED_CORE}" "${CORE_PATH}"
/usr/bin/codesign --verify --strict "${CORE_PATH}"

ACTUAL_IDENTIFIER=$(
  /usr/bin/codesign --display --verbose=4 "${CORE_PATH}" 2>&1 \
    | /usr/bin/sed -n 's/^Identifier=//p'
)
if [[ "${ACTUAL_IDENTIFIER}" != "${EXPECTED_IDENTIFIER}" ]]; then
  echo "error: embedded Mihomo signing identifier is '${ACTUAL_IDENTIFIER}', expected '${EXPECTED_IDENTIFIER}'" >&2
  exit 1
fi
