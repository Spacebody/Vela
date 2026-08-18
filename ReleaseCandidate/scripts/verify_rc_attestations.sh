#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
MANIFEST=""
ARTIFACTS=""
SUBJECT_CHECKSUMS=""
OUTPUT=""
BUNDLE=""
BUNDLE_OUTPUT=""
TRUSTED_ROOT=""
TRUSTED_ROOT_OUTPUT=""
EXPECTED_BUNDLE_SHA256=""
EXPECTED_TRUSTED_ROOT_SHA256=""
VERIFY_ONLY=0

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --artifacts-dir) ARTIFACTS="${2:-}"; shift 2 ;;
    --subject-checksums) SUBJECT_CHECKSUMS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --bundle) BUNDLE="${2:-}"; shift 2 ;;
    --bundle-output) BUNDLE_OUTPUT="${2:-}"; shift 2 ;;
    --trusted-root) TRUSTED_ROOT="${2:-}"; shift 2 ;;
    --trusted-root-output) TRUSTED_ROOT_OUTPUT="${2:-}"; shift 2 ;;
    --expected-bundle-sha256) EXPECTED_BUNDLE_SHA256="${2:-}"; shift 2 ;;
    --expected-trusted-root-sha256) EXPECTED_TRUSTED_ROOT_SHA256="${2:-}"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -f "${MANIFEST}" && ! -L "${MANIFEST}" ]] || fail "--manifest is required"
[[ -d "${ARTIFACTS}" && ! -L "${ARTIFACTS}" ]] || fail "--artifacts-dir is required"
[[ -f "${SUBJECT_CHECKSUMS}" && ! -L "${SUBJECT_CHECKSUMS}" ]] || \
  fail "--subject-checksums is required"

if [[ -n "${EXPECTED_BUNDLE_SHA256}" ]]; then
  [[ "${EXPECTED_BUNDLE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
    fail "--expected-bundle-sha256 must be a lowercase SHA-256"
  [[ -n "${BUNDLE}" ]] || fail "--expected-bundle-sha256 requires --bundle"
fi
if [[ -n "${EXPECTED_TRUSTED_ROOT_SHA256}" ]]; then
  [[ "${EXPECTED_TRUSTED_ROOT_SHA256}" =~ ^[0-9a-f]{64}$ ]] || \
    fail "--expected-trusted-root-sha256 must be a lowercase SHA-256"
  [[ -n "${TRUSTED_ROOT}" ]] || \
    fail "--expected-trusted-root-sha256 requires --trusted-root"
fi

if [[ "${VERIFY_ONLY}" == "1" ]]; then
  [[ -z "${OUTPUT}" && -z "${BUNDLE_OUTPUT}" && -z "${TRUSTED_ROOT_OUTPUT}" ]] || \
    fail "--verify-only cannot create an output, bundle, or trusted root"
  [[ -f "${BUNDLE}" && ! -L "${BUNDLE}" ]] || \
    fail "--verify-only requires a regular offline --bundle"
  [[ -f "${TRUSTED_ROOT}" && ! -L "${TRUSTED_ROOT}" ]] || \
    fail "--verify-only requires a regular offline --trusted-root"
else
  [[ -n "${OUTPUT}" && ! -e "${OUTPUT}" && ! -L "${OUTPUT}" ]] || \
    fail "--output must be a new immutable path"
  if [[ -z "${BUNDLE}" ]]; then
    [[ -z "${TRUSTED_ROOT}" ]] || \
      fail "online verification creates its own trusted root; do not pass --trusted-root"
    [[ -n "${BUNDLE_OUTPUT}" && ! -e "${BUNDLE_OUTPUT}" && ! -L "${BUNDLE_OUTPUT}" ]] || \
      fail "online verification requires a new immutable --bundle-output"
    [[ -n "${TRUSTED_ROOT_OUTPUT}" && ! -e "${TRUSTED_ROOT_OUTPUT}" && ! -L "${TRUSTED_ROOT_OUTPUT}" ]] || \
      fail "online verification requires a new immutable --trusted-root-output"
  else
    [[ -z "${BUNDLE_OUTPUT}" && -z "${TRUSTED_ROOT_OUTPUT}" ]] || \
      fail "offline verification cannot create a bundle or trusted root"
    [[ -f "${TRUSTED_ROOT}" && ! -L "${TRUSTED_ROOT}" ]] || \
      fail "offline verification requires a regular --trusted-root"
  fi
fi
if [[ -n "${BUNDLE}" ]]; then
  [[ -f "${BUNDLE}" && ! -L "${BUNDLE}" ]] || fail "--bundle must be a regular file"
fi

if [[ -n "${BUNDLE}" ]]; then
  PROTECTED_PATHS=("${BUNDLE}" "${TRUSTED_ROOT}")
else
  PROTECTED_PATHS=("${BUNDLE_OUTPUT}" "${TRUSTED_ROOT_OUTPUT}")
fi
if [[ -n "${OUTPUT}" ]]; then
  PROTECTED_PATHS+=("${OUTPUT}")
fi
INFERRED_EVIDENCE_ROOT="$(/usr/bin/python3 -c \
  'import os,sys; from pathlib import Path; print(Path(os.path.abspath(sys.argv[1])).parent.parent)' \
  "${PROTECTED_PATHS[0]}")"
PRIVATE_PATH_ARGS=()
for protected_path in "${PROTECTED_PATHS[@]}"; do
  PRIVATE_PATH_ARGS+=(--direct-file "${protected_path}")
done
/usr/bin/python3 "${SCRIPT_DIR}/validate_private_evidence_root.py" \
  "${INFERRED_EVIDENCE_ROOT}" "${PRIVATE_PATH_ARGS[@]}" >/dev/null

GH_COMMAND="$(command -v gh || true)"
[[ -n "${GH_COMMAND}" ]] || fail "GitHub CLI is required"
GH_BIN="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${GH_COMMAND}")"
/usr/bin/python3 -c \
  'import os,stat,sys; p=sys.argv[1]; s=os.stat(p); raise SystemExit(0 if stat.S_ISREG(s.st_mode) and os.access(p, os.X_OK) and not (s.st_mode & 0o022) else 1)' \
  "${GH_BIN}" || fail "GitHub CLI must resolve to a non-writable regular executable"

WORK="$(/usr/bin/mktemp -d "/tmp/vela-rc-attestation.XXXXXX")"
/bin/chmod 0700 "${WORK}"
trap '/bin/rm -rf "${WORK}"' EXIT
ISOLATED_HOME="${WORK}/home"
ISOLATED_CONFIG="${WORK}/gh-config"
ISOLATED_XDG="${WORK}/xdg-config"
ISOLATED_TMP="${WORK}/tmp"
/bin/mkdir -m 0700 "${ISOLATED_HOME}" "${ISOLATED_CONFIG}" "${ISOLATED_XDG}" "${ISOLATED_TMP}"

CLEAN_ENV=(
  /usr/bin/env -i
  "HOME=${ISOLATED_HOME}"
  "GH_CONFIG_DIR=${ISOLATED_CONFIG}"
  "XDG_CONFIG_HOME=${ISOLATED_XDG}"
  "TMPDIR=${ISOLATED_TMP}"
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  "GH_PROMPT_DISABLED=1"
  "GH_NO_UPDATE_NOTIFIER=1"
  "NO_COLOR=1"
)
TOKEN_FREE_ENV=("${CLEAN_ENV[@]}")
ONLINE_ENV=("${CLEAN_ENV[@]}")
ONLINE_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -n "${ONLINE_TOKEN}" ]]; then
  ONLINE_ENV+=("GH_TOKEN=${ONLINE_TOKEN}")
fi

GH_VERSION_OUTPUT="$("${CLEAN_ENV[@]}" "${GH_BIN}" version 2>&1)" || \
  fail "unable to determine GitHub CLI version"
GH_VERSION="$(/usr/bin/python3 -c \
  'import re,sys; m=re.search(r"(?m)^gh version ([0-9]+\.[0-9]+\.[0-9]+)(?: |$)", sys.stdin.read()); print(m.group(1) if m else "")' \
  <<<"${GH_VERSION_OUTPUT}")"
[[ -n "${GH_VERSION}" ]] || fail "unable to parse GitHub CLI version"
/usr/bin/python3 -c \
  'import sys; value=tuple(map(int,sys.argv[1].split("."))); raise SystemExit(0 if value >= (2,93,0) else 1)' \
  "${GH_VERSION}" || fail "GitHub CLI 2.93.0 or newer is required for safe attestation verification"

SNAPSHOTS="${WORK}/subjects"
INVENTORY="${WORK}/inventory.json"
BUNDLE_SNAPSHOT="${WORK}/attestation-bundle.snapshot.jsonl"
TRUSTED_ROOT_SNAPSHOT="${WORK}/trusted-root.snapshot.jsonl"

/usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" create \
  --manifest "${MANIFEST}" \
  --artifacts-dir "${ARTIFACTS}" \
  --subject-checksums "${SUBJECT_CHECKSUMS}" \
  --snapshot-dir "${SNAPSHOTS}" \
  --inventory "${INVENTORY}"

SNAPSHOT_MANIFEST="$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["manifestSnapshot"])' \
  "${INVENTORY}")"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_release_candidate.py" "${SNAPSHOT_MANIFEST}" \
  --stage structural --verify-files --artifacts-dir "${SNAPSHOTS}"
COMMIT="$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["source"]["commit"])' \
  "${SNAPSHOT_MANIFEST}")"
TAG="$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["source"]["tag"])' \
  "${SNAPSHOT_MANIFEST}")"
DMG_NAME="$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["artifacts"]["dmg"]["filename"])' \
  "${SNAPSHOT_MANIFEST}")"
CHECKSUM_SNAPSHOT="$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["subjectChecksums"]["snapshotPath"])' \
  "${INVENTORY}")"

SUBJECT_NAMES=()
while IFS= read -r name; do
  SUBJECT_NAMES+=("${name}")
done < <(/usr/bin/python3 -c \
  'import json,sys; [print(item["filename"]) for item in json.load(open(sys.argv[1], encoding="utf-8"))["subjects"]]' \
  "${INVENTORY}")

VERIFY_RESULTS=()

assert_verified_result() {
  local path="$1"
  local label="$2"
  /usr/bin/python3 -c \
    'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); raise SystemExit(0 if isinstance(value,list) and value else 1)' \
    "${path}" || fail "GitHub returned no verified ${label} attestation"
}

verify_subject() {
  local subject="$1"
  local predicate="$2"
  local output="$3"
  local bundle_path="$4"
  local label="$5"
  local args=(
    attestation verify "${subject}"
    --repo Spacebody/Vela
    --hostname github.com
    --signer-workflow github.com/Spacebody/Vela/.github/workflows/release.yml
    --signer-digest "${COMMIT}"
    --source-digest "${COMMIT}"
    --source-ref "refs/tags/${TAG}"
    --predicate-type "${predicate}"
    --custom-trusted-root "${TRUSTED_ROOT_SNAPSHOT}"
    --format json
  )
  if [[ -n "${bundle_path}" ]]; then
    args+=(--bundle "${bundle_path}")
    "${TOKEN_FREE_ENV[@]}" "${GH_BIN}" "${args[@]}" >"${output}"
  else
    "${ONLINE_ENV[@]}" "${GH_BIN}" "${args[@]}" >"${output}"
  fi
  assert_verified_result "${output}" "${label}"
  VERIFY_RESULTS+=("${output}")
}

verify_all() {
  local prefix="$1"
  local bundle_path="$2"
  local index=0
  VERIFY_RESULTS=()
  /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" check --inventory "${INVENTORY}"
  verify_subject \
    "${CHECKSUM_SNAPSHOT}" \
    "https://slsa.dev/provenance/v1" \
    "${WORK}/${prefix}-checksum-inventory.json" \
    "${bundle_path}" \
    "checksum-inventory provenance"
  /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" check --inventory "${INVENTORY}"
  for name in "${SUBJECT_NAMES[@]}"; do
    subject="${SNAPSHOTS}/${name}"
    # --signer-digest pins the workflow revision; --source-digest/ref bind the
    # attested source commit and exact candidate tag independently.
    verify_subject \
      "${subject}" \
      "https://slsa.dev/provenance/v1" \
      "${WORK}/${prefix}-provenance-${index}.json" \
      "${bundle_path}" \
      "provenance"
    if [[ "${name}" == "${DMG_NAME}" ]]; then
      verify_subject \
        "${subject}" \
        "https://spdx.dev/Document/v2.3" \
        "${WORK}/${prefix}-sbom-${index}.json" \
        "${bundle_path}" \
        "SPDX SBOM"
    fi
    /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" check \
      --inventory "${INVENTORY}" --subject "${name}"
    index=$((index + 1))
  done
  [[ "${index}" -gt 0 ]] || fail "subject checksum inventory is empty"
  /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" check --inventory "${INVENTORY}"
}

snapshot_bound_file() {
  local input="$1"
  local output="$2"
  local kind="$3"
  local expected="$4"
  local args=(snapshot-file --input "${input}" --output "${output}" --kind "${kind}")
  if [[ -n "${expected}" ]]; then
    args+=(--expected-sha256 "${expected}")
  fi
  /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" "${args[@]}"
}

recheck_bound_file() {
  local input="$1"
  local snapshot="$2"
  local kind="$3"
  local expected="$4"
  local args=(check-file --input "${input}" --snapshot "${snapshot}" --kind "${kind}")
  if [[ -n "${expected}" ]]; then
    args+=(--expected-sha256 "${expected}")
  fi
  /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" "${args[@]}"
}

if [[ -n "${BUNDLE}" ]]; then
  snapshot_bound_file "${BUNDLE}" "${BUNDLE_SNAPSHOT}" bundle "${EXPECTED_BUNDLE_SHA256}"
  snapshot_bound_file \
    "${TRUSTED_ROOT}" "${TRUSTED_ROOT_SNAPSHOT}" trusted-root \
    "${EXPECTED_TRUSTED_ROOT_SHA256}"
  verify_all offline "${BUNDLE_SNAPSHOT}"
  BUNDLE_FOR_REPORT="${BUNDLE}"
  TRUSTED_ROOT_FOR_REPORT="${TRUSTED_ROOT}"
else
  RAW_TRUSTED_ROOT="${WORK}/trusted-root.download.jsonl"
  "${TOKEN_FREE_ENV[@]}" "${GH_BIN}" attestation trusted-root --hostname github.com \
    >"${RAW_TRUSTED_ROOT}" || fail "unable to acquire GitHub attestation trusted root"
  /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" seal-file \
    --input "${RAW_TRUSTED_ROOT}" --output "${TRUSTED_ROOT_OUTPUT}" --kind trusted-root
  snapshot_bound_file \
    "${TRUSTED_ROOT_OUTPUT}" "${TRUSTED_ROOT_SNAPSHOT}" trusted-root ""

  verify_all online ""
  ONLINE_RESULTS=("${VERIFY_RESULTS[@]}")
  BUNDLE_ARGS=()
  for result in "${ONLINE_RESULTS[@]}"; do
    BUNDLE_ARGS+=(--verified-result "${result}")
  done
  /usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" bundle \
    "${BUNDLE_ARGS[@]}" --output "${BUNDLE_OUTPUT}"
  snapshot_bound_file "${BUNDLE_OUTPUT}" "${BUNDLE_SNAPSHOT}" bundle ""
  # The report is issued only after every frozen byte reverifies using only the
  # immutable bundle and explicit trusted root snapshots, with no token/config.
  verify_all offline "${BUNDLE_SNAPSHOT}"
  BUNDLE_FOR_REPORT="${BUNDLE_OUTPUT}"
  TRUSTED_ROOT_FOR_REPORT="${TRUSTED_ROOT_OUTPUT}"
fi

recheck_bound_file \
  "${BUNDLE_FOR_REPORT}" "${BUNDLE_SNAPSHOT}" bundle "${EXPECTED_BUNDLE_SHA256}"
recheck_bound_file \
  "${TRUSTED_ROOT_FOR_REPORT}" "${TRUSTED_ROOT_SNAPSHOT}" trusted-root \
  "${EXPECTED_TRUSTED_ROOT_SHA256}"
/usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" check --inventory "${INVENTORY}"

if [[ "${VERIFY_ONLY}" == "1" ]]; then
  printf 'Offline GitHub attestation bundle verification passed against the bound custom trusted root for every checksummed RC subject and the DMG SPDX attestation.\n'
  exit 0
fi

/usr/bin/env python3 "${SCRIPT_DIR}/attestation_snapshot.py" report \
  --inventory "${INVENTORY}" --commit "${COMMIT}" --tag "${TAG}" \
  --bundle "${BUNDLE_SNAPSHOT}" \
  --bundle-name "$(/usr/bin/basename "${BUNDLE_FOR_REPORT}")" \
  --trusted-root "${TRUSTED_ROOT_SNAPSHOT}" \
  --trusted-root-name "$(/usr/bin/basename "${TRUSTED_ROOT_FOR_REPORT}")" \
  --output "${OUTPUT}"

printf 'Cryptographic verification and true offline replay passed for every checksummed RC subject against the exact retained bundle and custom trusted root; final accountable Go/No-Go remains separate.\n'
