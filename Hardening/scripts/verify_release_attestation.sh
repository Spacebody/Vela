#!/bin/bash
set -euo pipefail

ARTIFACT="${1:-}"
REPOSITORY="${2:-}"

if [[ -z "${ARTIFACT}" || -z "${REPOSITORY}" || ! -f "${ARTIFACT}" || -L "${ARTIFACT}" ]]; then
  printf 'Usage: %s /path/to/immutable-artifact owner/repository\n' "$0" >&2
  exit 1
fi
[[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  printf 'error: invalid repository name\n' >&2
  exit 1
}
command -v gh >/dev/null 2>&1 || {
  printf 'error: GitHub CLI is required\n' >&2
  exit 1
}
gh attestation verify "${ARTIFACT}" -R "${REPOSITORY}"
