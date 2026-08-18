#!/bin/bash
set -euo pipefail

BINARY="${1:-}"
LOAD_ADDRESS="${2:-}"
ADDRESS="${3:-}"

if [[ "$(uname -s)" != "Darwin" || ! -f "${BINARY}" || -L "${BINARY}" || ! "${LOAD_ADDRESS}" =~ ^0x[0-9A-Fa-f]+$ || ! "${ADDRESS}" =~ ^0x[0-9A-Fa-f]+$ ]]; then
  printf 'Usage on macOS: %s /path/to/binary 0xLOAD_ADDRESS 0xCRASH_ADDRESS\n' "$0" >&2
  exit 1
fi

ARCHS="$(/usr/bin/lipo -archs "${BINARY}")"
[[ "${ARCHS}" == "arm64" ]] || {
  printf 'error: expected thin arm64 binary, got %s\n' "${ARCHS}" >&2
  exit 1
}
/usr/bin/atos -arch arm64 -o "${BINARY}" -l "${LOAD_ADDRESS}" "${ADDRESS}"
