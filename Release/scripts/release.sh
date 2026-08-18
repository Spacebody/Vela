#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"

MODE="dry-run"
PHASE=""
CONFIG="${REPO_ROOT}/Release/config/release.json"
CORE_RELEASE_CONFIG="${REPO_ROOT}/Release/Core/config/core-release.json"
DOCUMENTATION_CONFIG="${REPO_ROOT}/Release/config/documentation.json"
VERSION=""
BUILD=""
CHANNEL=""
TAG=""
PRERELEASE_LABEL=""
NOTES=""
FEED_HISTORY=""
PRIOR_APPCAST=""
PRIOR_APPCAST_SHA256=""
MIGRATION_EVIDENCE=""
EVIDENCE_ROOT=""
AUDIT_EVIDENCE=""
AUDIT_SUMMARY_EVIDENCE=""
GO_NO_GO_EVIDENCE=""
PUBLISHED_BUILDS=""
SUPPORT_MATRIX=""
INSTALLATION_MATRIX=""
CANDIDATE_STAGE_PATH=""
PROMOTION_OUTPUT_ROOT=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  release.sh --dry-run [--config FILE]
  release.sh --execute --stage-candidate --version 1.0.0 --build YYYYMMDDNN \
    --channel stable|beta --tag TAG [--prerelease-label LABEL] \
    --notes FILE --feed-history DIR --prior-appcast FILE \
    --prior-appcast-sha256 SHA256 --migration FILE \
    --evidence-dir DIR \
    --audit FILE --go-no-go FILE --published-builds FILE --support-matrix FILE \
    --installation-matrix FILE --candidate-stage PATH \
    [--config FILE]
  release.sh --execute --promote-candidate --version 1.0.0 --build YYYYMMDDNN \
    --channel stable|beta --tag TAG [--prerelease-label LABEL] \
    --migration FILE --evidence-dir DIR --audit FILE --audit-summary FILE \
    --go-no-go FILE --published-builds FILE --support-matrix FILE \
    --installation-matrix FILE --candidate-stage PATH \
    --promotion-output-root DIR \
    [--config FILE]

Candidate staging builds the complete signed/notarized DMG and private signed
Sparkle set, then stops No-Go for exact-byte soak/matrix testing. Promotion
reuses that immutable stage; it never rebuilds or resigns candidate bytes.
USAGE
}

SEEN_OPTIONS=$'\n'

claim_option() {
  local option="$1"
  case "${SEEN_OPTIONS}" in
    *$'\n'"${option}"$'\n'*) fail "option may be specified only once: ${option}" ;;
  esac
  SEEN_OPTIONS="${SEEN_OPTIONS}${option}"$'\n'
}

require_option_value() {
  local option="$1"
  [[ "$#" -ge 2 ]] || fail "option requires a value: ${option}"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      claim_option "--mode"
      MODE="dry-run"
      shift
      ;;
    --execute)
      claim_option "--mode"
      MODE="execute"
      shift
      ;;
    --stage-candidate)
      claim_option "--phase"
      PHASE="candidate-stage"
      shift
      ;;
    --promote-candidate)
      claim_option "--phase"
      PHASE="promotion"
      shift
      ;;
    --config)
      require_option_value "$@"; claim_option "$1"; CONFIG="$2"; shift 2 ;;
    --version)
      require_option_value "$@"; claim_option "$1"; VERSION="$2"; shift 2 ;;
    --build)
      require_option_value "$@"; claim_option "$1"; BUILD="$2"; shift 2 ;;
    --channel)
      require_option_value "$@"; claim_option "$1"; CHANNEL="$2"; shift 2 ;;
    --tag)
      require_option_value "$@"; claim_option "$1"; TAG="$2"; shift 2 ;;
    --prerelease-label)
      require_option_value "$@"; claim_option "$1"; PRERELEASE_LABEL="$2"; shift 2 ;;
    --notes)
      require_option_value "$@"; claim_option "$1"; NOTES="$2"; shift 2 ;;
    --feed-history)
      require_option_value "$@"; claim_option "$1"; FEED_HISTORY="$2"; shift 2 ;;
    --prior-appcast)
      require_option_value "$@"; claim_option "$1"; PRIOR_APPCAST="$2"; shift 2 ;;
    --prior-appcast-sha256)
      require_option_value "$@"; claim_option "$1"; PRIOR_APPCAST_SHA256="$2"; shift 2 ;;
    --migration)
      require_option_value "$@"; claim_option "$1"; MIGRATION_EVIDENCE="$2"; shift 2 ;;
    --evidence-dir)
      require_option_value "$@"; claim_option "$1"; EVIDENCE_ROOT="$2"; shift 2 ;;
    --audit)
      require_option_value "$@"; claim_option "$1"; AUDIT_EVIDENCE="$2"; shift 2 ;;
    --audit-summary)
      require_option_value "$@"; claim_option "$1"; AUDIT_SUMMARY_EVIDENCE="$2"; shift 2 ;;
    --go-no-go)
      require_option_value "$@"; claim_option "$1"; GO_NO_GO_EVIDENCE="$2"; shift 2 ;;
    --published-builds)
      require_option_value "$@"; claim_option "$1"; PUBLISHED_BUILDS="$2"; shift 2 ;;
    --support-matrix)
      require_option_value "$@"; claim_option "$1"; SUPPORT_MATRIX="$2"; shift 2 ;;
    --installation-matrix)
      require_option_value "$@"; claim_option "$1"; INSTALLATION_MATRIX="$2"; shift 2 ;;
    --candidate-stage)
      require_option_value "$@"; claim_option "$1"; CANDIDATE_STAGE_PATH="$2"; shift 2 ;;
    --promotion-output-root)
      require_option_value "$@"; claim_option "$1"; PROMOTION_OUTPUT_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -f "${CONFIG}" && ! -L "${CONFIG}" ]] || fail "release config is missing or unsafe"
CONFIG="$(cd "$(/usr/bin/dirname "${CONFIG}")" && /bin/pwd -P)/$(/usr/bin/basename "${CONFIG}")"

json_value() {
  /usr/bin/python3 - "${CONFIG}" "$1" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
if not isinstance(value, (str, int, float)):
    raise SystemExit(f"configured value is not scalar: {sys.argv[2]}")
print(value)
PY
}

validate_ephemeral_file() {
  local raw_path="$1"
  local label="$2"
  local canonical parent candidate_root is_temporary
  [[ -f "${raw_path}" && ! -L "${raw_path}" ]] || fail "${label} must be an explicit regular non-symlink file"
  canonical="$(cd "$(/usr/bin/dirname "${raw_path}")" && /bin/pwd -P)/$(/usr/bin/basename "${raw_path}")"
  [[ "$(/usr/bin/stat -f '%Lp' "${canonical}")" == "600" ]] || fail "${label} permissions must be 0600"
  [[ "$(/usr/bin/stat -f '%u' "${canonical}")" == "$(/usr/bin/id -u)" ]] || fail "${label} must be owned by the release user"
  parent="$(/usr/bin/dirname "${canonical}")"
  [[ "$(/usr/bin/stat -f '%Lp' "${parent}")" == "700" ]] || fail "${label} parent permissions must be 0700"
  is_temporary=0
  for candidate_root in "${RUNNER_TEMP:-}" "${TMPDIR:-/tmp}"; do
    if [[ -n "${candidate_root}" && -d "${candidate_root}" && ! -L "${candidate_root}" ]]; then
      candidate_root="$(cd "${candidate_root}" && /bin/pwd -P)"
      case "${canonical}" in
        "${candidate_root}"/*) is_temporary=1 ;;
      esac
    fi
  done
  [[ "${is_temporary}" == "1" ]] || fail "${label} must live under RUNNER_TEMP or TMPDIR"
  case "${canonical}" in
    "${REPO_ROOT}"/*) fail "${label} may not be stored in the source checkout" ;;
  esac
  printf '%s\n' "${canonical}"
}

canonical_evidence_file() {
  local raw_path="$1"
  local label="$2"
  local expected_basename="$3"
  local canonical
  [[ -f "${raw_path}" && ! -L "${raw_path}" ]] || fail "${label} must be a regular non-symlink file"
  canonical="$(cd "$(/usr/bin/dirname "${raw_path}")" && /bin/pwd -P)/$(/usr/bin/basename "${raw_path}")"
  [[ "$(/usr/bin/basename "${canonical}")" == "${expected_basename}" ]] || \
    fail "${label} must be named ${expected_basename}"
  [[ "$(/usr/bin/stat -f '%z' "${canonical}")" -le 4194304 ]] || fail "${label} exceeds 4 MiB"
  printf '%s\n' "${canonical}"
}

canonical_evidence_directory() {
  local raw_path="$1"
  local label="$2"
  local canonical
  [[ -d "${raw_path}" && ! -L "${raw_path}" ]] || fail "${label} must be a regular non-symlink directory"
  canonical="$(cd "${raw_path}" && /bin/pwd -P)"
  [[ -d "${canonical}" && ! -L "${canonical}" ]] || fail "${label} canonical path is unsafe"
  printf '%s\n' "${canonical}"
}

canonical_private_directory() {
  local raw_path="$1"
  local label="$2"
  local canonical
  canonical="$(canonical_evidence_directory "${raw_path}" "${label}")"
  [[ "$(/usr/bin/stat -f '%u' "${canonical}")" == "$(/usr/bin/id -u)" ]] || \
    fail "${label} must be owned by the release user"
  [[ "$(/usr/bin/stat -f '%Lp' "${canonical}")" == "700" ]] || \
    fail "${label} permissions must be exactly 0700"
  printf '%s\n' "${canonical}"
}

paths_overlap() {
  local first="$1"
  local second="$2"
  case "${first}" in
    "${second}"|"${second}"/*) return 0 ;;
  esac
  case "${second}" in
    "${first}"|"${first}"/*) return 0 ;;
  esac
  return 1
}

copy_public_file() {
  local source="$1"
  local destination="$2"
  [[ -f "${source}" && ! -L "${source}" ]] || fail "public evidence source is missing or unsafe: ${source}"
  [[ ! -e "${destination}" && ! -L "${destination}" ]] || fail "public evidence destination already exists: ${destination}"
  /usr/bin/ditto "${source}" "${destination}"
  [[ -f "${destination}" && ! -L "${destination}" ]] || fail "public evidence copy is unsafe: ${destination}"
}

if [[ "${MODE}" == "dry-run" ]]; then
  /usr/bin/env python3 "${SCRIPT_DIR}/validate_release_config.py" \
    --repository-root "${REPO_ROOT}" --config "${CONFIG}"
  /usr/bin/env python3 "${REPO_ROOT}/Release/Core/core_catalog_distribution.py" \
    --config "${CORE_RELEASE_CONFIG}"
  "${SCRIPT_DIR}/validate_release_tooling.sh" --skip-config
  printf '\nVela release dry-run completed. No archive, signing, notarization, staple, appcast, or publish action ran.\n'
  printf 'Production remains fail-closed until every reported blocker and external credential prerequisite is resolved.\n'
  exit 0
fi

[[ "${VELA_RELEASE_EXECUTE:-NO}" == "YES" ]] || fail "set VELA_RELEASE_EXECUTE=YES and pass --execute"
[[ "${PHASE}" == "candidate-stage" || "${PHASE}" == "promotion" ]] || \
  fail "production requires exactly one of --stage-candidate or --promote-candidate"
[[ -n "${VERSION}" && -n "${BUILD}" && -n "${CHANNEL}" && -n "${TAG}" ]] || fail "production requires version, build, channel, and tag"
[[ -n "${MIGRATION_EVIDENCE}" && -n "${EVIDENCE_ROOT}" && -n "${AUDIT_EVIDENCE}" && -n "${GO_NO_GO_EVIDENCE}" ]] || \
  fail "production requires migration, protected evidence root, private audit closure, and candidate-bound Go/No-Go evidence"
[[ -n "${PUBLISHED_BUILDS}" && -n "${SUPPORT_MATRIX}" && -n "${INSTALLATION_MATRIX}" ]] || \
  fail "production requires build-ledger, support-matrix, and installation-matrix evidence"
[[ -n "${CANDIDATE_STAGE_PATH}" ]] || fail "production requires an explicit --candidate-stage path"
if [[ "${PHASE}" == "candidate-stage" ]]; then
  [[ -n "${NOTES}" && -n "${FEED_HISTORY}" && -n "${PRIOR_APPCAST}" && -n "${PRIOR_APPCAST_SHA256}" ]] || \
    fail "candidate staging requires release notes, feed-history artifacts, and a prior signed appcast snapshot"
  [[ "${PRIOR_APPCAST_SHA256}" =~ ^[0-9a-f]{64}$ && "${PRIOR_APPCAST_SHA256}" != "0000000000000000000000000000000000000000000000000000000000000000" ]] || \
    fail "prior appcast SHA-256 must be a nonzero lowercase digest"
else
  [[ -n "${AUDIT_SUMMARY_EVIDENCE}" ]] || fail "promotion requires the public audit summary"
  [[ -n "${PROMOTION_OUTPUT_ROOT}" ]] || \
    fail "promotion requires an explicit protected --promotion-output-root outside the checkout"
fi
[[ "${CHANNEL}" == "stable" || "${CHANNEL}" == "beta" ]] || fail "channel must be stable or beta"
[[ "${BUILD}" =~ ^20[0-9]{8}$ ]] || fail "build must use YYYYMMDDNN"
/usr/bin/python3 - "${BUILD}" <<'PY'
from datetime import datetime
import sys

value = sys.argv[1]
datetime.strptime(value[:8], "%Y%m%d")
if value[8:] == "00":
    raise SystemExit("error: build sequence NN must be 01 through 99")
PY

CONFIGURED_VERSION="$(json_value versioning.marketingVersion)"
[[ "${VERSION}" == "${CONFIGURED_VERSION}" ]] || fail "version differs from release config"
if [[ "${CHANNEL}" == "stable" ]]; then
  [[ "${TAG}" == "v${VERSION}" ]] || fail "Stable tag must be v${VERSION}"
  [[ -z "${PRERELEASE_LABEL}" ]] || fail "Stable release may not have a prerelease label"
  CANDIDATE_VERSION="${VERSION}"
  CANDIDATE_CHANNEL="stable"
else
  [[ "${TAG}" =~ ^v${VERSION//./\.}-rc\.([1-9][0-9]*)$ ]] || \
    fail "V1 RC tag must be v${VERSION}-rc.N"
  RC_SEQUENCE="${BASH_REMATCH[1]}"
  CANDIDATE_VERSION="${TAG#v}"
  CANDIDATE_CHANNEL="rc"
  [[ "${PRERELEASE_LABEL}" == "RC ${RC_SEQUENCE}" ]] || \
    fail "RC prerelease label must be exactly RC ${RC_SEQUENCE}"
fi

/usr/bin/env python3 "${SCRIPT_DIR}/validate_release_config.py" \
  --repository-root "${REPO_ROOT}" --config "${CONFIG}" --production
CORE_CATALOG_URL="$(/usr/bin/env python3 "${REPO_ROOT}/Release/Core/core_catalog_distribution.py" \
  --config "${CORE_RELEASE_CONFIG}" --production --emit catalogURL)"
CORE_CATALOG_SIGNATURES_URL="$(/usr/bin/env python3 "${REPO_ROOT}/Release/Core/core_catalog_distribution.py" \
  --config "${CORE_RELEASE_CONFIG}" --production --emit catalogSignaturesURL)"
MIGRATION_EVIDENCE="$(canonical_evidence_file "${MIGRATION_EVIDENCE}" "migration evidence" "migration-guarantee.json")"
EVIDENCE_ROOT="$(canonical_evidence_directory "${EVIDENCE_ROOT}" "protected evidence root")"
AUDIT_EVIDENCE="$(canonical_evidence_file "${AUDIT_EVIDENCE}" "audit evidence" "audit-closure.json")"
GO_NO_GO_EVIDENCE="$(canonical_evidence_file "${GO_NO_GO_EVIDENCE}" "Go/No-Go evidence" "go-no-go.json")"
PUBLISHED_BUILDS="$(canonical_evidence_file "${PUBLISHED_BUILDS}" "published-build evidence" "published-builds.json")"
SUPPORT_MATRIX="$(canonical_evidence_file "${SUPPORT_MATRIX}" "support-matrix evidence" "support-matrix.json")"
INSTALLATION_MATRIX="$(canonical_evidence_file "${INSTALLATION_MATRIX}" "installation-matrix evidence" "installation-matrix.json")"
if [[ "${PHASE}" == "promotion" ]]; then
  PROMOTION_OUTPUT_ROOT="$(canonical_private_directory \
    "${PROMOTION_OUTPUT_ROOT}" "protected promotion output root")"
  case "${PROMOTION_OUTPUT_ROOT}" in
    "${REPO_ROOT}"|"${REPO_ROOT}"/*) \
      fail "protected promotion output root must be outside the source checkout" ;;
  esac
fi

EXPECTED_STAGE_NAME="candidate-stage-${CANDIDATE_VERSION}-${BUILD}"
if [[ "$(/usr/bin/basename "${CANDIDATE_STAGE_PATH}")" != "${EXPECTED_STAGE_NAME}" ]]; then
  fail "candidate-stage path must be named ${EXPECTED_STAGE_NAME}"
fi
CANDIDATE_STAGE_PARENT="$(canonical_private_directory \
  "$(/usr/bin/dirname "${CANDIDATE_STAGE_PATH}")" "candidate-stage parent")"
CANDIDATE_STAGE_PATH="${CANDIDATE_STAGE_PARENT}/${EXPECTED_STAGE_NAME}"
if paths_overlap "${CANDIDATE_STAGE_PATH}" "${EVIDENCE_ROOT}"; then
  fail "candidate-stage and protected evidence roots must be separate and non-overlapping"
fi
if [[ "${PHASE}" == "promotion" ]]; then
  if paths_overlap "${PROMOTION_OUTPUT_ROOT}" "${EVIDENCE_ROOT}" || \
     paths_overlap "${PROMOTION_OUTPUT_ROOT}" "${CANDIDATE_STAGE_PATH}"; then
    fail "promotion output, candidate-stage, and protected evidence roots must be pairwise non-overlapping"
  fi
fi
if [[ "${PHASE}" == "candidate-stage" ]]; then
  [[ ! -e "${CANDIDATE_STAGE_PATH}" && ! -L "${CANDIDATE_STAGE_PATH}" ]] || \
    fail "candidate-stage output already exists"
  [[ -f "${NOTES}" && ! -L "${NOTES}" ]] || fail "release notes must be a regular file"
  [[ -d "${FEED_HISTORY}" && ! -L "${FEED_HISTORY}" ]] || fail "feed history must be a regular directory"
  if /usr/bin/find -P "${FEED_HISTORY}" -type l -print -quit | /usr/bin/grep -q .; then
    fail "feed-history may not contain symlinks"
  fi
  if [[ -e "${FEED_HISTORY}/appcast.xml" || -L "${FEED_HISTORY}/appcast.xml" ]]; then
    fail "feed-history must contain immutable archives/notes, not a mutable appcast.xml"
  fi
  PRIOR_APPCAST="$(canonical_evidence_file "${PRIOR_APPCAST}" "prior appcast snapshot" "prior-appcast.xml")"
  /usr/bin/env python3 "${SCRIPT_DIR}/validate_release_notes.py" \
    "${NOTES}" --candidate-version "${CANDIDATE_VERSION}" --production
else
  [[ -d "${CANDIDATE_STAGE_PATH}" && ! -L "${CANDIDATE_STAGE_PATH}" ]] || \
    fail "immutable candidate-stage input is missing or unsafe"
  /usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/validate_candidate_stage_tree.py" \
    "${CANDIDATE_STAGE_PATH}"
  AUDIT_SUMMARY_EVIDENCE="$(canonical_evidence_file "${AUDIT_SUMMARY_EVIDENCE}" "public audit summary" "audit-summary.md")"
fi

[[ -z "$(/usr/bin/git -C "${REPO_ROOT}" status --porcelain)" ]] || fail "production release requires a clean checkout including untracked files"
HEAD="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse HEAD)"
TAG_COMMIT="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse "${TAG}^{commit}" 2>/dev/null || true)"
[[ -n "${TAG_COMMIT}" && "${TAG_COMMIT}" == "${HEAD}" ]] || fail "requested tag does not point at HEAD"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "production release host must be arm64"

PREFLIGHT_PHASE_ARGS=(--expect-reserved)
if [[ "${PHASE}" == "candidate-stage" ]]; then
  PREFLIGHT_PHASE_ARGS+=(--candidate-stage)
else
  PREFLIGHT_PHASE_ARGS+=(--promotion --candidate-stage-path "${CANDIDATE_STAGE_PATH}")
fi
"${REPO_ROOT}/ReleaseCandidate/scripts/preflight.sh" \
  --version "${VERSION}" \
  --candidate-version "${CANDIDATE_VERSION}" \
  --build "${BUILD}" \
  --tag "${TAG}" \
  --channel "${CANDIDATE_CHANNEL}" \
  --evidence-dir "${EVIDENCE_ROOT}" \
  --migration "${MIGRATION_EVIDENCE}" \
  --audit "${AUDIT_EVIDENCE}" \
  --go-no-go "${GO_NO_GO_EVIDENCE}" \
  --published-builds "${PUBLISHED_BUILDS}" \
  --support-matrix "${SUPPORT_MATRIX}" \
  --installation-matrix "${INSTALLATION_MATRIX}" \
  "${PREFLIGHT_PHASE_ARGS[@]}"

SOURCE_DATE_EPOCH="$(/usr/bin/python3 - "${DOCUMENTATION_CONFIG}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)["sourceDateEpoch"]
if not isinstance(value, int) or value < 0:
    raise SystemExit("error: documentation sourceDateEpoch must be a non-negative integer")
print(value)
PY
)"
export SOURCE_DATE_EPOCH
/usr/bin/env python3 "${SCRIPT_DIR}/validate_v07_acceptance.py" --source \
  --repository-root "${REPO_ROOT}" --config "${DOCUMENTATION_CONFIG}" \
  --app-version "${VERSION}" --app-build "${BUILD}"

if [[ "${PHASE}" == "candidate-stage" ]]; then
  TEAM_ID="$(json_value product.teamIdentifier)"
  [[ -n "${VELA_RELEASE_KEYCHAIN:-}" ]] || fail "VELA_RELEASE_KEYCHAIN is required; persistent Keychain fallback is forbidden"
  RELEASE_KEYCHAIN="$(validate_ephemeral_file "${VELA_RELEASE_KEYCHAIN}" "release Keychain")"
  case "$(/usr/bin/basename "${RELEASE_KEYCHAIN}")" in
    login.keychain|login.keychain-db|System.keychain) fail "persistent login/system Keychains are forbidden" ;;
  esac
  /usr/bin/security show-keychain-info "${RELEASE_KEYCHAIN}" >/dev/null 2>&1 || fail "ephemeral release Keychain is unavailable or locked"
  SEARCH_COUNT="$(/usr/bin/security list-keychains -d user | /usr/bin/awk 'NF {count++} END {print count+0}')"
  SEARCH_KEYCHAIN="$(/usr/bin/security list-keychains -d user | /usr/bin/sed -n '1{s/^[[:space:]]*"//;s/"[[:space:]]*$//;p;}')"
  [[ "${SEARCH_COUNT}" == "1" && "${SEARCH_KEYCHAIN}" == "${RELEASE_KEYCHAIN}" ]] || fail "user Keychain search list must contain only the ephemeral release Keychain"

  IDENTITY="${VELA_DEVELOPER_IDENTITY:-}"
  [[ -n "${IDENTITY}" ]] || fail "VELA_DEVELOPER_IDENTITY is required; identity auto-discovery is forbidden"
  /usr/bin/security find-identity -p codesigning -v "${RELEASE_KEYCHAIN}" | /usr/bin/grep -Fq "\"${IDENTITY}\"" || fail "configured Developer ID identity is not valid in the ephemeral Keychain"
  printf '%s\n' "${IDENTITY}" | /usr/bin/grep -Fq "(${TEAM_ID})" || fail "Developer ID identity has the wrong Team ID"

  CERTIFICATE_SHA256="$(/usr/bin/security find-certificate -Z -c "${IDENTITY}" "${RELEASE_KEYCHAIN}" 2>/dev/null | /usr/bin/awk -F': ' '/SHA-256 hash:/ {print tolower($2); exit}')"
  [[ "${CERTIFICATE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "could not determine Developer ID certificate SHA-256"
  CERTIFICATE_SERIAL="$(/usr/bin/security find-certificate -c "${IDENTITY}" -p "${RELEASE_KEYCHAIN}" 2>/dev/null | /usr/bin/openssl x509 -serial -noout 2>/dev/null | /usr/bin/sed 's/^serial=//' | /usr/bin/tr 'A-F' 'a-f')"
  [[ "${CERTIFICATE_SERIAL}" =~ ^[0-9a-f]+$ ]] || fail "could not determine Developer ID certificate serial"

  [[ -n "${NOTARY_PROFILE:-}" ]] || fail "NOTARY_PROFILE is required"
  [[ "${NOTARY_PROFILE}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "NOTARY_PROFILE contains unsafe characters"
  [[ -n "${SPARKLE_BIN:-}" ]] || fail "SPARKLE_BIN is required"
  [[ -x "${SPARKLE_BIN}/generate_appcast" && -x "${SPARKLE_BIN}/sign_update" ]] || fail "Sparkle signing tools are missing"
  "${SPARKLE_BIN}/generate_appcast" --version 2>&1 | /usr/bin/grep -Fq '2.9.4' || fail "Sparkle tools must be exactly 2.9.4"
  [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] || fail "SPARKLE_ED_KEY_FILE is required; Keychain/default-key fallback is forbidden"
  SPARKLE_ED_KEY_FILE="$(validate_ephemeral_file "${SPARKLE_ED_KEY_FILE}" "Sparkle EdDSA key file")"
  [[ -s "${SPARKLE_ED_KEY_FILE}" ]] || fail "Sparkle EdDSA key file is empty"
  [[ "$(/usr/bin/stat -f '%z' "${SPARKLE_ED_KEY_FILE}")" -le 16384 ]] || fail "Sparkle EdDSA key file is unexpectedly large"

  OTHER_CODE_SIGN_FLAGS="--keychain ${RELEASE_KEYCHAIN}"
  export OTHER_CODE_SIGN_FLAGS
fi

PROJECT="${REPO_ROOT}/$(json_value product.project)"
SCHEME="$(json_value product.scheme)"
PACKAGE_RESOLVED="${REPO_ROOT}/$(json_value paths.packageResolved)"
EXPORT_OPTIONS="${REPO_ROOT}/$(json_value paths.exportOptions)"
APPCAST_POLICY="${REPO_ROOT}/$(json_value paths.appcastPolicy)"
SPARKLE_FEED_URL="$(json_value updates.feedURL)"
SPARKLE_PUBLIC_KEY="$(json_value updates.publicEDKey)"
STAGING_ROOT="${REPO_ROOT}/$(json_value paths.staging)"
if [[ "${PHASE}" == "promotion" ]]; then
  OUTPUT_ROOT="${PROMOTION_OUTPUT_ROOT}"
else
  OUTPUT_ROOT="${REPO_ROOT}/$(json_value paths.output)"
fi
if paths_overlap "${STAGING_ROOT}" "${OUTPUT_ROOT}" || \
   paths_overlap "${STAGING_ROOT}" "${EVIDENCE_ROOT}" || \
   paths_overlap "${OUTPUT_ROOT}" "${EVIDENCE_ROOT}" || \
   paths_overlap "${STAGING_ROOT}" "${CANDIDATE_STAGE_PATH}" || \
   paths_overlap "${OUTPUT_ROOT}" "${CANDIDATE_STAGE_PATH}"; then
  fail "candidate, evidence, staging, and public output roots must be pairwise non-overlapping"
fi
RELEASE_ID="${VERSION}-${BUILD}-${CHANNEL}"
STAGE="${STAGING_ROOT}/${RELEASE_ID}"
FINAL_OUTPUT="${OUTPUT_ROOT}/${RELEASE_ID}"
[[ ! -e "${STAGE}" && ! -L "${STAGE}" ]] || fail "release staging already exists: ${STAGE}"
[[ ! -e "${FINAL_OUTPUT}" && ! -L "${FINAL_OUTPUT}" ]] || fail "immutable release output already exists: ${FINAL_OUTPUT}"
[[ ! -L "${STAGING_ROOT}" && ! -L "${OUTPUT_ROOT}" ]] || fail "release staging/output roots must not be symlinks"

if [[ "${PHASE}" == "candidate-stage" ]]; then
  /bin/mkdir -p "${STAGE}/build" "${STAGE}/export" "${STAGE}/updates" \
    "${STAGE}/public/release-notes" "${STAGE}/private/notary"
  /bin/chmod 0700 "${STAGE}" "${STAGE}/build" "${STAGE}/export" "${STAGE}/updates" \
    "${STAGE}/private" "${STAGE}/private/notary"

  BUNDLE_MANIFEST="${STAGE}/build/VelaReleaseManifest.json"
MANIFEST_ARGS=(
  --repository-root "${REPO_ROOT}"
  --config "${CONFIG}"
  --kind bundle
  --version "${VERSION}"
  --build "${BUILD}"
  --channel "${CHANNEL}"
  --tag "${TAG}"
  --output "${BUNDLE_MANIFEST}"
)
if [[ -n "${PRERELEASE_LABEL}" ]]; then
  MANIFEST_ARGS+=(--prerelease-label "${PRERELEASE_LABEL}")
fi
/usr/bin/env python3 "${SCRIPT_DIR}/generate_release_manifest.py" "${MANIFEST_ARGS[@]}"

ARCHIVE="${STAGE}/build/Vela.xcarchive"
/usr/bin/xcodebuild archive \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE}" \
  -disableAutomaticPackageResolution \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD}" \
  ARCHS=arm64 \
  VELA_RELEASE_CHANNEL="${CHANNEL}" \
  VELA_PRERELEASE_LABEL="${PRERELEASE_LABEL}" \
  VELA_CORE_CATALOG_URL="${CORE_CATALOG_URL}" \
  VELA_CORE_CATALOG_SIGNATURES_URL="${CORE_CATALOG_SIGNATURES_URL}" \
  VELA_SPARKLE_FEED_URL="${SPARKLE_FEED_URL}" \
  VELA_SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY}" \
  VELA_RELEASE_MANIFEST_PATH="${BUNDLE_MANIFEST}" \
  VELA_RELEASE_MANIFEST_REQUIRED=YES \
  OTHER_CODE_SIGN_FLAGS="${OTHER_CODE_SIGN_FLAGS}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  archive

/usr/bin/xcodebuild -exportArchive \
  -archivePath "${ARCHIVE}" \
  -exportPath "${STAGE}/export" \
  -exportOptionsPlist "${EXPORT_OPTIONS}"

APP="${STAGE}/export/Vela.app"
[[ -d "${APP}" && ! -L "${APP}" ]] || fail "export did not produce Vela.app"
"${SCRIPT_DIR}/verify_release_bundle.sh" --production --app "${APP}" \
  --config "${CONFIG}" --expected-version "${VERSION}" --expected-build "${BUILD}"

APP_ZIP="${STAGE}/private/Vela-${CANDIDATE_VERSION}-${BUILD}-app-notary.zip"
"${SCRIPT_DIR}/notarize_artifact.sh" --execute --kind app --artifact "${APP}" \
  --receipt-dir "${STAGE}/private/notary" --archive-output "${APP_ZIP}" \
  --keychain "${RELEASE_KEYCHAIN}"

DMG="${STAGE}/public/Vela-${CANDIDATE_VERSION}-arm64.dmg"
"${SCRIPT_DIR}/create_release_dmg.sh" --app "${APP}" --output "${DMG}"
"${SCRIPT_DIR}/notarize_artifact.sh" --execute --kind dmg --artifact "${DMG}" \
  --receipt-dir "${STAGE}/private/notary" --keychain "${RELEASE_KEYCHAIN}"
"${SCRIPT_DIR}/verify_release_bundle.sh" --post-notary --app "${APP}" --dmg "${DMG}" \
  --config "${CONFIG}" --expected-version "${VERSION}" --expected-build "${BUILD}"

/usr/bin/ditto "${FEED_HISTORY}" "${STAGE}/updates"
/usr/bin/ditto "${DMG}" "${STAGE}/updates/$(/usr/bin/basename "${DMG}")"
NOTES_FOR_SPARKLE="${STAGE}/updates/Vela-${CANDIDATE_VERSION}-arm64.md"
/usr/bin/ditto "${NOTES}" "${NOTES_FOR_SPARKLE}"
/usr/bin/ditto "${NOTES}" "${STAGE}/public/release-notes/${CANDIDATE_VERSION}.md"
"${SCRIPT_DIR}/generate_signed_appcast.sh" --execute --updates-dir "${STAGE}/updates" \
  --policy "${APPCAST_POLICY}" --ed-key-file "${SPARKLE_ED_KEY_FILE}" \
  --prior-appcast "${PRIOR_APPCAST}" --prior-appcast-sha256 "${PRIOR_APPCAST_SHA256}" \
  --channel "${CHANNEL}" --build "${BUILD}"
APPCAST="${STAGE}/updates/appcast.xml"
/usr/bin/ditto "${APPCAST}" "${STAGE}/public/appcast.xml"
SIGNED_RELEASE_NOTES="${STAGE}/public/$(/usr/bin/basename "${NOTES_FOR_SPARKLE}")"
copy_public_file "${NOTES_FOR_SPARKLE}" "${SIGNED_RELEASE_NOTES}"
/usr/bin/cmp -s "${NOTES_FOR_SPARKLE}" "${SIGNED_RELEASE_NOTES}" || \
  fail "published signed release notes differ from the appcast input"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_appcast_policy.py" \
  "${STAGE}/public/appcast.xml" \
  --policy "${APPCAST_POLICY}" \
  --artifacts-dir "${STAGE}/updates" \
  --expected-build "${BUILD}" \
  --expected-release-notes "${SIGNED_RELEASE_NOTES}"

EXTERNAL_MANIFEST="${STAGE}/public/release-manifest-${CANDIDATE_VERSION}.json"
EXTERNAL_ARGS=(
  --repository-root "${REPO_ROOT}"
  --config "${CONFIG}"
  --kind external
  --version "${VERSION}"
  --build "${BUILD}"
  --channel "${CHANNEL}"
  --tag "${TAG}"
  --output "${EXTERNAL_MANIFEST}"
  --app "${APP}"
  --app-zip "${APP_ZIP}"
  --dmg "${DMG}"
  --appcast "${STAGE}/public/appcast.xml"
  --app-notary-receipt "${STAGE}/private/notary/notary-app-result.json"
  --dmg-notary-receipt "${STAGE}/private/notary/notary-dmg-result.json"
  --signing-certificate-sha256 "${CERTIFICATE_SHA256}"
  --signing-certificate-serial "${CERTIFICATE_SERIAL}"
)
if [[ -n "${PRERELEASE_LABEL}" ]]; then
  EXTERNAL_ARGS+=(--prerelease-label "${PRERELEASE_LABEL}")
fi
/usr/bin/env python3 "${SCRIPT_DIR}/generate_release_manifest.py" "${EXTERNAL_ARGS[@]}"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
  "${EXTERNAL_MANIFEST}" --kind external --production

SBOM="${STAGE}/public/sbom-${CANDIDATE_VERSION}.spdx.json"
  /usr/bin/env python3 "${SCRIPT_DIR}/generate_sbom.py" \
    --repository-root "${REPO_ROOT}" --config "${CONFIG}" \
    --version "${VERSION}" --build "${BUILD}" --output "${SBOM}"

  ARCHITECTURE_STAGE="${STAGE}/private/architecture-freeze.json"
  copy_public_file "${REPO_ROOT}/Hardening/config/architecture-freeze.json" "${ARCHITECTURE_STAGE}"
  ARCHIVE_RECEIPT="${STAGE}/private/dsym-inventory.json"
  /usr/bin/env python3 "${SCRIPT_DIR}/inventory_dsyms.py" \
    --archive "${ARCHIVE}" --output "${ARCHIVE_RECEIPT}" \
    --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json" \
    --require Vela --require VelaHelper
  ARCHIVE_ZIP="${STAGE}/private/Vela-${CANDIDATE_VERSION}-${BUILD}.xcarchive.zip"
  /usr/bin/ditto -c -k --keepParent "${ARCHIVE}" "${ARCHIVE_ZIP}"
  [[ -f "${ARCHIVE_ZIP}" && ! -L "${ARCHIVE_ZIP}" && -s "${ARCHIVE_ZIP}" ]] || \
    fail "xcarchive container was not sealed as a regular ZIP"
  /usr/bin/env python3 "${SCRIPT_DIR}/verify_archive_container.py" \
    --archive-zip "${ARCHIVE_ZIP}" --live-archive "${ARCHIVE}" \
    --receipt "${ARCHIVE_RECEIPT}" \
    --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json" \
    --require Vela --require VelaHelper
  UPDATES_CHECKSUMS="${STAGE}/private/updates-checksums.txt"
  UPDATES_FILES=()
  while IFS= read -r -d '' update_file; do
    UPDATES_FILES+=("${update_file}")
  done < <(/usr/bin/find -P "${STAGE}/updates" -type f -print0)
  [[ "${#UPDATES_FILES[@]}" -ge 3 ]] || fail "candidate updates inventory is incomplete"
  /usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" generate \
    --base-dir "${STAGE}/updates" --output "${UPDATES_CHECKSUMS}" \
    "${UPDATES_FILES[@]}"
  /usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" verify \
    --checksums "${UPDATES_CHECKSUMS}" --base-dir "${STAGE}/updates" --require-complete
  /usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/generate_candidate_stage_evidence.py" \
    --repository-root "${REPO_ROOT}" \
    --evidence-root "${STAGE}" \
    --candidate-version "${CANDIDATE_VERSION}" \
    --build "${BUILD}" \
    --tag "${TAG}" \
    --commit "${HEAD}" \
    --architecture-freeze "private/architecture-freeze.json" \
    --dmg "updates/$(/usr/bin/basename "${DMG}")" \
    --appcast "updates/appcast.xml" \
    --sbom "public/$(/usr/bin/basename "${SBOM}")" \
    --signed-release-notes "updates/$(/usr/bin/basename "${NOTES_FOR_SPARKLE}")" \
    --updates-root "updates" \
    --updates-checksums "private/$(/usr/bin/basename "${UPDATES_CHECKSUMS}")" \
    --app-receipt "public/$(/usr/bin/basename "${EXTERNAL_MANIFEST}")" \
    --archive-receipt "private/$(/usr/bin/basename "${ARCHIVE_RECEIPT}")" \
    --archive-directory "build/Vela.xcarchive" \
    --app-archive "private/$(/usr/bin/basename "${APP_ZIP}")" \
    --archive-container "private/$(/usr/bin/basename "${ARCHIVE_ZIP}")" \
    --app-notary-receipt "private/notary/notary-app-result.json" \
    --dmg-notary-receipt "private/notary/notary-dmg-result.json" \
    --sparkle-sign-update "${SPARKLE_BIN}/sign_update" \
    --sparkle-ed-key-file "${SPARKLE_ED_KEY_FILE}" \
    --signing-certificate-sha256 "${CERTIFICATE_SHA256}" \
    --output "${STAGE}/private/candidate-stage-evidence.json"
  /usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/validate_candidate_stage_evidence.py" \
    "${STAGE}/private/candidate-stage-evidence.json" \
    --evidence-root "${STAGE}" --verify-files \
    --candidate-version "${CANDIDATE_VERSION}" --build "${BUILD}" \
    --tag "${TAG}" --commit "${HEAD}"

  CANDIDATE_PENDING="$(/usr/bin/mktemp -d "${CANDIDATE_STAGE_PARENT}/.${EXPECTED_STAGE_NAME}.XXXXXX")"
  /bin/rmdir "${CANDIDATE_PENDING}"
  /usr/bin/ditto "${STAGE}" "${CANDIDATE_PENDING}"
  /bin/chmod -R go-rwx "${CANDIDATE_PENDING}"
  /usr/bin/env python3 "${SCRIPT_DIR}/atomic_publish_directory.py" \
    "${CANDIDATE_PENDING}" "${CANDIDATE_STAGE_PATH}"
  /usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/validate_candidate_stage_tree.py" \
    "${CANDIDATE_STAGE_PATH}"
  /usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/validate_candidate_stage_evidence.py" \
    "${CANDIDATE_STAGE_PATH}/private/candidate-stage-evidence.json" \
    --evidence-root "${CANDIDATE_STAGE_PATH}" --verify-files \
    --candidate-version "${CANDIDATE_VERSION}" --build "${BUILD}" \
    --tag "${TAG}" --commit "${HEAD}"
  printf '\nImmutable private candidate staged: %s\n' "${CANDIDATE_STAGE_PATH}"
  printf 'Decision remains NO-GO until exact-byte soak, installation matrix, and final approvals pass.\n'
  exit 0
else
  /bin/mkdir -p "${STAGING_ROOT}"
  [[ -d "${STAGING_ROOT}" && ! -L "${STAGING_ROOT}" ]] || fail "release staging root is unsafe"
  /usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/validate_candidate_stage_tree.py" \
    "${CANDIDATE_STAGE_PATH}"
  /usr/bin/ditto "${CANDIDATE_STAGE_PATH}" "${STAGE}"
  BUNDLE_MANIFEST="${STAGE}/build/VelaReleaseManifest.json"
  ARCHIVE="${STAGE}/build/Vela.xcarchive"
  APP="${STAGE}/export/Vela.app"
  APP_ZIP="${STAGE}/private/Vela-${CANDIDATE_VERSION}-${BUILD}-app-notary.zip"
  DMG="${STAGE}/public/Vela-${CANDIDATE_VERSION}-arm64.dmg"
  APPCAST="${STAGE}/updates/appcast.xml"
  NOTES_FOR_SPARKLE="${STAGE}/updates/Vela-${CANDIDATE_VERSION}-arm64.md"
  SIGNED_RELEASE_NOTES="${STAGE}/public/Vela-${CANDIDATE_VERSION}-arm64.md"
  EXTERNAL_MANIFEST="${STAGE}/public/release-manifest-${CANDIDATE_VERSION}.json"
  SBOM="${STAGE}/public/sbom-${CANDIDATE_VERSION}.spdx.json"
  ARCHIVE_ZIP="${STAGE}/private/Vela-${CANDIDATE_VERSION}-${BUILD}.xcarchive.zip"
  ARCHITECTURE_SHA256="$(/usr/bin/shasum -a 256 "${REPO_ROOT}/Hardening/config/architecture-freeze.json" | /usr/bin/awk '{print $1}')"
  /usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/validate_candidate_stage_evidence.py" \
    "${STAGE}/private/candidate-stage-evidence.json" \
    --evidence-root "${STAGE}" --verify-files \
    --candidate-version "${CANDIDATE_VERSION}" --build "${BUILD}" \
    --tag "${TAG}" --commit "${HEAD}" \
    --architecture-sha256 "${ARCHITECTURE_SHA256}"
  /usr/bin/env python3 "${SCRIPT_DIR}/verify_archive_container.py" \
    --archive-zip "${ARCHIVE_ZIP}" --live-archive "${ARCHIVE}" \
    --receipt "${STAGE}/private/dsym-inventory.json" \
    --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json" \
    --require Vela --require VelaHelper
  "${SCRIPT_DIR}/verify_release_bundle.sh" --post-notary --app "${APP}" --dmg "${DMG}" \
    --config "${CONFIG}" --expected-version "${VERSION}" --expected-build "${BUILD}"
  /usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
    "${EXTERNAL_MANIFEST}" --kind external --production
  /usr/bin/env python3 "${SCRIPT_DIR}/verify_appcast_policy.py" \
    "${STAGE}/public/appcast.xml" --policy "${APPCAST_POLICY}" \
    --artifacts-dir "${STAGE}/updates" --expected-build "${BUILD}" \
    --expected-release-notes "${SIGNED_RELEASE_NOTES}"
fi

PUBLIC_CONTRACT_SOURCE="${REPO_ROOT}/Contracts/v1/public-contract-freeze.json"
APP_INTENT_REGISTRY_SOURCE="${REPO_ROOT}/Contracts/v1/app-intent-registry.json"
CONTRACT_HASHES_SOURCE="${REPO_ROOT}/Contracts/v1/hashes.json"
FEATURE_FREEZE_SOURCE="${REPO_ROOT}/ReleaseCandidate/config/feature-freeze.json"
ARCHITECTURE_SOURCE="${REPO_ROOT}/Hardening/config/architecture-freeze.json"
DOCUMENTATION_SOURCE="${REPO_ROOT}/Vela/Resources/VelaDocumentationManifest.json"
PRIVACY_SOURCE="${REPO_ROOT}/Vela/Resources/PrivacyInfo.xcprivacy"
KNOWN_LIMITATIONS_SOURCE="${REPO_ROOT}/ReleaseCandidate/config/known-limitations.json"

PUBLIC_CONTRACT="${STAGE}/public/public-contract-freeze.json"
APP_INTENT_REGISTRY="${STAGE}/public/app-intent-registry.json"
CONTRACT_HASHES="${STAGE}/public/contract-hashes.json"
FEATURE_FREEZE="${STAGE}/public/feature-freeze.json"
ARCHITECTURE="${STAGE}/public/architecture-freeze.json"
DOCUMENTATION="${STAGE}/public/VelaDocumentationManifest.json"
PRIVACY="${STAGE}/public/PrivacyInfo.xcprivacy"
MIGRATION="${STAGE}/public/migration-guarantee.json"
AUDIT_SUMMARY="${STAGE}/public/audit-summary.md"
KNOWN_LIMITATIONS="${STAGE}/public/known-limitations.json"
PUBLISHED="${STAGE}/public/published-builds.json"
SUPPORT="${STAGE}/public/support-matrix.json"

copy_public_file "${PUBLIC_CONTRACT_SOURCE}" "${PUBLIC_CONTRACT}"
copy_public_file "${APP_INTENT_REGISTRY_SOURCE}" "${APP_INTENT_REGISTRY}"
copy_public_file "${CONTRACT_HASHES_SOURCE}" "${CONTRACT_HASHES}"
copy_public_file "${FEATURE_FREEZE_SOURCE}" "${FEATURE_FREEZE}"
copy_public_file "${ARCHITECTURE_SOURCE}" "${ARCHITECTURE}"
copy_public_file "${DOCUMENTATION_SOURCE}" "${DOCUMENTATION}"
copy_public_file "${PRIVACY_SOURCE}" "${PRIVACY}"
copy_public_file "${MIGRATION_EVIDENCE}" "${MIGRATION}"
copy_public_file "${AUDIT_SUMMARY_EVIDENCE}" "${AUDIT_SUMMARY}"
copy_public_file "${KNOWN_LIMITATIONS_SOURCE}" "${KNOWN_LIMITATIONS}"
copy_public_file "${PUBLISHED_BUILDS}" "${PUBLISHED}"
copy_public_file "${SUPPORT_MATRIX}" "${SUPPORT}"

ARTIFACT_CHECKSUMS="${STAGE}/public/artifact-checksums-${CANDIDATE_VERSION}.txt"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" generate \
  --output "${ARTIFACT_CHECKSUMS}" \
  "${DMG}" "${STAGE}/public/appcast.xml" "${EXTERNAL_MANIFEST}" "${SBOM}"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" verify \
  --checksums "${ARTIFACT_CHECKSUMS}" --base-dir "${STAGE}/public"

RC_MANIFEST="${STAGE}/public/release-candidate-manifest-${CANDIDATE_VERSION}.json"
RC_ARGS=(
  --repository-root "${REPO_ROOT}"
  --version "${VERSION}"
  --candidate-version "${CANDIDATE_VERSION}"
  --build "${BUILD}"
  --tag "${TAG}"
  --public-contract "${PUBLIC_CONTRACT_SOURCE}"
  --architecture-freeze "${ARCHITECTURE_SOURCE}"
  --documentation-manifest "${DOCUMENTATION_SOURCE}"
  --privacy-manifest "${PRIVACY_SOURCE}"
  --migration "${MIGRATION_EVIDENCE}"
  --audit "${AUDIT_EVIDENCE}"
  --audit-summary "${AUDIT_SUMMARY_EVIDENCE}"
  --known-limitations "${KNOWN_LIMITATIONS_SOURCE}"
  --go-no-go "${GO_NO_GO_EVIDENCE}"
  --release-manifest "${EXTERNAL_MANIFEST}"
  --dmg "${DMG}"
  --sbom "${SBOM}"
  --appcast "${STAGE}/public/appcast.xml"
  --checksums "${ARTIFACT_CHECKSUMS}"
  --evidence-root "${EVIDENCE_ROOT}"
  --require-release-ready
  --output "${RC_MANIFEST}"
)
if [[ -n "${PRERELEASE_LABEL}" ]]; then
  RC_ARGS+=(--prerelease-label "${PRERELEASE_LABEL}")
fi
/usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/generate_rc_manifest.py" "${RC_ARGS[@]}"
/usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/validate_release_candidate.py" \
  "${RC_MANIFEST}" --stage local --verify-files --artifacts-dir "${STAGE}/public" \
  --version "${VERSION}" --candidate-version "${CANDIDATE_VERSION}" \
  --build "${BUILD}" --tag "${TAG}" --commit "${HEAD}"

READINESS="${STAGE}/public/v1-readiness-${CANDIDATE_VERSION}.json"
/usr/bin/env python3 "${REPO_ROOT}/ReleaseCandidate/scripts/generate_v1_readiness_report.py" \
  --rc "${RC_MANIFEST}" \
  --go-no-go "${GO_NO_GO_EVIDENCE}" \
  --migration "${MIGRATION_EVIDENCE}" \
  --audit "${AUDIT_EVIDENCE}" \
  --audit-summary "${AUDIT_SUMMARY_EVIDENCE}" \
  --known-limitations "${KNOWN_LIMITATIONS_SOURCE}" \
  --repository-root "${REPO_ROOT}" \
  --evidence-root "${EVIDENCE_ROOT}" \
  --public-contract "${PUBLIC_CONTRACT_SOURCE}" \
  --output "${READINESS}"

/usr/bin/env python3 "${SCRIPT_DIR}/inventory_dsyms.py" \
  --archive "${ARCHIVE}" \
  --verify-receipt "${STAGE}/private/dsym-inventory.json" \
  --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json" \
  --require Vela --require VelaHelper
/usr/bin/ditto "${PACKAGE_RESOLVED}" "${STAGE}/private/Package.resolved"

CHECKSUMS="${STAGE}/public/checksums.txt"
PUBLIC_INVENTORY=(
  "${DMG}"
  "${STAGE}/public/appcast.xml"
  "${EXTERNAL_MANIFEST}"
  "${SBOM}"
  "${SIGNED_RELEASE_NOTES}"
  "${STAGE}/public/release-notes/${CANDIDATE_VERSION}.md"
  "${PUBLIC_CONTRACT}"
  "${APP_INTENT_REGISTRY}"
  "${CONTRACT_HASHES}"
  "${FEATURE_FREEZE}"
  "${ARCHITECTURE}"
  "${DOCUMENTATION}"
  "${PRIVACY}"
  "${MIGRATION}"
  "${AUDIT_SUMMARY}"
  "${KNOWN_LIMITATIONS}"
  "${PUBLISHED}"
  "${SUPPORT}"
  "${ARTIFACT_CHECKSUMS}"
  "${RC_MANIFEST}"
  "${READINESS}"
)
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" generate \
  --base-dir "${STAGE}/public" --output "${CHECKSUMS}" \
  "${PUBLIC_INVENTORY[@]}"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" verify \
  --checksums "${CHECKSUMS}" --base-dir "${STAGE}/public" --require-complete
"${REPO_ROOT}/ReleaseCandidate/scripts/scan_release_candidate.sh" --public "${STAGE}/public"
/usr/bin/env python3 "${SCRIPT_DIR}/scan_release_logs.py" "${STAGE}/public"

/bin/mkdir -p "${OUTPUT_ROOT}"
[[ -d "${OUTPUT_ROOT}" && ! -L "${OUTPUT_ROOT}" ]] || fail "output root is unsafe"
PENDING="$(/usr/bin/mktemp -d "${OUTPUT_ROOT}/.${RELEASE_ID}.XXXXXX")"
/usr/bin/ditto "${STAGE}/public" "${PENDING}/public"
/usr/bin/ditto "${STAGE}/private" "${PENDING}/private"
/usr/bin/find -P "${PENDING}/public" -type f -exec /bin/chmod 0444 {} +
/usr/bin/find -P "${PENDING}/public" -type d -exec /bin/chmod 0555 {} +
/usr/bin/find -P "${PENDING}/private" -type f -exec /bin/chmod 0400 {} +
/usr/bin/find -P "${PENDING}/private" -type d -exec /bin/chmod 0500 {} +
/bin/chmod 0500 "${PENDING}"
/usr/bin/env python3 "${SCRIPT_DIR}/atomic_publish_directory.py" "${PENDING}" "${FINAL_OUTPUT}"

printf '\nRelease engineering pipeline completed locally: %s\n' "${FINAL_OUTPUT}"
printf 'No artifact was uploaded or published. Public and private outputs remain separated for review.\n'
