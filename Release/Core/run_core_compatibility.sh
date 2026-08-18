#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
exec /usr/bin/env python3 "${SCRIPT_DIR}/CompatibilityLab/run_compatibility_lab.py" "$@"
