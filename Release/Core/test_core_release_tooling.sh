#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
PACK="${REPO_ROOT}/Docs/V1/Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack"
TEMP_ROOT="${TMPDIR:-/tmp}"
TEMP_ROOT="$(cd "${TEMP_ROOT}" && /bin/pwd -P)"
WORK="$(/usr/bin/mktemp -d "${TEMP_ROOT}/vela-core-tools.XXXXXX")"
cleanup() { local status=$?; case "${WORK}" in "${TEMP_ROOT}"/vela-core-tools.*) /bin/rm -rf "${WORK}" ;; esac; return "${status}"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  local label="$1"
  shift
  if "$@" >"${WORK}/expected-failure.log" 2>&1; then fail "${label} was unexpectedly accepted"; fi
}

"${SCRIPT_DIR}/CompatibilityLab/test_compatibility_lab.sh"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_embedded_core_trust_roots.py" --check
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_release_config.py"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_upstream_seed.py" "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json"
/usr/bin/cmp -s "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json" "${PACK}/fixtures/upstream-seed-v1.19.28.json" || fail "release seed differs from reviewed Pack seed"

METADATA="${WORK}/metadata"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_resources.py" \
  --seed "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json" \
  --compatibility-report "${PACK}/fixtures/compatibility-report-v1.19.28-r1.json" \
  --license "${REPO_ROOT}/Vendor/Mihomo/LICENSE" --bundle-identifier dev.yilin.Vela.MihomoCore \
  --package-revision 1 --output-directory "${METADATA}"
BUNDLE="${WORK}/VelaMihomoCore.bundle"
/bin/mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/_CodeSignature" "${BUNDLE}/Contents/Resources"
/bin/cp -p "${METADATA}/Info.plist" "${BUNDLE}/Contents/Info.plist"
/bin/cp -p "${METADATA}/Resources/"* "${BUNDLE}/Contents/Resources/"
printf 'fixture executable\n' >"${BUNDLE}/Contents/MacOS/mihomo"
printf 'fixture code resources\n' >"${BUNDLE}/Contents/_CodeSignature/CodeResources"
/bin/chmod 0755 "${BUNDLE}/Contents/MacOS/mihomo"
/bin/chmod 0644 "${BUNDLE}/Contents/Info.plist" "${BUNDLE}/Contents/_CodeSignature/CodeResources" "${BUNDLE}/Contents/Resources/"*

INDEX="${WORK}/files.json"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_file_index.py" "${BUNDLE}" \
  --base-url https://cores.test.invalid/vela/v1.19.28-r1 --output "${INDEX}"
CATALOG="${WORK}/core-catalog.json"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_catalog.py" \
  --seed "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json" \
  --compatibility-report "${PACK}/fixtures/compatibility-report-v1.19.28-r1.json" \
  --file-index "${INDEX}" --output "${CATALOG}" --sequence 1 \
  --generated-at 2026-07-13T00:00:00Z --expires-at 2026-08-12T00:00:00Z --published-at 2026-07-13T00:00:00Z \
  --status recommended --release-notes-url https://cores.test.invalid/vela/v1.19.28-r1/release-notes.md \
  --bundle-identifier dev.yilin.Vela.MihomoCore

PRIVATE_KEY="${WORK}/catalog.key"
ROTATION_PRIVATE_KEY="${WORK}/catalog-rotation.key"
KEYRING="${WORK}/keyring.json"
/usr/bin/python3 - "${PACK}/fixtures/TEST-ONLY-core-catalog-key.json" "${PRIVATE_KEY}" "${ROTATION_PRIVATE_KEY}" "${KEYRING}" <<'PY'
import base64, json, os, pathlib, sys
fixture = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
pathlib.Path(sys.argv[2]).write_text(fixture["privateKeySeedHex"] + "\n", encoding="utf-8")
rotation_seed = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
rotation_public = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
pathlib.Path(sys.argv[3]).write_text(rotation_seed + "\n", encoding="utf-8")
os.chmod(sys.argv[2], 0o600)
os.chmod(sys.argv[3], 0o600)
keyring = {"schemaVersion": 1, "keys": [
    {"keyID": fixture["keyID"], "algorithm": "ed25519", "publicKeyBase64": fixture["publicKeyBase64"], "status": "active", "notBefore": "2026-01-01T00:00:00Z", "notAfter": "2026-12-31T23:59:59Z"},
    {"keyID": "TEST-ONLY-core-catalog-2026-b", "algorithm": "ed25519", "publicKeyBase64": base64.b64encode(bytes.fromhex(rotation_public)).decode("ascii"), "status": "next", "notBefore": "2026-01-01T00:00:00Z", "notAfter": "2026-12-31T23:59:59Z"},
]}
pathlib.Path(sys.argv[4]).write_text(json.dumps(keyring, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
SIGNATURES="${WORK}/core-catalog.signatures.json"
/usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${CATALOG}" \
  --key-id TEST-ONLY-core-catalog-2026-a --private-key-file "${PRIVATE_KEY}" \
  --output "${SIGNATURES}" --repository-root "${REPO_ROOT}" --allow-test-key
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${CATALOG}" \
  --signatures "${SIGNATURES}" --public-keyring "${KEYRING}" \
  --compatibility-report "${PACK}/fixtures/compatibility-report-v1.19.28-r1.json"
ROTATING_SIGNATURES="${WORK}/core-catalog.rotating.signatures.json"
/usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${CATALOG}" \
  --key-id TEST-ONLY-core-catalog-2026-b --private-key-file "${ROTATION_PRIVATE_KEY}" \
  --existing-envelope "${SIGNATURES}" --output "${ROTATING_SIGNATURES}" \
  --repository-root "${REPO_ROOT}" --allow-test-key
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${CATALOG}" \
  --signatures "${ROTATING_SIGNATURES}" --public-keyring "${KEYRING}" \
  --required-key-id TEST-ONLY-core-catalog-2026-a \
  --required-key-id TEST-ONLY-core-catalog-2026-b --require-exact-key-set
expect_failure "missing rotation signature" /usr/bin/env python3 \
  "${SCRIPT_DIR}/validate_core_catalog.py" "${CATALOG}" \
  --signatures "${SIGNATURES}" --public-keyring "${KEYRING}" \
  --required-key-id TEST-ONLY-core-catalog-2026-a \
  --required-key-id TEST-ONLY-core-catalog-2026-b --require-exact-key-set
expect_failure "rotation envelope bound to different raw Catalog" /usr/bin/env python3 \
  "${SCRIPT_DIR}/sign_core_catalog.py" "${PACK}/fixtures/core-catalog-test.json" \
  --key-id TEST-ONLY-core-catalog-2026-b --private-key-file "${ROTATION_PRIVATE_KEY}" \
  --existing-envelope "${SIGNATURES}" --output "${WORK}/mismatched-rotation.json" \
  --repository-root "${REPO_ROOT}" --allow-test-key

HISTORY_SIGNATURES="${WORK}/core-catalog.history.signatures.json"
/usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${CATALOG}" \
  --key-id fixture-history-key --private-key-file "${PRIVATE_KEY}" \
  --output "${HISTORY_SIGNATURES}" --repository-root "${REPO_ROOT}"
HISTORY_PUBLIC="${WORK}/history-public"
/bin/mkdir "${HISTORY_PUBLIC}"
/bin/cp "${CATALOG}" "${HISTORY_PUBLIC}/core-catalog.json"
/bin/cp "${HISTORY_SIGNATURES}" "${HISTORY_PUBLIC}/core-catalog.signatures.json"
/usr/bin/env python3 "${SCRIPT_DIR}/stage_core_catalog_history.py" \
  --catalog "${CATALOG}" --signatures "${HISTORY_SIGNATURES}" \
  --public-directory "${HISTORY_PUBLIC}" --sequence 1
/usr/bin/cmp -s "${HISTORY_PUBLIC}/core-catalog.json" \
  "${HISTORY_PUBLIC}/catalog-history/sequence-1/core-catalog.json" || \
  fail "Catalog history bytes differ from the top-level raw Catalog"
/usr/bin/cmp -s "${HISTORY_PUBLIC}/core-catalog.signatures.json" \
  "${HISTORY_PUBLIC}/catalog-history/sequence-1/core-catalog.signatures.json" || \
  fail "Catalog history signature envelope differs from the top-level envelope"
expect_failure "immutable Catalog history overwrite" /usr/bin/env python3 \
  "${SCRIPT_DIR}/stage_core_catalog_history.py" \
  --catalog "${CATALOG}" --signatures "${HISTORY_SIGNATURES}" \
  --public-directory "${HISTORY_PUBLIC}" --sequence 1

# The Pack's independently generated signature proves exact raw-byte verification.
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${PACK}/fixtures/core-catalog-test.json" \
  --signatures "${PACK}/fixtures/core-catalog-test.signatures.json" --public-keyring "${KEYRING}"
expect_failure "test key production gate" /usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${CATALOG}" \
  --signatures "${SIGNATURES}" --public-keyring "${KEYRING}" --production
expect_failure "unsigned production Catalog gate" /usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${CATALOG}" --production

# Production App endpoints are fixed by the reviewed Core config, while empty
# build defaults stay unconfigured instead of becoming a development feed.
DISTRIBUTION_SEQUENCE_1="${WORK}/distribution-sequence-1.json"
DISTRIBUTION_SEQUENCE_2="${WORK}/distribution-sequence-2.json"
DISTRIBUTION_WRONG_URL="${WORK}/distribution-wrong-url.json"
DISTRIBUTION_WRONG_PRIOR="${WORK}/distribution-wrong-prior.json"
DISTRIBUTION_EXAMPLE="${WORK}/distribution-example.json"
DISTRIBUTION_LOCALHOST="${WORK}/distribution-localhost.json"
DISTRIBUTION_PRIVATE="${WORK}/distribution-private.json"
INFO_EXACT="${WORK}/Info-exact.plist"
INFO_EMPTY="${WORK}/Info-empty.plist"
INFO_WRONG="${WORK}/Info-wrong.plist"
/usr/bin/python3 - "${SCRIPT_DIR}/config/core-release.json" "${CATALOG}" \
  "${DISTRIBUTION_SEQUENCE_1}" "${DISTRIBUTION_SEQUENCE_2}" "${DISTRIBUTION_WRONG_URL}" "${DISTRIBUTION_WRONG_PRIOR}" \
  "${DISTRIBUTION_EXAMPLE}" "${DISTRIBUTION_LOCALHOST}" "${DISTRIBUTION_PRIVATE}" \
  "${INFO_EXACT}" "${INFO_EMPTY}" "${INFO_WRONG}" <<'PY'
import copy
import hashlib
import json
import pathlib
import plistlib
import sys

source_path, catalog_path, sequence_1_path, sequence_2_path, wrong_url_path, wrong_prior_path, example_path, localhost_path, private_path, exact_info_path, empty_info_path, wrong_info_path = sys.argv[1:]
source = json.loads(pathlib.Path(source_path).read_text(encoding="utf-8"))
base = "https://github.com/Spacebody/Vela/releases/download/core-feed-v1"
sequence_1 = copy.deepcopy(source)
sequence_1["catalog"].update({
    "baseURL": base,
    "catalogURL": base + "/core-catalog.json",
    "catalogSignaturesURL": base + "/core-catalog.signatures.json",
    "sequence": 1,
    "priorCatalogSequence": None,
    "priorCatalogURL": None,
    "priorCatalogSHA256": None,
})
sequence_2 = copy.deepcopy(sequence_1)
sequence_2["catalog"].update({
    "sequence": 2,
    "priorCatalogSequence": 1,
    "priorCatalogURL": base + "/catalog-history/sequence-1/core-catalog.json",
    "priorCatalogSHA256": hashlib.sha256(pathlib.Path(catalog_path).read_bytes()).hexdigest(),
})
wrong_url = copy.deepcopy(sequence_1)
wrong_url["catalog"]["catalogSignaturesURL"] = base + "/other-signatures.json"
wrong_prior = copy.deepcopy(sequence_2)
wrong_prior["catalog"]["priorCatalogURL"] = "https://attacker.example.com/core-catalog.json"
def with_base(value, replacement):
    result = copy.deepcopy(value)
    result["catalog"]["baseURL"] = replacement
    result["catalog"]["catalogURL"] = replacement + "/core-catalog.json"
    result["catalog"]["catalogSignaturesURL"] = replacement + "/core-catalog.signatures.json"
    return result
example = with_base(sequence_1, "https://core-downloads.example.com/vela")
localhost = with_base(sequence_1, "https://localhost/vela")
private = with_base(sequence_1, "https://127.0.0.1/vela")
for path, value in [
    (sequence_1_path, sequence_1),
    (sequence_2_path, sequence_2),
    (wrong_url_path, wrong_url),
    (wrong_prior_path, wrong_prior),
    (example_path, example),
    (localhost_path, localhost),
    (private_path, private),
]:
    pathlib.Path(path).write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
with pathlib.Path(exact_info_path).open("wb") as handle:
    plistlib.dump({
        "VelaCoreCatalogURL": base + "/core-catalog.json",
        "VelaCoreCatalogSignaturesURL": base + "/core-catalog.signatures.json",
    }, handle)
with pathlib.Path(empty_info_path).open("wb") as handle:
    plistlib.dump({
        "VelaCoreCatalogURL": "",
        "VelaCoreCatalogSignaturesURL": "",
    }, handle)
with pathlib.Path(wrong_info_path).open("wb") as handle:
    plistlib.dump({
        "VelaCoreCatalogURL": base + "/wrong-catalog.json",
        "VelaCoreCatalogSignaturesURL": base + "/core-catalog.signatures.json",
    }, handle)
PY
/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${DISTRIBUTION_SEQUENCE_1}" --production
/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${DISTRIBUTION_SEQUENCE_1}" --info-plist "${INFO_EXACT}" --production
/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${SCRIPT_DIR}/config/core-release.json" --info-plist "${INFO_EMPTY}"
/usr/bin/env python3 "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${DISTRIBUTION_SEQUENCE_1}" --info-plist "${INFO_EMPTY}"
expect_failure "missing production Core endpoints" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" \
  --config "${SCRIPT_DIR}/config/core-release.json" --production
expect_failure "empty production bundled Core endpoints" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" --config "${DISTRIBUTION_SEQUENCE_1}" \
  --info-plist "${INFO_EMPTY}" --production
expect_failure "incorrect bundled Core endpoint" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" --config "${DISTRIBUTION_SEQUENCE_1}" \
  --info-plist "${INFO_WRONG}" --production
expect_failure "incorrect fixed signatures endpoint" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" --config "${DISTRIBUTION_WRONG_URL}" --production
expect_failure "operator-selected prior Catalog origin" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" --config "${DISTRIBUTION_WRONG_PRIOR}" --production
expect_failure "reserved example production endpoint" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" --config "${DISTRIBUTION_EXAMPLE}" --production
expect_failure "localhost production endpoint" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" --config "${DISTRIBUTION_LOCALHOST}" --production
expect_failure "private production endpoint" /usr/bin/env python3 \
  "${SCRIPT_DIR}/core_catalog_distribution.py" --config "${DISTRIBUTION_PRIVATE}" --production
/usr/bin/env PYTHONPATH="${SCRIPT_DIR}" /usr/bin/python3 -c \
  'from core_release_lib import production_https_url_issue; assert production_https_url_issue("https://notes.example.invalid/v1.md") is not None'
/usr/bin/env python3 "${SCRIPT_DIR}/verify_prior_core_catalog.py" "${CATALOG}" \
  --config "${DISTRIBUTION_SEQUENCE_2}"
"${SCRIPT_DIR}/acquire_prior_core_catalog.sh" --dry-run --config "${DISTRIBUTION_SEQUENCE_2}"

BLOCKED="${WORK}/core-catalog-blocked.json"
TIMESTAMPED_BUNDLE="${WORK}/timestamped/VelaMihomoCore.bundle"
/bin/mkdir "${WORK}/timestamped"
/bin/cp -pR "${BUNDLE}" "${TIMESTAMPED_BUNDLE}"
printf 'different signing timestamp fixture\n' >>"${TIMESTAMPED_BUNDLE}/Contents/_CodeSignature/CodeResources"
TIMESTAMPED_INDEX="${WORK}/timestamped-files.json"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_file_index.py" "${TIMESTAMPED_BUNDLE}" \
  --base-url https://cores.test.invalid/vela/v1.19.28-r1 --output "${TIMESTAMPED_INDEX}"
expect_failure "timestamped rebuild changed immutable current Core files" /usr/bin/env python3 \
  "${SCRIPT_DIR}/generate_core_catalog.py" \
  --seed "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json" \
  --compatibility-report "${PACK}/fixtures/compatibility-report-v1.19.28-r1.json" \
  --file-index "${TIMESTAMPED_INDEX}" --output "${WORK}/rebuilt-incident.json" \
  --sequence 2 --prior-catalog "${CATALOG}" \
  --generated-at 2026-07-14T00:00:00Z --expires-at 2026-08-13T00:00:00Z \
  --published-at 2026-07-13T00:00:00Z --status blocked --block-reason 'fixture incident' \
  --release-notes-url https://cores.test.invalid/vela/v1.19.28-r1/release-notes.md \
  --bundle-identifier dev.yilin.Vela.MihomoCore
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_incident_catalog.py" \
  --prior-catalog "${CATALOG}" --core-id v1.19.28-r1 --status blocked \
  --reason 'fixture incident' --sequence 2 --generated-at 2026-07-14T00:00:00Z \
  --expires-at 2026-08-13T00:00:00Z --key-set-version 1 --output "${BLOCKED}"
/usr/bin/python3 - "${CATALOG}" "${BLOCKED}" <<'PY'
import json, pathlib, sys
prior = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["entries"][0]
incident = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))["entries"][0]
for field in set(prior) - {"status", "blockReason"}:
    if incident[field] != prior[field]:
        raise SystemExit("error: catalog-only incident changed immutable prior metadata/files")
if incident["status"] != "blocked" or incident["blockReason"] != "fixture incident":
    raise SystemExit("error: catalog-only incident did not apply the requested status/reason")
PY
INCIDENT_SIGNATURES="${WORK}/incident.signatures.json"
/usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${BLOCKED}" \
  --key-id fixture-incident-evidence-key --private-key-file "${PRIVATE_KEY}" \
  --output "${INCIDENT_SIGNATURES}" --repository-root "${REPO_ROOT}"
INCIDENT_PUBLIC="${WORK}/incident-public"
/bin/mkdir "${INCIDENT_PUBLIC}"
/bin/cp "${BLOCKED}" "${INCIDENT_PUBLIC}/core-catalog.json"
/bin/cp "${INCIDENT_SIGNATURES}" "${INCIDENT_PUBLIC}/core-catalog.signatures.json"
/usr/bin/env python3 "${SCRIPT_DIR}/stage_core_catalog_history.py" \
  --catalog "${BLOCKED}" --signatures "${INCIDENT_SIGNATURES}" \
  --public-directory "${INCIDENT_PUBLIC}" --sequence 2
INCIDENT_CONFIG="${WORK}/incident-release.json"
/usr/bin/python3 - "${SCRIPT_DIR}/config/core-release.json" "${CATALOG}" "${INCIDENT_CONFIG}" <<'PY'
import hashlib, json, pathlib, sys
source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
prior = pathlib.Path(sys.argv[2]).read_bytes()
source["catalog"].update({
    "operation": "incident",
    "sequence": 2,
    "priorCatalogSequence": 1,
    "priorCatalogURL": "https://github.com/Spacebody/Vela/releases/download/core-feed-v1/catalog-history/sequence-1/core-catalog.json",
    "priorCatalogSHA256": hashlib.sha256(prior).hexdigest(),
    "status": "blocked",
    "blockReason": "fixture incident",
    "generatedAt": "2026-07-14T00:00:00Z",
    "expiresAt": "2026-08-13T00:00:00Z",
})
pathlib.Path(sys.argv[3]).write_text(
    json.dumps(source, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
PRIVATE_EVIDENCE="${WORK}/private-incident-evidence.zip"
PRIVATE_MANIFEST="${WORK}/private-incident-manifest.json"
/usr/bin/env python3 "${SCRIPT_DIR}/create_core_release_evidence.py" \
  --repository-root "${REPO_ROOT}" --config "${INCIDENT_CONFIG}" \
  --public-directory "${INCIDENT_PUBLIC}" --prior-catalog "${CATALOG}" \
  --archive-output "${PRIVATE_EVIDENCE}" --manifest-output "${PRIVATE_MANIFEST}"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_release_evidence.py" \
  "${PRIVATE_EVIDENCE}" --manifest "${PRIVATE_MANIFEST}"
/bin/cp "${PRIVATE_MANIFEST}" "${WORK}/tampered-private-manifest.json"
printf ' ' >>"${WORK}/tampered-private-manifest.json"
expect_failure "tampered private evidence sidecar" /usr/bin/env python3 \
  "${SCRIPT_DIR}/validate_core_release_evidence.py" "${PRIVATE_EVIDENCE}" \
  --manifest "${WORK}/tampered-private-manifest.json"

# A full release archive must retain every private/public evidence class before
# workflow cleanup. These are structure fixtures; cryptographic content is
# validated independently by the build, notary, identity, and Catalog gates.
FULL_PREPARED="${WORK}/full-prepared"
/bin/mkdir -p "${FULL_PREPARED}/upstream" "${FULL_PREPARED}/notary"
/bin/cp -pR "${BUNDLE}" "${FULL_PREPARED}/VelaMihomoCore.bundle"
printf 'upstream archive fixture\n' >"${FULL_PREPARED}/upstream/mihomo-darwin-arm64-v1.19.28.gz"
printf 'unsigned executable fixture\n' >"${FULL_PREPARED}/upstream/mihomo"
printf '{"id":"fixture","status":"Accepted"}\n' >"${FULL_PREPARED}/notary/notary-core-result.json"
printf '{"statusSummary":"Accepted fixture"}\n' >"${FULL_PREPARED}/notary/notary-core-log.json"
printf 'notary archive fixture\n' >"${FULL_PREPARED}/notary/VelaMihomoCore-v1.19.28-r1.zip"
printf '{}\n' >"${FULL_PREPARED}/signed-core-identity.json"
printf 'fixture compatibility hash\n' >"${FULL_PREPARED}/compatibility.sha256"
FULL_PUBLIC="${WORK}/full-public"
/bin/cp -pR "${HISTORY_PUBLIC}" "${FULL_PUBLIC}"
/bin/cp "${INDEX}" "${FULL_PUBLIC}/files.json"
printf '{}\n' >"${FULL_PUBLIC}/core-sbom.spdx.json"
FULL_CONFIG="${WORK}/full-release.json"
/usr/bin/python3 - "${SCRIPT_DIR}/config/core-release.json" "${FULL_CONFIG}" <<'PY'
import json, pathlib, sys
source = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
fixture = "Docs/V1/Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack/fixtures/compatibility-report-v1.19.28-r1.json"
source["core"].update({
    "compatibilityReport": fixture,
    "dedicatedHostEvidence": fixture,
    "performanceReview": fixture,
})
source["catalog"].update({
    "operation": "full",
    "sequence": 1,
    "generatedAt": "2026-07-13T00:00:00Z",
    "expiresAt": "2026-08-12T00:00:00Z",
})
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(source, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
FULL_EVIDENCE="${WORK}/private-full-evidence.zip"
FULL_MANIFEST="${WORK}/private-full-manifest.json"
/usr/bin/env python3 "${SCRIPT_DIR}/create_core_release_evidence.py" \
  --repository-root "${REPO_ROOT}" --config "${FULL_CONFIG}" \
  --prepared-directory "${FULL_PREPARED}" --public-directory "${FULL_PUBLIC}" \
  --archive-output "${FULL_EVIDENCE}" --manifest-output "${FULL_MANIFEST}"
/usr/bin/env python3 "${SCRIPT_DIR}/validate_core_release_evidence.py" \
  "${FULL_EVIDENCE}" --manifest "${FULL_MANIFEST}"
WITHDRAWN="${WORK}/core-catalog-withdrawn.json"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_incident_catalog.py" \
  --prior-catalog "${BLOCKED}" --core-id v1.19.28-r1 --status withdrawn \
  --reason 'fixture withdrawn incident' --sequence 3 \
  --generated-at 2026-07-15T00:00:00Z --expires-at 2026-08-14T00:00:00Z \
  --key-set-version 1 --output "${WITHDRAWN}"
expect_failure "withdrawn status without reason" /usr/bin/env python3 \
  "${SCRIPT_DIR}/generate_core_incident_catalog.py" \
  --prior-catalog "${WITHDRAWN}" --core-id v1.19.28-r1 --status withdrawn \
  --sequence 4 --generated-at 2026-07-16T00:00:00Z \
  --expires-at 2026-08-15T00:00:00Z --key-set-version 1 \
  --output "${WORK}/withdrawn-without-reason.json"
expect_failure "terminal Core reintroduction" /usr/bin/env python3 \
  "${SCRIPT_DIR}/generate_core_catalog.py" \
  --seed "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json" \
  --compatibility-report "${PACK}/fixtures/compatibility-report-v1.19.28-r1.json" \
  --file-index "${INDEX}" --output "${WORK}/terminal-reintroduced.json" --sequence 4 --prior-catalog "${WITHDRAWN}" \
  --generated-at 2026-07-16T00:00:00Z --expires-at 2026-08-15T00:00:00Z --published-at 2026-07-13T00:00:00Z \
  --status available --release-notes-url https://cores.test.invalid/vela/v1.19.28-r1/release-notes.md \
  --bundle-identifier dev.yilin.Vela.MihomoCore
/usr/bin/python3 - "${WITHDRAWN}" "${WORK}/omitted-tombstone.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value["sequence"] = 4
value["generatedAt"] = "2026-07-16T00:00:00Z"
value["expiresAt"] = "2026-08-15T00:00:00Z"
value["entries"] = []
pathlib.Path(sys.argv[2]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
expect_failure "omitted terminal tombstone" /usr/bin/env python3 \
  "${SCRIPT_DIR}/validate_core_catalog.py" "${WORK}/omitted-tombstone.json" \
  --prior-catalog "${WITHDRAWN}"
expect_failure "lower sequence replay" /usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${CATALOG}" --prior-catalog "${BLOCKED}"
expect_failure "same sequence substitution" /usr/bin/env python3 "${SCRIPT_DIR}/validate_core_catalog.py" "${PACK}/fixtures/core-catalog-blocked.json" --prior-catalog "${BLOCKED}"
expect_failure "prior Catalog expected SHA mismatch" /usr/bin/env python3 \
  "${SCRIPT_DIR}/verify_prior_core_catalog.py" "${BLOCKED}" \
  --config "${DISTRIBUTION_SEQUENCE_2}"

SBOM="${WORK}/core-sbom.spdx.json"
/usr/bin/env python3 "${SCRIPT_DIR}/generate_core_sbom.py" \
  --seed "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json" --file-index "${INDEX}" \
  --core-id v1.19.28-r1 --created-at 2026-07-13T00:00:00Z --output "${SBOM}"
printf 'safe release note\n' >"${WORK}/safe.txt"
/usr/bin/env python3 "${SCRIPT_DIR}/scan_core_release.py" "${WORK}/safe.txt" "${SBOM}"
printf 'https://github.com/MetaCubeX/mihomo/releases/latest\n' >"${WORK}/unsafe.txt"
expect_failure "latest release scan" /usr/bin/env python3 "${SCRIPT_DIR}/scan_core_release.py" "${WORK}/unsafe.txt"
printf '{"keyID":"catalog-test-2026"}\n' >"${WORK}/unsafe-test-key.txt"
expect_failure "generic test key scan" /usr/bin/env python3 "${SCRIPT_DIR}/scan_core_release.py" "${WORK}/unsafe-test-key.txt"
printf 'opaque credential bytes\n' >"${WORK}/unsafe.p12"
expect_failure "credential filename scan" /usr/bin/env python3 "${SCRIPT_DIR}/scan_core_release.py" "${WORK}/unsafe.p12"
/bin/chmod 0644 "${PRIVATE_KEY}"
expect_failure "private key permission gate" /usr/bin/env python3 "${SCRIPT_DIR}/sign_core_catalog.py" "${CATALOG}" \
  --key-id fixture-permission-test --private-key-file "${PRIVATE_KEY}" --output "${WORK}/forbidden-signature.json" --repository-root "${REPO_ROOT}"

"${SCRIPT_DIR}/fetch_upstream_core.sh" --dry-run --seed "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json"
"${SCRIPT_DIR}/build_core_bundle.sh" --dry-run --seed "${SCRIPT_DIR}/config/upstream-seed-v1.19.28.json" \
  --compatibility-report "${PACK}/fixtures/compatibility-report-v1.19.28-r1.json" --license "${REPO_ROOT}/Vendor/Mihomo/LICENSE" \
  --bundle-identifier dev.yilin.Vela.MihomoCore --package-revision 1
"${SCRIPT_DIR}/verify_core_bundle.sh" --dry-run
"${SCRIPT_DIR}/notarize_core_bundle.sh" --dry-run
"${SCRIPT_DIR}/prepare_core_release.sh" --dry-run
"${SCRIPT_DIR}/publish_core_release.sh" --dry-run
printf 'Vela 0.6 signed Core release tooling fixtures passed.\n'
