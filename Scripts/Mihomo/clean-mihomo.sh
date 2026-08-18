#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

/bin/rm -rf \
  "${PROJECT_ROOT}/Vendor/Mihomo/cache" \
  "${PROJECT_ROOT}/Vendor/Mihomo/bin"

printf 'Removed generated Mihomo cache and binary.\n'
printf 'Kept manifest, LICENSE and NOTICE.\n'
