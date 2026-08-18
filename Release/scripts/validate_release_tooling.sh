#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
SKIP_CONFIG=0

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "--skip-config" ]]; then
  SKIP_CONFIG=1
  shift
fi
[[ "$#" == "0" ]] || fail "Usage: $0 [--skip-config]"

if [[ "${SKIP_CONFIG}" == "0" ]]; then
  /usr/bin/env python3 "${SCRIPT_DIR}/validate_release_config.py" \
    --repository-root "${REPO_ROOT}" --config "${REPO_ROOT}/Release/config/release.json"
fi

for script in "${SCRIPT_DIR}"/*.sh; do
  [[ -f "${script}" && ! -L "${script}" ]] || continue
  /bin/bash -n "${script}"
done

for script in "${SCRIPT_DIR}"/*.py; do
  [[ -f "${script}" && ! -L "${script}" ]] || continue
  /usr/bin/python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), filename=sys.argv[1])' "${script}"
done

for script in "${REPO_ROOT}/Release/Core"/*.sh; do
  [[ -f "${script}" && ! -L "${script}" ]] || continue
  /bin/bash -n "${script}"
done

for script in "${REPO_ROOT}/Release/Core"/*.py; do
  [[ -f "${script}" && ! -L "${script}" ]] || continue
  /usr/bin/python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), filename=sys.argv[1])' "${script}"
done

/usr/bin/python3 -m unittest discover \
  -s "${REPO_ROOT}/Release/tests" \
  -p 'test_*.py'

/usr/bin/plutil -lint "${REPO_ROOT}/Release/config/ExportOptions.plist" >/dev/null
/usr/bin/env python3 "${SCRIPT_DIR}/validate_ci_workflows.py"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_v07_acceptance.py" --self-test
/usr/bin/python3 - "${REPO_ROOT}/Vela/Info.plist" "${REPO_ROOT}/Vela.xcodeproj/project.pbxproj" <<'PY'
import plistlib
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    info = plistlib.load(handle)
expected = {
    "VelaCoreCatalogURL": "$(VELA_CORE_CATALOG_URL)",
    "VelaCoreCatalogSignaturesURL": "$(VELA_CORE_CATALOG_SIGNATURES_URL)",
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"error: source Info.plist lacks Core Catalog build-setting binding: {key}")
project = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
for setting in ["VELA_CORE_CATALOG_URL", "VELA_CORE_CATALOG_SIGNATURES_URL"]:
    if project.count(f'{setting} = "";') != 2:
        raise SystemExit(
            f"error: Debug and Release must each default {setting} to an empty unconfigured value"
        )
PY
/usr/bin/python3 - "${REPO_ROOT}/Release/config" <<'PY'
import json
import pathlib
import sys

for path in pathlib.Path(sys.argv[1]).glob("*.json"):
    json.loads(path.read_text(encoding="utf-8"))
PY

/usr/bin/env python3 "${SCRIPT_DIR}/validate_release_notes.py" \
  "${REPO_ROOT}/Release/config/fixtures/release-notes-1.0.0-rc.1.md" \
  --candidate-version 1.0.0-rc.1 --production
/usr/bin/env python3 "${SCRIPT_DIR}/validate_release_notes.py" \
  "${REPO_ROOT}/Release/config/fixtures/release-notes-1.0.0.md" \
  --candidate-version 1.0.0 --production
/usr/bin/cmp -s \
  "${REPO_ROOT}/Release/config/release-notes-template.md" \
  "${REPO_ROOT}/ReleaseCandidate/templates/v1-release-notes-template.md" || \
  fail "V1 release-note templates diverged"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_release_notes.py" \
  "${REPO_ROOT}/Release/config/release-notes-template.md"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_appcast_policy.py" \
  "${REPO_ROOT}/Release/config/fixtures/appcast-signed-structure.xml" \
  --policy "${REPO_ROOT}/Release/config/appcast-policy.json" --fixture
if /usr/bin/env python3 "${SCRIPT_DIR}/verify_appcast_policy.py" \
  "${REPO_ROOT}/Docs/Vela-v0.5-Secure-Updates-Release-Codex-Pack/fixtures/appcast-invalid-http.xml" \
  --policy "${REPO_ROOT}/Release/config/appcast-policy.json" --fixture >/dev/null 2>&1; then
  fail "HTTP appcast fixture was unexpectedly accepted"
fi

TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="$(cd "${TEMP_ROOT}" && /bin/pwd -P)"
WORK="$(/usr/bin/mktemp -d "${TEMP_ROOT}/vela-release-tools.XXXXXX")"
cleanup() {
  local result=$?
  case "${WORK}" in
    "${TEMP_ROOT}"/vela-release-tools.*) /bin/rm -rf "${WORK}" ;;
    *) printf 'warning: refused to clean unexpected release-tool fixture path\n' >&2 ;;
  esac
  return "${result}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

SOURCE_DATE_EPOCH=1783987200 \
  /usr/bin/env python3 "${SCRIPT_DIR}/generate_documentation_manifest.py" \
    --repository-root "${REPO_ROOT}" --config "${REPO_ROOT}/Release/config/documentation.json" \
    --app-version 1.0.0 --app-build 2026071403 \
    --output "${WORK}/VelaDocumentationManifest-one.json"
SOURCE_DATE_EPOCH=1783987200 \
  /usr/bin/env python3 "${SCRIPT_DIR}/generate_documentation_manifest.py" \
    --repository-root "${REPO_ROOT}" --config "${REPO_ROOT}/Release/config/documentation.json" \
    --app-version 1.0.0 --app-build 2026071403 \
    --output "${WORK}/VelaDocumentationManifest-two.json"
/usr/bin/cmp -s "${WORK}/VelaDocumentationManifest-one.json" \
  "${WORK}/VelaDocumentationManifest-two.json" \
  || fail "documentation manifest generation is not deterministic"
SOURCE_DATE_EPOCH=1783987200 \
  /usr/bin/env python3 "${SCRIPT_DIR}/generate_documentation_manifest.py" \
    --repository-root "${REPO_ROOT}" --config "${REPO_ROOT}/Release/config/documentation.json" \
    --app-version 1.0.0 --app-build 2026071403 \
    --output "${WORK}/VelaDocumentationManifest-one.json" --verify

printf 'alpha\n' >"${WORK}/alpha.bin"
printf 'beta\n' >"${WORK}/beta.bin"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" generate \
  --output "${WORK}/checksums.txt" "${WORK}/alpha.bin" "${WORK}/beta.bin"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" verify \
  --checksums "${WORK}/checksums.txt" --base-dir "${WORK}"
if /usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" generate \
  --output "${WORK}/checksums.txt" "${WORK}/alpha.bin" >/dev/null 2>&1; then
  fail "immutable checksum output was unexpectedly overwritten"
fi
/bin/mkdir -p "${WORK}/complete/release-notes"
printf 'candidate notes\n' >"${WORK}/complete/release-notes/1.0.0-rc.1.md"
printf 'candidate artifact\n' >"${WORK}/complete/artifact.bin"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" generate \
  --base-dir "${WORK}/complete" \
  --output "${WORK}/complete/checksums.txt" \
  "${WORK}/complete/release-notes/1.0.0-rc.1.md" \
  "${WORK}/complete/artifact.bin"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" verify \
  --checksums "${WORK}/complete/checksums.txt" \
  --base-dir "${WORK}/complete" --require-complete
printf 'not inventoried\n' >"${WORK}/complete/unhashed.txt"
if /usr/bin/env python3 "${SCRIPT_DIR}/generate_checksums.py" verify \
  --checksums "${WORK}/complete/checksums.txt" \
  --base-dir "${WORK}/complete" --require-complete >/dev/null 2>&1; then
  fail "incomplete recursive checksum inventory was unexpectedly accepted"
fi
/bin/rm "${WORK}/complete/unhashed.txt"

printf 'release validation log\n' >"${WORK}/safe.log"
/usr/bin/env python3 "${SCRIPT_DIR}/scan_release_logs.py" "${WORK}"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' >"${WORK}/unsafe.log"
if /usr/bin/env python3 "${SCRIPT_DIR}/scan_release_logs.py" "${WORK}" >/dev/null 2>&1; then
  fail "private-key fixture was unexpectedly accepted"
fi
/bin/rm "${WORK}/unsafe.log"

/usr/bin/env python3 "${SCRIPT_DIR}/generate_release_manifest.py" \
  --repository-root "${REPO_ROOT}" --config "${REPO_ROOT}/Release/config/release.json" \
  --kind bundle --version 1.0.0 --build 2026071403 --channel stable \
  --tag v1.0.0 --output "${WORK}/VelaReleaseManifest.json" --allow-dirty
/usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
  "${WORK}/VelaReleaseManifest.json" --kind bundle
/usr/bin/python3 - "${WORK}/VelaReleaseManifest.json" "${WORK}/invalid-bundle-manifest.json" <<'PY'
import json
import pathlib
import sys

source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if "architectureFreezeSHA256" in source.get("source", {}):
    raise SystemExit(
        "error: bundled manifest unexpectedly contains external architecture binding"
    )
source["manifestKind"] = "bundle"
pathlib.Path(sys.argv[2]).write_text(json.dumps(source), encoding="utf-8")
PY
if /usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
  "${WORK}/invalid-bundle-manifest.json" --kind bundle >/dev/null 2>&1; then
  fail "bundle manifest with a BuildManifestReader-unknown field was unexpectedly accepted"
fi

/bin/mkdir -p "${WORK}/embed-build"
CONFIGURATION=Release \
VELA_RELEASE_MANIFEST_REQUIRED=YES \
VELA_RELEASE_MANIFEST_PATH="${WORK}/VelaReleaseManifest.json" \
PRODUCT_BUNDLE_IDENTIFIER=dev.yilin.Vela \
FULL_PRODUCT_NAME=Vela.app \
TARGET_BUILD_DIR="${WORK}/embed-build" \
UNLOCALIZED_RESOURCES_FOLDER_PATH=Vela.app/Contents/Resources \
  /usr/bin/env python3 "${SCRIPT_DIR}/embed_release_resources.py"
EMBEDDED_RESOURCES="${WORK}/embed-build/Vela.app/Contents/Resources"
/usr/bin/cmp -s "${WORK}/VelaReleaseManifest.json" "${EMBEDDED_RESOURCES}/VelaReleaseManifest.json" \
  || fail "embedded release manifest differs from its source"
/usr/bin/cmp -s "${REPO_ROOT}/Release/licenses/Sparkle-2.9.4-LICENSE.txt" \
  "${EMBEDDED_RESOURCES}/ThirdParty/Sparkle/LICENSE" \
  || fail "embedded Sparkle license differs from its source"
/usr/bin/cmp -s "${REPO_ROOT}/Release/licenses/Yams-6.2.2-LICENSE.txt" \
  "${EMBEDDED_RESOURCES}/ThirdParty/Yams/LICENSE" \
  || fail "embedded Yams license differs from its source"
/usr/bin/cmp -s "${REPO_ROOT}/Release/THIRD_PARTY_NOTICES.md" \
  "${EMBEDDED_RESOURCES}/ThirdParty/THIRD_PARTY_NOTICES.md" \
  || fail "embedded third-party notices differ from their source"

/bin/mkdir -p "${WORK}/debug-legal-build"
CONFIGURATION=Debug \
VELA_RELEASE_MANIFEST_REQUIRED=NO \
PRODUCT_BUNDLE_IDENTIFIER=dev.yilin.Vela \
FULL_PRODUCT_NAME=Vela.app \
TARGET_BUILD_DIR="${WORK}/debug-legal-build" \
UNLOCALIZED_RESOURCES_FOLDER_PATH=Vela.app/Contents/Resources \
  /usr/bin/env python3 "${SCRIPT_DIR}/embed_release_resources.py"
DEBUG_LEGAL_RESOURCES="${WORK}/debug-legal-build/Vela.app/Contents/Resources"
/usr/bin/cmp -s "${REPO_ROOT}/Release/licenses/Sparkle-2.9.4-LICENSE.txt" \
  "${DEBUG_LEGAL_RESOURCES}/ThirdParty/Sparkle/LICENSE" \
  || fail "debug build Sparkle license differs from its source"
/usr/bin/cmp -s "${REPO_ROOT}/Release/licenses/Yams-6.2.2-LICENSE.txt" \
  "${DEBUG_LEGAL_RESOURCES}/ThirdParty/Yams/LICENSE" \
  || fail "debug build Yams license differs from its source"
/usr/bin/cmp -s "${REPO_ROOT}/Release/THIRD_PARTY_NOTICES.md" \
  "${DEBUG_LEGAL_RESOURCES}/ThirdParty/THIRD_PARTY_NOTICES.md" \
  || fail "debug build third-party notices differ from their source"
[[ ! -e "${DEBUG_LEGAL_RESOURCES}/VelaReleaseManifest.json" ]] \
  || fail "debug build unexpectedly embedded a release manifest"

/bin/mkdir -p "${WORK}/visual-test-legal-build"
CONFIGURATION=Debug \
VELA_RELEASE_MANIFEST_REQUIRED=NO \
VELA_VISUAL_TEST_BUILD=YES \
PRODUCT_BUNDLE_IDENTIFIER=dev.yilin.Vela.VisualTests \
FULL_PRODUCT_NAME=Vela.app \
TARGET_BUILD_DIR="${WORK}/visual-test-legal-build" \
UNLOCALIZED_RESOURCES_FOLDER_PATH=Vela.app/Contents/Resources \
  /usr/bin/env python3 "${SCRIPT_DIR}/embed_release_resources.py"
VISUAL_TEST_LEGAL_RESOURCES="${WORK}/visual-test-legal-build/Vela.app/Contents/Resources"
/usr/bin/cmp -s "${REPO_ROOT}/Release/licenses/Sparkle-2.9.4-LICENSE.txt" \
  "${VISUAL_TEST_LEGAL_RESOURCES}/ThirdParty/Sparkle/LICENSE" \
  || fail "visual test build Sparkle license differs from its source"
/usr/bin/cmp -s "${REPO_ROOT}/Release/licenses/Yams-6.2.2-LICENSE.txt" \
  "${VISUAL_TEST_LEGAL_RESOURCES}/ThirdParty/Yams/LICENSE" \
  || fail "visual test build Yams license differs from its source"
/usr/bin/cmp -s "${REPO_ROOT}/Release/THIRD_PARTY_NOTICES.md" \
  "${VISUAL_TEST_LEGAL_RESOURCES}/ThirdParty/THIRD_PARTY_NOTICES.md" \
  || fail "visual test build third-party notices differ from their source"
[[ ! -e "${VISUAL_TEST_LEGAL_RESOURCES}/VelaReleaseManifest.json" ]] \
  || fail "visual test build unexpectedly embedded a release manifest"

if CONFIGURATION=Debug \
  VELA_RELEASE_MANIFEST_REQUIRED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=dev.yilin.Vela.VisualTests \
  FULL_PRODUCT_NAME=Vela.app \
  TARGET_BUILD_DIR="${WORK}/visual-test-legal-build" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH=Vela.app/Contents/Resources \
    /usr/bin/env python3 "${SCRIPT_DIR}/embed_release_resources.py" >/dev/null 2>&1; then
  fail "visual test release resources were accepted without VELA_VISUAL_TEST_BUILD=YES"
fi

/bin/mkdir -p "${WORK}/v07-build" "${WORK}/v07-temp"
SRCROOT="${REPO_ROOT}" \
TARGET_BUILD_DIR="${WORK}/v07-build" \
TARGET_TEMP_DIR="${WORK}/v07-temp" \
UNLOCALIZED_RESOURCES_FOLDER_PATH=Vela.app/Contents/Resources \
PRODUCT_BUNDLE_IDENTIFIER=dev.yilin.Vela \
FULL_PRODUCT_NAME=Vela.app \
  /usr/bin/env python3 "${SCRIPT_DIR}/embed_v07_resources.py" \
    --input-list "${REPO_ROOT}/Release/config/v07-resource-inputs.xcfilelist" \
    --output-list "${REPO_ROOT}/Release/config/v07-resource-outputs.xcfilelist"
V07_RESOURCES="${WORK}/v07-build/Vela.app/Contents/Resources"
for relative in \
  Help/en/getting-started.md \
  Help/zh-Hans/getting-started.md \
  Policies/en/SECURITY.md \
  Policies/zh-Hans/SECURITY.md \
  ReleaseCandidate/baseline.json \
  ReleaseCandidate/known-limitations.json \
  ReleaseCandidate/public-contract-freeze.json \
  Schemas/documentation-manifest.schema.json \
  Localization/terminology.json; do
  /usr/bin/cmp -s "${REPO_ROOT}/Vela/Resources/${relative}" "${V07_RESOURCES}/${relative}" \
    || fail "hierarchical V0.7 resource differs from repository source: ${relative}"
done
/usr/bin/python3 - \
  "${REPO_ROOT}/Release/config/v07-resource-inputs.xcfilelist" \
  "${REPO_ROOT}/Vela.xcodeproj/project.pbxproj" \
  "${REPO_ROOT}" <<'PY'
import pathlib
import sys

source_prefix = "$(SRCROOT)/Vela/"
entries = [
    line.strip()
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
project = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
root = pathlib.Path(sys.argv[3])
listed = set()
for entry in entries:
    if not entry.startswith(source_prefix):
        raise SystemExit(f"error: unexpected V0.7 input-list prefix: {entry}")
    relative = entry.removeprefix(source_prefix)
    listed.add(relative)
    if relative not in project:
        raise SystemExit(
            f"error: hierarchical resource lacks a synchronized-folder membership exception: {relative}"
        )
expected = {"Resources/Localization/terminology.json"}
for directory in ["Help", "Policies", "ReleaseCandidate", "Schemas"]:
    for path in (root / "Vela/Resources" / directory).rglob("*"):
        if path.is_file() and not path.is_symlink() and not path.name.startswith("."):
            expected.add(path.relative_to(root / "Vela").as_posix())
if listed != expected:
    raise SystemExit(
        "error: hierarchical V0.7 input list differs from source inventory: "
        f"missing={sorted(expected - listed)}, unexpected={sorted(listed - expected)}"
    )
for marker in [
    "Embed V0.7 Hierarchical Resources",
    "v07-resource-inputs.xcfilelist",
    "v07-resource-outputs.xcfilelist",
]:
    if marker not in project:
        raise SystemExit(f"error: Xcode project lacks hierarchical V0.7 resource marker: {marker}")
PY

/bin/mkdir -p "${WORK}/unsafe-embed/Vela.app/Contents"
/bin/ln -s "${WORK}" "${WORK}/unsafe-embed/Vela.app/Contents/Resources"
if CONFIGURATION=Release \
  VELA_RELEASE_MANIFEST_REQUIRED=YES \
  VELA_RELEASE_MANIFEST_PATH="${WORK}/VelaReleaseManifest.json" \
  PRODUCT_BUNDLE_IDENTIFIER=dev.yilin.Vela \
  FULL_PRODUCT_NAME=Vela.app \
  TARGET_BUILD_DIR="${WORK}/unsafe-embed" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH=Vela.app/Contents/Resources \
    /usr/bin/env python3 "${SCRIPT_DIR}/embed_release_resources.py" >/dev/null 2>&1; then
  fail "release resource embedding unexpectedly followed a destination symlink"
fi

/usr/bin/env python3 "${SCRIPT_DIR}/generate_release_manifest.py" \
  --repository-root "${REPO_ROOT}" --config "${REPO_ROOT}/Release/config/release.json" \
  --kind external --version 1.0.0 --build 2026071403 --channel stable \
  --tag v1.0.0 --output "${WORK}/release-manifest-external.json" --allow-dirty \
  --app-zip "${WORK}/alpha.bin" --dmg "${WORK}/beta.bin" \
  --appcast "${REPO_ROOT}/Release/config/fixtures/appcast-signed-structure.xml"
/usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
  "${WORK}/release-manifest-external.json" --kind external \
  --architecture-freeze "${REPO_ROOT}/Hardening/config/architecture-freeze.json"
/usr/bin/python3 - \
  "${WORK}/release-manifest-external.json" \
  "${REPO_ROOT}/Hardening/config/architecture-freeze.json" \
  "${WORK}/release-manifest-architecture-mismatch.json" \
  "${WORK}/release-manifest-architecture-uppercase.json" <<'PY'
import copy
import hashlib
import json
import pathlib
import sys

manifest_path, architecture_path, mismatch_path, uppercase_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
expected = hashlib.sha256(architecture_path.read_bytes()).hexdigest()
actual = manifest.get("source", {}).get("architectureFreezeSHA256")
if actual != expected:
    raise SystemExit("error: external manifest does not bind the architecture freeze bytes")

mismatch = copy.deepcopy(manifest)
mismatch["source"]["architectureFreezeSHA256"] = "0" * 64
mismatch_path.write_text(json.dumps(mismatch), encoding="utf-8")

uppercase = copy.deepcopy(manifest)
uppercase["source"]["architectureFreezeSHA256"] = "A" * 64
uppercase_path.write_text(json.dumps(uppercase), encoding="utf-8")
PY
if /usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
  "${WORK}/release-manifest-architecture-mismatch.json" --kind external \
  --architecture-freeze "${REPO_ROOT}/Hardening/config/architecture-freeze.json" \
  >/dev/null 2>&1; then
  fail "external manifest with a mismatched architecture-freeze SHA was unexpectedly accepted"
fi
if /usr/bin/env python3 "${SCRIPT_DIR}/verify_release_manifest.py" \
  "${WORK}/release-manifest-architecture-uppercase.json" --kind external \
  --architecture-freeze "${REPO_ROOT}/Hardening/config/architecture-freeze.json" \
  >/dev/null 2>&1; then
  fail "external manifest with an uppercase architecture-freeze SHA was unexpectedly accepted"
fi

/usr/bin/env python3 "${SCRIPT_DIR}/generate_sbom.py" \
  --repository-root "${REPO_ROOT}" --config "${REPO_ROOT}/Release/config/release.json" \
  --version 1.0.0 --build 2026071403 --output "${WORK}/sbom.spdx.json" --allow-unresolved
/usr/bin/env python3 "${SCRIPT_DIR}/scan_release_logs.py" \
  "${WORK}/VelaReleaseManifest.json" "${WORK}/release-manifest-external.json" \
  "${WORK}/sbom.spdx.json"

"${SCRIPT_DIR}/generate_signed_appcast.sh" --dry-run --updates-dir "${WORK}" \
  --policy "${REPO_ROOT}/Release/config/appcast-policy.json"

"${REPO_ROOT}/Release/Core/test_core_release_tooling.sh"

printf 'Release tooling syntax and fixture validation passed.\n'
