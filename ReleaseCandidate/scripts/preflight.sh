#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
CONFIG_ROOT="${REPO_ROOT}/ReleaseCandidate/config"
VERSION=""
CANDIDATE_VERSION=""
BUILD=""
TAG=""
CHANNEL=""
AUDIT_EVIDENCE=""
GO_NO_GO_EVIDENCE=""
EVIDENCE_DIR=""
MIGRATION_EVIDENCE="${CONFIG_ROOT}/migration-guarantee.json"
PUBLISHED_BUILDS="${CONFIG_ROOT}/published-builds.json"
SUPPORT_MATRIX="${CONFIG_ROOT}/support-matrix.json"
INSTALLATION_MATRIX=""
PHASE=""
EXPECT_RESERVED=0
CANDIDATE_STAGE_PATH=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --candidate-version) CANDIDATE_VERSION="${2:-}"; shift 2 ;;
    --build) BUILD="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --audit) AUDIT_EVIDENCE="${2:-}"; shift 2 ;;
    --go-no-go) GO_NO_GO_EVIDENCE="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --migration) MIGRATION_EVIDENCE="${2:-}"; shift 2 ;;
    --published-builds) PUBLISHED_BUILDS="${2:-}"; shift 2 ;;
    --support-matrix) SUPPORT_MATRIX="${2:-}"; shift 2 ;;
    --installation-matrix) INSTALLATION_MATRIX="${2:-}"; shift 2 ;;
    --candidate-stage)
      [[ -z "${PHASE}" ]] || fail "release phase may be specified only once"
      PHASE="candidate-stage"
      shift
      ;;
    --promotion)
      [[ -z "${PHASE}" ]] || fail "release phase may be specified only once"
      PHASE="promotion"
      shift
      ;;
    --expect-reserved) EXPECT_RESERVED=1; shift ;;
    --candidate-stage-path) CANDIDATE_STAGE_PATH="${2:-}"; shift 2 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

PYTHON=/usr/bin/python3

structural() {
  "${PYTHON}" "${SCRIPT_DIR}/validate_migration_guarantee.py" \
    "${CONFIG_ROOT}/migration-guarantee.json" --allow-pending
  "${PYTHON}" "${SCRIPT_DIR}/validate_installation_matrix.py" \
    "${CONFIG_ROOT}/installation-matrix.json" --allow-pending \
    --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json"
  "${PYTHON}" "${SCRIPT_DIR}/validate_audit_closure.py" \
    "${CONFIG_ROOT}/audit-closure.json" --allow-pending
  "${PYTHON}" "${SCRIPT_DIR}/validate_known_limitations.py" \
    "${CONFIG_ROOT}/known-limitations.json" --version 1.0.0
  "${PYTHON}" "${SCRIPT_DIR}/validate_support_matrix.py" \
    "${CONFIG_ROOT}/support-matrix.json"
  "${PYTHON}" "${SCRIPT_DIR}/validate_go_no_go.py" \
    "${CONFIG_ROOT}/go-no-go.json" --expect noGo
  if [[ -f "${CONFIG_ROOT}/feature-freeze.json" ]]; then
    "${PYTHON}" "${SCRIPT_DIR}/validate_feature_freeze.py" "${CONFIG_ROOT}/feature-freeze.json"
  fi
  if [[ -f "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json" ]]; then
    "${PYTHON}" "${SCRIPT_DIR}/validate_contract_freeze.py" \
      "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json" \
      --app-intent-registry "${REPO_ROOT}/Contracts/v1/app-intent-registry.json"
    "${PYTHON}" "${SCRIPT_DIR}/validate_known_limitations.py" \
      "${CONFIG_ROOT}/known-limitations.json" --version 1.0.0 \
      --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json"
    "${PYTHON}" "${SCRIPT_DIR}/validate_support_matrix.py" \
      "${CONFIG_ROOT}/support-matrix.json" \
      --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json"
  fi
  "${SCRIPT_DIR}/scan_release_candidate.sh" --source "${REPO_ROOT}/ReleaseCandidate"
  printf 'Development structural preflight passed. Release decision remains NO-GO.\n'
}

if [[ -z "${VERSION}${CANDIDATE_VERSION}${BUILD}${TAG}" ]]; then
  structural
  exit 0
fi
[[ -n "${VERSION}" && -n "${CANDIDATE_VERSION}" && -n "${BUILD}" && -n "${TAG}" ]] || \
  fail "release preflight requires --version, --candidate-version, --build, and --tag together"
[[ "${PHASE}" == "candidate-stage" || "${PHASE}" == "promotion" ]] || \
  fail "release preflight requires exactly one of --candidate-stage or --promotion"
[[ -n "${AUDIT_EVIDENCE}" && -n "${GO_NO_GO_EVIDENCE}" && -n "${INSTALLATION_MATRIX}" ]] || \
  fail "external candidate evidence required: pass --audit, --go-no-go, and --installation-matrix files created after the candidate tag"
[[ -n "${EVIDENCE_DIR}" ]] || \
  fail "external candidate evidence required: pass the protected --evidence-dir"
if [[ -z "${CHANNEL}" ]]; then
  if [[ "${CANDIDATE_VERSION}" =~ -rc\.[1-9][0-9]*$ ]]; then
    CHANNEL="rc"
  else
    CHANNEL="stable"
  fi
fi
[[ "${CHANNEL}" == "rc" || "${CHANNEL}" == "stable" ]] || fail "--channel must be rc or stable"

EVIDENCE_DIR="$("${PYTHON}" "${SCRIPT_DIR}/validate_private_evidence_root.py" "${EVIDENCE_DIR}")"
"${PYTHON}" - "${REPO_ROOT}" "${EVIDENCE_DIR}" "${AUDIT_EVIDENCE}" "${GO_NO_GO_EVIDENCE}" "${INSTALLATION_MATRIX}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
evidence = Path(sys.argv[2])
if not evidence.is_dir() or evidence.is_symlink():
    raise SystemExit("error: external evidence directory must be a regular non-symlink directory")
evidence = evidence.resolve()
try:
    evidence.relative_to(root)
except ValueError:
    pass
else:
    raise SystemExit("error: external evidence directory must be outside the tagged repository")
for label, raw in (
    ("audit", sys.argv[3]),
    ("Go/No-Go", sys.argv[4]),
    ("installation matrix", sys.argv[5]),
):
    path = Path(raw)
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"error: external {label} evidence must be a regular non-symlink file")
    try:
        path.resolve().relative_to(evidence)
    except ValueError:
        raise SystemExit(f"error: external {label} evidence must be inside --evidence-dir")
PY
[[ -z "$(/usr/bin/git -C "${REPO_ROOT}" status --porcelain)" ]] || fail "release preflight requires clean source"
HEAD="$(/usr/bin/git -C "${REPO_ROOT}" rev-parse HEAD)"
TAG_REF="refs/tags/${TAG}"
/usr/bin/git -C "${REPO_ROOT}" show-ref --verify --quiet "${TAG_REF}" || fail "candidate tag is missing"
[[ "$(/usr/bin/git -C "${REPO_ROOT}" cat-file -t "${TAG_REF}")" == "tag" ]] || fail "candidate tag must be annotated"
[[ "$(/usr/bin/git -C "${REPO_ROOT}" rev-parse "${TAG_REF}^{commit}")" == "${HEAD}" ]] || fail "candidate tag does not point at HEAD"
/usr/bin/git -C "${REPO_ROOT}" verify-tag "${TAG_REF}" >/dev/null 2>&1 || fail "candidate tag signature verification failed"

SEMVER_ARGS=(
  --version "${CANDIDATE_VERSION}"
  --marketing-version "${VERSION}"
  --build "${BUILD}"
  --tag "${TAG}"
  --channel "${CHANNEL}"
  --published "${PUBLISHED_BUILDS}"
)
if [[ "${EXPECT_RESERVED}" == "1" ]]; then
  SEMVER_ARGS+=(--require-history --expect-reserved)
fi
"${PYTHON}" "${SCRIPT_DIR}/validate_semver_build.py" "${SEMVER_ARGS[@]}"
"${PYTHON}" "${SCRIPT_DIR}/validate_source_build_identity.py" \
  --repository-root "${REPO_ROOT}" --version "${VERSION}" --build "${BUILD}"
"${PYTHON}" "${SCRIPT_DIR}/validate_feature_freeze.py" "${CONFIG_ROOT}/feature-freeze.json"

WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vela-rc-contracts.XXXXXX")"
trap '/bin/rm -rf "${WORK}"' EXIT
"${PYTHON}" "${SCRIPT_DIR}/generate_project_contracts.py" \
  --repository-root "${REPO_ROOT}" --output-dir "${WORK}"
"${PYTHON}" "${SCRIPT_DIR}/compare_contract_freeze.py" \
  "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json" \
  "${WORK}/public-contract-freeze.json"
"${PYTHON}" "${SCRIPT_DIR}/validate_app_intent_registry.py" \
  "${REPO_ROOT}/Contracts/v1/app-intent-registry.json" \
  "${WORK}/app-intent-registry.json"
"${PYTHON}" "${SCRIPT_DIR}/generate_contract_hashes.py" \
  --contracts-dir "${REPO_ROOT}/Contracts/v1" \
  --output "${REPO_ROOT}/Contracts/v1/hashes.json" --verify

"${PYTHON}" "${SCRIPT_DIR}/validate_migration_guarantee.py" \
  "${MIGRATION_EVIDENCE}" --repository-root "${REPO_ROOT}" --verify-files
INSTALL_ARGS=(
  "${INSTALLATION_MATRIX}"
  --candidate-version "${CANDIDATE_VERSION}"
  --build "${BUILD}"
  --commit "${HEAD}"
  --evidence-root "${EVIDENCE_DIR}"
  --verify-files
  --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json"
)
if [[ "${PHASE}" == "candidate-stage" ]]; then
  INSTALL_ARGS+=(--candidate-stage)
else
  [[ -d "${CANDIDATE_STAGE_PATH}" && ! -L "${CANDIDATE_STAGE_PATH}" ]] || \
    fail "promotion requires --candidate-stage-path"
  "${PYTHON}" "${SCRIPT_DIR}/validate_candidate_stage_tree.py" "${CANDIDATE_STAGE_PATH}"
  INSTALL_ARGS+=(--artifacts-dir "${CANDIDATE_STAGE_PATH}/public")
  ARCHITECTURE_SHA256="$(/usr/bin/shasum -a 256 "${REPO_ROOT}/Hardening/config/architecture-freeze.json" | /usr/bin/awk '{print $1}')"
  "${PYTHON}" "${SCRIPT_DIR}/validate_candidate_stage_evidence.py" \
    "${CANDIDATE_STAGE_PATH}/private/candidate-stage-evidence.json" \
    --evidence-root "${CANDIDATE_STAGE_PATH}" --verify-files \
    --candidate-version "${CANDIDATE_VERSION}" --build "${BUILD}" \
    --tag "${TAG}" --commit "${HEAD}" \
    --architecture-sha256 "${ARCHITECTURE_SHA256}"
fi
"${PYTHON}" "${SCRIPT_DIR}/validate_installation_matrix.py" "${INSTALL_ARGS[@]}"
"${PYTHON}" "${SCRIPT_DIR}/validate_audit_closure.py" \
  "${AUDIT_EVIDENCE}" --repository-root "${REPO_ROOT}" \
  --evidence-root "${EVIDENCE_DIR}" --verify-files --expected-commit "${HEAD}"
"${PYTHON}" "${SCRIPT_DIR}/validate_known_limitations.py" \
  "${CONFIG_ROOT}/known-limitations.json" --version "${VERSION}" \
  --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json"
DECISION_ARGS=(
  "${GO_NO_GO_EVIDENCE}"
  --candidate-version "${CANDIDATE_VERSION}"
  --build "${BUILD}"
  --commit "${HEAD}"
  --repository-root "${REPO_ROOT}"
  --evidence-root "${EVIDENCE_DIR}"
  --verify-files
)
if [[ "${PHASE}" == "candidate-stage" ]]; then
  DECISION_ARGS+=(--candidate-stage)
else
  DECISION_ARGS+=(--pre-artifact)
fi
"${PYTHON}" "${SCRIPT_DIR}/validate_go_no_go.py" "${DECISION_ARGS[@]}"
"${PYTHON}" "${SCRIPT_DIR}/validate_support_matrix.py" \
  "${SUPPORT_MATRIX}" \
  --public-contract "${REPO_ROOT}/Contracts/v1/public-contract-freeze.json"
HARDENING_ARGS=(--repository-root "${REPO_ROOT}")
if [[ "${PHASE}" == "candidate-stage" ]]; then
  if [[ "${CHANNEL}" == "rc" ]]; then
    HARDENING_CHANNEL="publicBeta"
  else
    HARDENING_CHANNEL="stable"
  fi
  HARDENING_ARGS+=(--release-gate "${HARDENING_CHANNEL}" --release-phase candidate-stage)
fi
"${PYTHON}" "${REPO_ROOT}/Hardening/scripts/validate_hardening_config.py" "${HARDENING_ARGS[@]}"
"${SCRIPT_DIR}/scan_release_candidate.sh" --source \
  "${REPO_ROOT}/ReleaseCandidate" "${REPO_ROOT}/Contracts"

printf 'Protected %s %s preflight passed: %s (%s). No publication was authorized.\n' \
  "${PHASE}" "${CHANNEL}" "${CANDIDATE_VERSION}" "${BUILD}"
