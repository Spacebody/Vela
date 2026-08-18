#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

MODE="source"
if [[ "${1:-}" == "--source" || "${1:-}" == "--public" ]]; then
  MODE="${1#--}"
  shift
fi
[[ "$#" -gt 0 ]] || set -- .

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

common_patterns=(
  'REPLACE_WITH_REAL_TEAM'
  '__PIN_FULL_SHA__'
  'BEGIN PRIVATE KEY'
  'BEGIN OPENSSH PRIVATE KEY'
  'Authorization: Bearer'
  'github_pat_'
  'ghp_'
)
public_patterns=(
  'FaultInjectionPoint'
  'VELA_TEST_FAULT_PLAN'
  'VELA_RUN_DESTRUCTIVE_BETA_TESTS'
  '/Users/'
  '/private/var/folders/'
  'login.keychain'
)

for root in "$@"; do
  [[ -e "${root}" && ! -L "${root}" ]] || fail "scan root is missing or unsafe: ${root}"
  if [[ "${MODE}" == "public" ]] && /usr/bin/find -P "${root}" -type l -print -quit | /usr/bin/grep -q .; then
    fail "public RC output contains a symlink: ${root}"
  fi
done

scan_pattern() {
  local pattern="$1"
  shift
  if /usr/bin/grep -R -I -n \
    --exclude-dir=.git \
    --exclude-dir=Docs \
    --exclude-dir=tests \
    --exclude-dir=templates \
    --exclude='*.pyc' \
    --exclude='scan_release_candidate.sh' \
    --exclude='_common.py' \
    --exclude='validate_contract_freeze.py' \
    -- "${pattern}" "$@"; then
    fail "release candidate contains forbidden pattern: ${pattern}"
  fi
}

for pattern in "${common_patterns[@]}"; do
  scan_pattern "${pattern}" "$@"
done
if [[ "${MODE}" == "public" ]]; then
  for pattern in "${public_patterns[@]}"; do
    scan_pattern "${pattern}" "$@"
  done
fi

printf 'Release Candidate %s scan passed.\n' "${MODE}"
