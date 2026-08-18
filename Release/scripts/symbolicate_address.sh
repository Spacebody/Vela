#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

DSYM=""
BINARY=""
ARCH="arm64"
LOAD_ADDRESS=""
ADDRESSES=()

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s --dsym App.dSYM --binary Vela --load-address 0x... --address 0x... [--address 0x...]\n' "$0" >&2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dsym) DSYM="${2:-}"; shift 2 ;;
    --binary) BINARY="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --load-address) LOAD_ADDRESS="${2:-}"; shift 2 ;;
    --address) ADDRESSES+=("${2:-}"); shift 2 ;;
    *) usage; fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -d "${DSYM}" && ! -L "${DSYM}" && "${DSYM}" == *.dSYM ]] || fail "--dsym must be a regular dSYM directory"
[[ -n "${BINARY}" && "${BINARY}" != */* ]] || fail "--binary must be a basename"
[[ "${ARCH}" == "arm64" ]] || fail "Vela V0.5 symbolication supports arm64 only"
[[ "${LOAD_ADDRESS}" =~ ^0x[0-9A-Fa-f]+$ ]] || fail "--load-address must be hexadecimal"
[[ "${#ADDRESSES[@]}" -gt 0 ]] || fail "at least one --address is required"
for address in "${ADDRESSES[@]}"; do
  [[ "${address}" =~ ^0x[0-9A-Fa-f]+$ ]] || fail "invalid address: ${address}"
done

DWARF="${DSYM}/Contents/Resources/DWARF/${BINARY}"
[[ -f "${DWARF}" && ! -L "${DWARF}" ]] || fail "DWARF binary not found: ${BINARY}"
/usr/bin/dwarfdump --uuid "${DWARF}" | /usr/bin/grep -Fq '(arm64)' || fail "dSYM does not contain an arm64 UUID"

printf 'dSYM UUIDs:\n'
/usr/bin/dwarfdump --uuid "${DWARF}"
printf '\nSymbolication:\n'
/usr/bin/atos -arch arm64 -o "${DWARF}" -l "${LOAD_ADDRESS}" "${ADDRESSES[@]}"
