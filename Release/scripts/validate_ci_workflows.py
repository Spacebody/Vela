#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    pr = root / ".github/workflows/pr-ci.yml"
    release = root / ".github/workflows/release.yml"
    core = root / ".github/workflows/core-ingest.yml"
    incident = root / ".github/workflows/core-incident.yml"
    for path in [pr, release, core, incident]:
        if not path.is_file() or path.is_symlink():
            fail(f"workflow is missing or unsafe: {path}")
        text = path.read_text(encoding="utf-8")
        uses = re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", text)
        if not uses:
            fail(f"workflow has no pinned action: {path.name}")
        for action in uses:
            if re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action) is None:
                fail(f"workflow action is not pinned to a full SHA: {path.name}: {action}")
        if "permissions:\n  contents: read" not in text:
            fail(f"workflow lacks top-level contents: read permission: {path.name}")
        if "Vela.xcworkspace" in text:
            fail(f"workflow references the nonexistent Vela.xcworkspace: {path.name}")
        syntax = subprocess.run(
            (
                "/usr/bin/ruby",
                "-e",
                'require "yaml"; YAML.parse_file(ARGV.fetch(0))',
                str(path),
            ),
            text=True,
            capture_output=True,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
        if syntax.returncode != 0:
            detail = syntax.stderr.strip() or syntax.stdout.strip() or "invalid YAML"
            fail(f"workflow YAML syntax is invalid: {path.name}: {detail}")
    pr_text = pr.read_text(encoding="utf-8")
    if "pull_request_target" in pr_text:
        fail("PR CI must not use pull_request_target")
    if "secrets." in pr_text:
        fail("PR CI must not reference secrets")
    if "pull_request:" not in pr_text or "macos-15" not in pr_text:
        fail("PR CI trigger/runner contract is missing")
    change_control_gate = re.search(
        r"(?ms)- name: Validate PR feature-freeze change control\n(.*?)(?=^\s{6}- name:|\Z)",
        pr_text,
    )
    if change_control_gate is None:
        fail("PR CI lacks the feature-freeze change-control gate")
    change_control_gate_text = change_control_gate.group(1)
    for required in [
        "if: github.event_name == 'pull_request'",
        "run: python3 ReleaseCandidate/scripts/validate_pr_change_control.py",
    ]:
        if required not in change_control_gate_text:
            fail(f"PR feature-freeze change-control gate lacks: {required}")
    if "github.event.pull_request.body" in change_control_gate_text:
        fail("PR change-control body must be read from GITHUB_EVENT_PATH, not shell interpolation")

    template = root / ".github/pull_request_template.md"
    codeowners = root / ".github/CODEOWNERS"
    for path in (template, codeowners):
        if not path.is_file() or path.is_symlink():
            fail(f"PR governance file is missing or unsafe: {path.relative_to(root)}")
    template_text = template.read_text(encoding="utf-8")
    start_marker = "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-START -->"
    end_marker = "<!-- VELA-FEATURE-FREEZE-CHANGE-CONTROL-END -->"
    if template_text.count(start_marker) != 1 or template_text.count(end_marker) != 1:
        fail("PR template must contain exactly one feature-freeze marker pair")
    required_metadata = [
        "changeClass",
        "issueID",
        "severity",
        "userImpact",
        "securityImpact",
        "contractImpact",
        "migrationImpact",
        "testEvidence",
        "releaseNoteImpact",
        "reviewer",
    ]
    for field in required_metadata:
        matches = re.findall(rf"(?m)^\s*{re.escape(field)}:\s*(\S.*?)\s*$", template_text)
        if matches != ["REPLACE_ME"]:
            fail(f"PR template must declare {field}: REPLACE_ME exactly once")
    owner_lines = {
        line.strip()
        for line in codeowners.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    required_owner_lines = {
        "/.github/workflows/ @Spacebody",
        "/Release/ @Spacebody",
        "/ReleaseCandidate/ @Spacebody",
        "/Hardening/ @Spacebody",
        "/VelaIPC/ @Spacebody",
        "/Vela/Core/Updates/ @Spacebody",
        "/Vela/Core/CoreLifecycle/ @Spacebody",
        "/Vela/Core/Privileged/ @Spacebody",
    }
    missing_owner_lines = sorted(required_owner_lines - owner_lines)
    if missing_owner_lines:
        fail("CODEOWNERS lacks sensitive-path ownership: " + ", ".join(missing_owner_lines))
    release_text = release.read_text(encoding="utf-8")
    portable_mac_paths = [
        *sorted((root / ".github/workflows").glob("*.yml")),
        *sorted((root / "Release/scripts").glob("*.sh")),
        *sorted((root / "Scripts/Privileged").glob("*.sh")),
    ]
    for path in portable_mac_paths:
        if "-maxdepth" in path.read_text(encoding="utf-8"):
            fail(f"macOS workflow/script uses GNU-only find -maxdepth: {path.relative_to(root)}")
    if "workflow_dispatch:" not in release_text or "environment: production" not in release_text:
        fail("release workflow must be manually dispatched through the production environment")
    if "pull_request:" in release_text or "pull_request_target" in release_text:
        fail("release workflow must not be triggered by pull requests")
    run_blocks = re.findall(r"(?ms)^\s+run:\s*\|\n(.*?)(?=^\s{6,}[A-Za-z_-]+:|\Z)", release_text)
    if any("${{ inputs." in block for block in run_blocks):
        fail("release workflow must pass dispatch inputs through environment variables before shell use")

    required_release_security = [
        "ref: refs/tags/${{ inputs.tag }}",
        'TAG_REF="refs/tags/${RELEASE_TAG}"',
        'git cat-file -t "${TAG_REF}"',
        "RELEASE_TAG_SIGNING_FINGERPRINT",
        'git verify-tag --raw "${TAG_REF}"',
        '$2 == "VALIDSIG"',
        "Initialize isolated release paths",
        'test -n "${RUNNER_TEMP}"',
        "VELA_CREDENTIAL_ROOT=%s/vela-release-credentials-",
        '"${RUNNER_TEMP}"/vela-release-credentials-*',
        "Create ephemeral release credentials",
        "security create-keychain",
        "security import",
        "security set-key-partition-list",
        "security list-keychains -d user -s \"${RELEASE_KEYCHAIN}\"",
        "notarytool store-credentials",
        "--keychain \"${RELEASE_KEYCHAIN}\"",
        "SPARKLE_ED25519_PRIVATE_KEY",
        "SPARKLE_ED_KEY_FILE",
        "prior_appcast_path:",
        "prior_appcast_sha256:",
        "audit_summary_evidence_path:",
        "phase:",
        "candidate_stage_path:",
        "promotion_output_root_path:",
        "installation_matrix_path:",
        'RELEASE_AUDIT_SUMMARY_EVIDENCE_PATH: ${{ inputs.audit_summary_evidence_path }}',
        '--audit-summary "${RELEASE_AUDIT_SUMMARY_EVIDENCE_PATH}"',
        "Atomically reserve candidate build number",
        "manage_build_ledger.py",
        "--installation-matrix",
        "--candidate-stage",
        "--promote-candidate",
        "--promotion-output-root",
        "--expect-reserved",
        "--bundle-output",
        "--trusted-root-output",
        "attestation-bundles-",
        "attestation-trusted-root-",
        "Consume incomplete candidate-stage build allocation",
        "Destroy ephemeral release credentials",
        "security delete-keychain",
    ]
    for required in required_release_security:
        if required not in release_text:
            fail(f"release workflow lacks ephemeral credential gate: {required}")
    cleanup = re.search(
        r"(?ms)- name: Destroy ephemeral release credentials\n(.*?)(?=^\s{6}- name:|^\s{6}#|\Z)",
        release_text,
    )
    if cleanup is None or "if: always()" not in cleanup.group(1):
        fail("release credential cleanup must run with if: always()")
    if release_text.index("Create ephemeral release credentials") > release_text.index(
        "Execute candidate stage or exact-byte promotion"
    ):
        fail("ephemeral credentials must be created before the release build")
    source_gate = re.search(
        r"(?ms)- name: Validate V0\.7 source acceptance\n(.*?)(?=^\s{6}- name:|\Z)",
        release_text,
    )
    if source_gate is None:
        fail("release workflow lacks the credential-free V0.7 source acceptance gate")
    source_gate_text = source_gate.group(1)
    for required in [
        "validate_v07_acceptance.py --source",
        "SOURCE_DATE_EPOCH",
        "--app-version",
        "--app-build",
    ]:
        if required not in source_gate_text:
            fail(f"V0.7 source acceptance gate lacks: {required}")
    if "secrets." in source_gate_text:
        fail("V0.7 source acceptance gate must run before and without release secrets")
    if release_text.index("Validate V0.7 source acceptance") > release_text.index(
        "Create ephemeral release credentials"
    ):
        fail("V0.7 source acceptance must finish before release credentials are created")
    if release_text.index("Destroy ephemeral release credentials") < release_text.index(
        "Execute candidate stage or exact-byte promotion"
    ):
        fail("ephemeral credentials must be destroyed after the release build")
    credential_step = re.search(
        r"(?ms)- name: Create ephemeral release credentials\n(.*?)(?=^\s{6}- name:|\Z)",
        release_text,
    )
    if credential_step is None or "if: inputs.phase == 'candidate-stage'" not in credential_step.group(1):
        fail("Apple/Sparkle credentials must be created only for candidate staging")
    release_runner = re.search(
        r"(?ms)- name: Bind durable release machine\n(.*?)(?=^\s{6}- name:|\Z)",
        release_text,
    )
    attestation_runner = re.search(
        r"(?ms)- name: Bind attestation to the release machine\n(.*?)(?=^\s{6}- name:|\Z)",
        release_text,
    )
    if release_runner is None or attestation_runner is None:
        fail("release workflow must bind both jobs to one durable protected release machine")
    for required in [
        "VELA_RELEASE_RUNNER_NAME",
        'test "${RUNNER_NAME}" = "${EXPECTED_RELEASE_RUNNER_NAME}"',
        'printf \'runner_name=%s\\n\' "${RUNNER_NAME}" >>"${GITHUB_OUTPUT}"',
    ]:
        if required not in release_runner.group(1):
            fail(f"release-machine binding lacks: {required}")
    for required in [
        "VELA_RELEASE_RUNNER_NAME",
        "needs.release.outputs.release_runner_name",
        'test "${RUNNER_NAME}" = "${RELEASE_RUNNER_NAME}"',
    ]:
        if required not in attestation_runner.group(1):
            fail(f"attestation-machine binding lacks: {required}")
    if "release_runner_name: ${{ steps.bind_release_runner.outputs.runner_name }}" not in release_text:
        fail("release job must export the exact durable runner identity")
    promotion_preparation_steps = [
        "Resolve immutable public release output",
        "Seal and verify exact public RC inventory",
    ]
    for name in promotion_preparation_steps:
        block = re.search(
            rf"(?ms)- name: {re.escape(name)}\n(.*?)(?=^\s{{6}}- name:|^\s{{6}}#|\Z)",
            release_text,
        )
        if block is None or "if: inputs.phase == 'promotion'" not in block.group(1):
            fail(f"promotion-only workflow step lacks a phase guard: {name}")
    top_permissions = release_text.split("\njobs:\n", 1)[0]
    for forbidden_permission in (
        "id-token: write",
        "attestations: write",
        "artifact-metadata: write",
    ):
        if forbidden_permission in top_permissions:
            fail(f"release workflow grants job-wide write permission: {forbidden_permission}")
    attestation_job = re.search(r"(?ms)^  attest:\n(.*)\Z", release_text)
    if attestation_job is None:
        fail("release workflow lacks an isolated attestation job")
    attestation_text = attestation_job.group(1)
    for required in [
        "if: inputs.phase == 'promotion'",
        "needs: release",
        "permissions:\n      contents: read\n      id-token: write\n      attestations: write\n      artifact-metadata: write",
        "Resolve durable immutable promotion bytes",
        "Attest release provenance",
        "Attest checksum inventory",
        "Attest DMG SBOM",
        "Reverify bytes and record cryptographic attestation closure",
        "VELA_RELEASE_EVIDENCE_ROOT",
        "attestation-trusted-root-",
        '--trusted-root-output "${ATTESTATION_TRUSTED_ROOT}"',
    ]:
        if required not in attestation_text:
            fail(f"isolated attestation job lacks: {required}")
    release_job = release_text.split("\n  attest:\n", 1)[0]
    for forbidden_permission in (
        "id-token: write",
        "attestations: write",
        "artifact-metadata: write",
    ):
        if forbidden_permission in release_job:
            fail(f"build/preparation job has attestation permission: {forbidden_permission}")
    if "VELA_RELEASE_PRIVATE_OUTPUT}/attestation" in release_text:
        fail("sealed promotion output must not be mutated with attestation evidence")
    for forbidden in ["NOTARY_PROFILE_NAME", "login.keychain", "security default-keychain"]:
        if forbidden in release_text:
            fail(f"release workflow contains a persistent-Keychain fallback: {forbidden}")

    core_text = core.read_text(encoding="utf-8")
    for required in [
        "workflow_dispatch:",
        "environment: core-production",
        "ref: refs/tags/${{ inputs.tag }}",
        'TAG_REF="refs/tags/${RELEASE_TAG}"',
        'git cat-file -t "${TAG_REF}"',
        'git rev-parse "${TAG_REF}^{commit}"',
        "RELEASE_TAG_SIGNING_FINGERPRINT",
        'git verify-tag --raw "${TAG_REF}"',
        '$2 == "VALIDSIG"',
        "self-hosted",
        "ARM64",
        "vela-release",
        "CORE_CATALOG_ED25519_PRIVATE_KEY",
        "CORE_CATALOG_ROTATION_ED25519_PRIVATE_KEY",
        "core-catalog-ed25519.key",
        "core-catalog-rotation-ed25519.key",
        "chmod 0600",
        "Create ephemeral Core release credentials",
        "Destroy ephemeral Core release credentials and private staging",
        "if: always()",
        "prepare_core_release.sh --execute",
        "CompatibilityLab/validate_compatibility_report.py",
        '--dedicated-host-evidence "${DEDICATED_EVIDENCE}"',
        '--performance-review "${PERFORMANCE_REVIEW}"',
        "notaryProfilePrefix",
        'CORE_NOTARY_PROFILE="${CORE_NOTARY_PROFILE_PREFIX}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
        "VELA_CORE_NOTARY_PROFILE",
        "create_core_release_evidence.py",
        "validate_core_release_evidence.py",
        "Upload short-lived private Core release evidence",
        "Acquire immutable prior Core Catalog when required",
        "acquire_prior_core_catalog.sh --execute",
        "VELA_CORE_PRIOR_CATALOG",
        "--prior-catalog",
        "--rotation-private-key-file",
        'publish_core_release.sh "${PUBLISH_ARGS[@]}"',
    ]:
        if required not in core_text:
            fail(f"Core ingest workflow lacks protected release gate: {required}")
    if "pull_request:" in core_text or "pull_request_target" in core_text:
        fail("Core ingest workflow must not be triggered by pull requests")
    if "permissions:\n  contents: read" not in core_text:
        fail("Core ingest workflow must use minimal contents: read permissions")
    core_run_blocks = re.findall(r"(?ms)^\s+run:\s*\|\n(.*?)(?=^\s{6,}[A-Za-z_-]+:|\Z)", core_text)
    if any("${{ inputs." in block for block in core_run_blocks):
        fail("Core ingest workflow must pass dispatch inputs through environment variables")
    if core_text.index("Acquire immutable prior Core Catalog when required") > core_text.index(
        "Create ephemeral Core release credentials"
    ):
        fail("prior Catalog network acquisition must finish before release secrets are created")
    for forbidden in [
        "prior_catalog_url:",
        "prior_catalog_sha256:",
        "inputs.prior_catalog",
        "PRIOR_CATALOG_URL",
        "PRIOR_CATALOG_SHA256",
    ]:
        if forbidden in core_text:
            fail(
                "Core ingest workflow must not accept operator-supplied prior Catalog provenance: "
                + forbidden
            )

    acquire_prior = (root / "Release/Core/acquire_prior_core_catalog.sh").read_text(
        encoding="utf-8"
    )
    for required in [
        "core_catalog_distribution.py",
        "--production --emit priorCatalogURL",
        "--production --emit priorCatalogSHA256",
        "--production --emit priorCatalogSequence",
        "/usr/bin/curl --disable",
        "--proto '=https'",
        "--max-filesize 2097152",
        "verify_prior_core_catalog.py",
    ]:
        if required not in acquire_prior:
            fail(f"prior Catalog acquisition lacks immutable provenance gate: {required}")
    if "--location" in acquire_prior:
        fail("prior Catalog acquisition must not follow redirects away from the fixed origin")

    fetch_upstream = (root / "Release/Core/fetch_upstream_core.sh").read_text(
        encoding="utf-8"
    )
    if "/usr/bin/curl --disable" not in fetch_upstream:
        fail("upstream Core fetch must ignore the runner's ambient curl configuration")

    prepare_core = (root / "Release/Core/prepare_core_release.sh").read_text(
        encoding="utf-8"
    )
    for required in [
        "notaryProfilePrefix",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        'EXPECTED_NOTARY_PROFILE="${NOTARY_PROFILE_PREFIX}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
        '"${NOTARY_PROFILE}" == "${EXPECTED_NOTARY_PROFILE}"',
        '--dedicated-host-evidence "${DEDICATED_EVIDENCE}"',
        '--performance-review "${PERFORMANCE_REVIEW}"',
    ]:
        if required not in prepare_core:
            fail(f"Core preparation lacks per-run notarization/evidence binding: {required}")

    publish_core = (root / "Release/Core/publish_core_release.sh").read_text(
        encoding="utf-8"
    )
    for required in [
        "rotationKeyID",
        "--rotation-private-key-file",
        "--existing-envelope",
        "--require-exact-key-set",
        "--status-transitions",
        "stage_core_catalog_history.py",
        '--dedicated-host-evidence "${DEDICATED_EVIDENCE}"',
        '--performance-review "${PERFORMANCE_REVIEW}"',
    ]:
        if required not in publish_core:
            fail(f"Core publication lacks signed lifecycle gate: {required}")

    stage_history = (root / "Release/Core/stage_core_catalog_history.py").read_text(
        encoding="utf-8"
    )
    for required in [
        '"catalog-history"',
        'f"sequence-{args.sequence}"',
        "target.mkdir(mode=0o755)",
        "FileExistsError",
        "refusing to overwrite immutable Catalog history sequence",
        "validate_signature_envelope",
    ]:
        if required not in stage_history:
            fail(f"Core Catalog history staging lacks immutability gate: {required}")

    incident_text = incident.read_text(encoding="utf-8")
    for required in [
        "workflow_dispatch:",
        "environment: core-production",
        "ref: refs/tags/${{ inputs.tag }}",
        "RELEASE_TAG_SIGNING_FINGERPRINT",
        'git cat-file -t "${TAG_REF}"',
        'git verify-tag --raw "${TAG_REF}"',
        '$2 == "VALIDSIG"',
        '"catalog"]["operation"])\')" = "incident"',
        "acquire_prior_core_catalog.sh --execute",
        "CORE_CATALOG_ED25519_PRIVATE_KEY",
        "CORE_CATALOG_ROTATION_ED25519_PRIVATE_KEY",
        "publish_core_incident.sh",
        "create_core_release_evidence.py",
        "validate_core_release_evidence.py",
        "Upload short-lived private incident evidence",
        "if: always()",
    ]:
        if required not in incident_text:
            fail(f"Core incident workflow lacks catalog-only security gate: {required}")
    if "pull_request:" in incident_text or "pull_request_target" in incident_text:
        fail("Core incident workflow must not be triggered by pull requests")
    incident_run_blocks = re.findall(
        r"(?ms)^\s+run:\s*\|\n(.*?)(?=^\s{6,}[A-Za-z_-]+:|\Z)",
        incident_text,
    )
    if any("${{ inputs." in block for block in incident_run_blocks):
        fail("Core incident workflow must pass dispatch inputs through environment variables")
    if incident_text.index("Acquire immutable prior Core Catalog") > incident_text.index(
        "Create ephemeral Catalog incident credentials"
    ):
        fail("Core incident prior Catalog acquisition must finish before secrets are created")

    incident_publish = (root / "Release/Core/publish_core_incident.sh").read_text(
        encoding="utf-8"
    )
    for required in [
        'catalog.operation)" == "incident"',
        "generate_core_incident_catalog.py",
        "--prior-catalog",
        "--existing-envelope",
        "--require-exact-key-set",
        "stage_core_catalog_history.py",
    ]:
        if required not in incident_publish:
            fail(f"catalog-only Core incident publication lacks gate: {required}")

    evidence = (root / "Release/Core/core_release_evidence.py").read_text(
        encoding="utf-8"
    )
    for required in [
        "prepared/notary/notary-core-result.json",
        "prepared/notary/notary-core-log.json",
        "prepared/signed-core-identity.json",
        "reviewed/dedicated-host-evidence.json",
        "private-release-manifest.json",
        "validate_evidence_archive",
    ]:
        if required not in evidence:
            fail(f"private Core evidence archive lacks required retention material: {required}")

    notarize = (root / "Release/scripts/notarize_artifact.sh").read_text(encoding="utf-8")
    appcast = (root / "Release/scripts/generate_signed_appcast.sh").read_text(
        encoding="utf-8"
    )
    sparkle_key_validator = (
        root / "Release/scripts/validate_sparkle_private_key.py"
    ).read_text(encoding="utf-8")
    entrypoint = (root / "Release/scripts/release.sh").read_text(encoding="utf-8")
    atomic_publish = (root / "Release/scripts/atomic_publish_directory.py").read_text(
        encoding="utf-8"
    )
    if notarize.count('--keychain "${KEYCHAIN}"') < 2:
        fail("notarization submit/log must use the explicit ephemeral Keychain")
    if '--ed-key-file "${ED_KEY_FILE}"' not in appcast:
        fail("generate_appcast must use an explicit EdDSA key file")
    if "validate_sparkle_private_key.py" not in appcast:
        fail("generate_appcast must validate the exact Sparkle 2.9.4 private-key format")
    if "{64, 96}" not in sparkle_key_validator or "{32, 96}" in sparkle_key_validator:
        fail("Sparkle 2.9.4 key validation must accept 64/96 bytes and reject 32 bytes")
    for required in [
        '--prior-appcast-sha256',
        '"${ACTUAL_PRIOR_SHA256}" == "${PRIOR_APPCAST_SHA256}"',
        '--versions "${BUILD}"',
        'GENERATE_ARGS+=(--channel beta)',
        '"${SPARKLE_BIN}/sign_update" --verify --ed-key-file "${ED_KEY_FILE}" "${APPCAST}"',
        "verify_signed_appcast_artifacts.py",
    ]:
        if required not in appcast:
            fail(f"generate_appcast lacks immutable history/channel binding: {required}")
    for required in [
        '--audit-summary "${AUDIT_SUMMARY_EVIDENCE}"',
        'AUDIT_SUMMARY="${STAGE}/public/audit-summary.md"',
        'copy_public_file "${AUDIT_SUMMARY_EVIDENCE}" "${AUDIT_SUMMARY}"',
        'copy_public_file "${NOTES_FOR_SPARKLE}" "${SIGNED_RELEASE_NOTES}"',
        '--expected-release-notes "${SIGNED_RELEASE_NOTES}"',
    ]:
        if required not in entrypoint:
            fail(f"release entrypoint lacks public audit-summary boundary: {required}")
    if 'copy_public_file "${AUDIT_EVIDENCE}"' in entrypoint:
        fail("release entrypoint must keep the private audit closure out of public staging")
    for required in [
        "VELA_RELEASE_KEYCHAIN is required",
        "SPARKLE_ED_KEY_FILE is required",
        "identity auto-discovery is forbidden",
        'OTHER_CODE_SIGN_FLAGS="--keychain ${RELEASE_KEYCHAIN}"',
        '--keychain "${RELEASE_KEYCHAIN}"',
        '--ed-key-file "${SPARKLE_ED_KEY_FILE}"',
        'VELA_CORE_CATALOG_URL="${CORE_CATALOG_URL}"',
        'VELA_CORE_CATALOG_SIGNATURES_URL="${CORE_CATALOG_SIGNATURES_URL}"',
        'claim_option "--mode"',
        'claim_option "--phase"',
        'CANDIDATE_STAGE_PARENT="$(canonical_private_directory',
        'PROMOTION_OUTPUT_ROOT="$(canonical_private_directory',
        "atomic_publish_directory.py",
    ]:
        if required not in entrypoint:
            fail(f"release entrypoint lacks ephemeral credential enforcement: {required}")
    for required in [
        "open_bound_directory",
        "source_parent_fd",
        "destination_parent_fd",
        "RENAME_EXCL",
        "published destination is not the exact source directory",
    ]:
        if required not in atomic_publish:
            fail(f"exclusive release publication lacks descriptor binding: {required}")
    if "AT_FDCWD" in atomic_publish:
        fail("exclusive release publication must not re-resolve parent paths through AT_FDCWD")
    bundle_verifier = (root / "Release/scripts/verify_release_bundle.sh").read_text(
        encoding="utf-8"
    )
    for required in [
        "core_catalog_distribution.py",
        '--info-plist "${INFO}"',
        "CORE_CATALOG_ARGS+=(--production)",
        "validate_v07_acceptance.py",
        '--archive "${APP}"',
    ]:
        if required not in bundle_verifier:
            fail(f"release bundle verification lacks Core Catalog endpoint gate: {required}")
    print("GitHub workflow security validation passed.")


if __name__ == "__main__":
    main()
