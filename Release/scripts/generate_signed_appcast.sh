#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

MODE="dry-run"
UPDATES_DIR=""
POLICY="Release/config/appcast-policy.json"
ED_KEY_FILE=""
PRIOR_APPCAST=""
PRIOR_APPCAST_SHA256=""
CHANNEL=""
BUILD=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--dry-run|--execute] --updates-dir DIR [--policy FILE] [--ed-key-file TEMP_FILE] [--prior-appcast FILE --prior-appcast-sha256 SHA256 --channel beta|stable --build YYYYMMDDNN]\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --updates-dir) UPDATES_DIR="${2:-}"; shift 2 ;;
    --policy) POLICY="${2:-}"; shift 2 ;;
    --ed-key-file) ED_KEY_FILE="${2:-}"; shift 2 ;;
    --prior-appcast) PRIOR_APPCAST="${2:-}"; shift 2 ;;
    --prior-appcast-sha256) PRIOR_APPCAST_SHA256="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --build) BUILD="${2:-}"; shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -d "${UPDATES_DIR}" && ! -L "${UPDATES_DIR}" ]] || fail "--updates-dir must be a regular directory"
[[ -f "${POLICY}" && ! -L "${POLICY}" ]] || fail "appcast policy is missing"

if [[ "${MODE}" == "dry-run" ]]; then
  printf 'Signed-appcast dry-run passed. Production will require Sparkle 2.9.4 tools and an explicit 0600 temporary EdDSA key file.\n'
  exit 0
fi

[[ "${VELA_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_RELEASE_EXECUTE=YES and pass --execute"
[[ "${CHANNEL}" == "beta" || "${CHANNEL}" == "stable" ]] || fail "--channel must be beta or stable"
[[ "${BUILD}" =~ ^20[0-9]{8}$ ]] || fail "--build must use YYYYMMDDNN"
[[ -f "${PRIOR_APPCAST}" && ! -L "${PRIOR_APPCAST}" ]] || \
  fail "--prior-appcast must be an immutable regular non-symlink file"
PRIOR_APPCAST="$(cd "$(/usr/bin/dirname "${PRIOR_APPCAST}")" && /bin/pwd -P)/$(/usr/bin/basename "${PRIOR_APPCAST}")"
[[ "${PRIOR_APPCAST_SHA256}" =~ ^[0-9a-f]{64}$ && "${PRIOR_APPCAST_SHA256}" != "0000000000000000000000000000000000000000000000000000000000000000" ]] || \
  fail "--prior-appcast-sha256 must be a nonzero lowercase digest"
[[ -n "${SPARKLE_BIN:-}" ]] || fail "SPARKLE_BIN must point to the Sparkle 2.9.4 bin directory"
[[ -x "${SPARKLE_BIN}/generate_appcast" ]] || fail "generate_appcast is missing"
[[ -x "${SPARKLE_BIN}/sign_update" ]] || fail "sign_update is missing"
VERSION_OUTPUT="$("${SPARKLE_BIN}/generate_appcast" --version 2>&1 || true)"
printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/grep -Fq '2.9.4' || fail "expected generate_appcast 2.9.4"

[[ -f "${ED_KEY_FILE}" && ! -L "${ED_KEY_FILE}" ]] || fail "--ed-key-file must be an explicit regular temporary key file"
ED_KEY_FILE="$(cd "$(/usr/bin/dirname "${ED_KEY_FILE}")" && /bin/pwd -P)/$(/usr/bin/basename "${ED_KEY_FILE}")"
[[ -s "${ED_KEY_FILE}" ]] || fail "EdDSA key file is empty"
[[ "$(/usr/bin/stat -f '%Lp' "${ED_KEY_FILE}")" == "600" ]] || fail "EdDSA key file permissions must be 0600"
[[ "$(/usr/bin/stat -f '%u' "${ED_KEY_FILE}")" == "$(/usr/bin/id -u)" ]] || fail "EdDSA key file must be owned by the release user"
ED_KEY_PARENT="$(/usr/bin/dirname "${ED_KEY_FILE}")"
[[ "$(/usr/bin/stat -f '%Lp' "${ED_KEY_PARENT}")" == "700" ]] || fail "EdDSA key parent permissions must be 0700"
[[ "$(/usr/bin/stat -f '%z' "${ED_KEY_FILE}")" -le 16384 ]] || fail "EdDSA key file is unexpectedly large"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_sparkle_private_key.py" "${ED_KEY_FILE}"
TEMP_ED_KEY=0
for candidate_root in "${RUNNER_TEMP:-}" "${TMPDIR:-/tmp}"; do
  if [[ -n "${candidate_root}" && -d "${candidate_root}" && ! -L "${candidate_root}" ]]; then
    candidate_root="$(cd "${candidate_root}" && /bin/pwd -P)"
    case "${ED_KEY_FILE}" in
      "${candidate_root}"/*) TEMP_ED_KEY=1 ;;
    esac
  fi
done
[[ "${TEMP_ED_KEY}" == "1" ]] || fail "EdDSA key file must live under RUNNER_TEMP or TMPDIR"

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
case "${ED_KEY_FILE}" in
  "${REPO_ROOT}"/*) fail "EdDSA private key may not be stored in the source checkout" ;;
esac

APPCAST="${UPDATES_DIR}/appcast.xml"
[[ ! -e "${APPCAST}" && ! -L "${APPCAST}" ]] || fail "refusing to overwrite an existing appcast"

# The signed prior feed is a separate immutable input. Sparkle reuses it to
# preserve the channel metadata of existing items; only the exact new build is
# assigned below. Feed history contains its referenced archives and notes but
# intentionally does not contain a mutable appcast.xml.
/usr/bin/ditto "${PRIOR_APPCAST}" "${APPCAST}"
[[ -f "${APPCAST}" && ! -L "${APPCAST}" ]] || fail "prior appcast staging failed"
ACTUAL_PRIOR_SHA256="$(/usr/bin/shasum -a 256 "${APPCAST}" | /usr/bin/awk '{print $1}')"
[[ "${ACTUAL_PRIOR_SHA256}" == "${PRIOR_APPCAST_SHA256}" ]] || \
  fail "prior appcast differs from its reviewed immutable SHA-256"
# A reviewed digest identifies the expected history snapshot; it does not prove
# the embedded Sparkle signature. Verify that signature with the same ephemeral
# Ed25519 key that will sign the updated feed before trusting any old entries.
"${SPARKLE_BIN}/sign_update" --verify --ed-key-file "${ED_KEY_FILE}" "${APPCAST}"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_signed_appcast_artifacts.py" \
  "${APPCAST}" \
  --artifacts-dir "${UPDATES_DIR}" \
  --sign-update "${SPARKLE_BIN}/sign_update" \
  --ed-key-file "${ED_KEY_FILE}"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_appcast_policy.py" \
  "${APPCAST}" \
  --policy "${POLICY}" \
  --artifacts-dir "${UPDATES_DIR}"

MAXIMUM_VERSIONS="$(/usr/bin/python3 - "${POLICY}" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
counts = [value.get("retainStable"), value.get("retainBeta")]
if not all(isinstance(item, int) and item > 0 for item in counts):
    raise SystemExit("error: appcast retention counts must be positive integers")
print(max(counts))
PY
)"

# Sparkle 2.9 signs archives automatically. With SURequireSignedFeed enabled
# in the bundled App it also signs the appcast and external release notes.
GENERATE_ARGS=(
  --maximum-deltas 0
  --maximum-versions "${MAXIMUM_VERSIONS}"
  --versions "${BUILD}"
  --ed-key-file "${ED_KEY_FILE}"
)
if [[ "${CHANNEL}" == "beta" ]]; then
  GENERATE_ARGS+=(--channel beta)
fi
"${SPARKLE_BIN}/generate_appcast" "${GENERATE_ARGS[@]}" "${UPDATES_DIR}"
[[ -f "${APPCAST}" && ! -L "${APPCAST}" ]] || fail "generate_appcast did not create appcast.xml"
"${SPARKLE_BIN}/sign_update" --verify --ed-key-file "${ED_KEY_FILE}" "${APPCAST}"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_signed_appcast_artifacts.py" \
  "${APPCAST}" \
  --artifacts-dir "${UPDATES_DIR}" \
  --sign-update "${SPARKLE_BIN}/sign_update" \
  --ed-key-file "${ED_KEY_FILE}"
if /usr/bin/find "${UPDATES_DIR}" -type f -name '*.delta' -print -quit | /usr/bin/grep -q .; then
  fail "delta artifacts were generated even though V0.5 disables deltas"
fi

/usr/bin/env python3 "${SCRIPT_DIR}/verify_appcast_policy.py" \
  "${APPCAST}" \
  --policy "${POLICY}" \
  --artifacts-dir "${UPDATES_DIR}"
printf 'Generated and structurally verified signed appcast: %s\n' "${APPCAST}"
