#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
PACK_ROOT="${PROJECT_ROOT}/Docs/V1/Vela-v0.3-Privileged-TUN-Codex-Pack"
MANIFEST="${PACK_ROOT}/manifest.json"
FIXTURES="${PACK_ROOT}/fixtures"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == "0" ]] || fail "Usage: $0"
[[ -f "${MANIFEST}" && ! -L "${MANIFEST}" ]] || fail "Missing regular pack manifest: ${MANIFEST}"
[[ -d "${FIXTURES}" && ! -L "${FIXTURES}" ]] || fail "Missing fixture directory: ${FIXTURES}"
[[ -f "${SCRIPT_DIR}/validate-fixtures.rb" && ! -L "${SCRIPT_DIR}/validate-fixtures.rb" ]] || \
  fail "Missing fixture validator"

/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby -rjson -e '
  value = JSON.parse(File.binread(ARGV.fetch(0)), create_additions: false)
  abort "manifest root is not an object" unless value.is_a?(Hash)
  abort "manifest name drifted" unless value["name"] == "Vela V0.3 Privileged TUN Codex Pack"
  required_features = [
    "SMAppService LaunchDaemon",
    "authenticated NSXPC",
    "privileged Mihomo backend",
    "macOS TUN",
    "transactional backend switching",
    "lease and crash recovery",
    "signing and notarization"
  ]
  abort "manifest features drifted" unless value["features"] == required_features
  required_exclusions = [
    "Intel",
    "Universal Binary",
    "Rosetta",
    "Network Extension",
    "Kill Switch",
    "app split tunneling",
    "runtime Mihomo update",
    "arbitrary privileged shell"
  ]
  abort "manifest exclusions drifted" unless value["excluded"] == required_exclusions
' "${MANIFEST}" || fail "Pack manifest contract is invalid"

manifest_value() {
  /usr/bin/plutil -extract "$1" raw -o - "${MANIFEST}"
}

[[ "$(manifest_value schemaVersion)" == "1" ]] || fail "Pack schema version is not 1"
[[ "$(manifest_value target.app)" == "Vela" ]] || fail "Pack target app drifted"
[[ "$(manifest_value target.minimumMacOS)" == "15.0" ]] || fail "Minimum macOS drifted"
[[ "$(manifest_value target.architecture.0)" == "arm64" ]] || fail "Architecture is not arm64"
if /usr/bin/plutil -extract target.architecture.1 raw -o - "${MANIFEST}" >/dev/null 2>&1; then
  fail "Pack target contains more than one architecture"
fi
[[ "$(manifest_value target.mihomo)" == "v1.19.28" ]] || fail "Mihomo version is not pinned"
[[ "$(manifest_value target.distribution)" == "Developer ID" ]] || fail "Distribution target drifted"

/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby \
  -c "${SCRIPT_DIR}/validate-fixtures.rb" >/dev/null
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby \
  "${SCRIPT_DIR}/validate-fixtures.rb" "${FIXTURES}"

printf 'Privileged pack manifest validation passed:\n'
printf '  Minimum macOS: %s\n' "$(manifest_value target.minimumMacOS)"
printf '  Architecture:  %s\n' "$(manifest_value target.architecture.0)"
printf '  Mihomo:        %s\n' "$(manifest_value target.mihomo)"
printf '  Distribution:  %s\n' "$(manifest_value target.distribution)"
