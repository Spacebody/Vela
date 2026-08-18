# Candidate-stage evidence and byte-identical promotion

Candidate construction and public promotion are separate operations. Building signed
artifacts does not authorize publication. The candidate-stage receipt is private,
immutable, and always records `decision=noGo` and `promotionStatus=pending`.

## Cut order

Create the receipt only after all of these inputs exist:

1. the exact clean annotated candidate tag and commit;
2. the reviewed `architecture-freeze.json`;
3. the signed and notarized App and DMG, the sealed App notarization ZIP, and their
   retained notary receipts;
4. the signed `appcast.xml` and signed release-notes artifact;
5. the external release manifest, which must bind the same DMG and appcast bytes;
6. the SPDX JSON SBOM;
7. a sealed regular-file ZIP of the complete xcarchive plus the private schema-v2 dSYM
   UUID-binding inventory; and
8. a sorted SHA-256 inventory covering every regular file below the updates root.

The checksum inventory uses `SHA256`, two ASCII spaces, then a safe path relative to
the updates root. It must end in a newline and list every regular file exactly once,
except the checksum file itself when that file lives below the updates root. Symlinks,
path escapes, special files, duplicate rows, stale rows, placeholders, and changed
files fail closed.

Run the generator from the exact candidate checkout. Example paths are illustrative:

```sh
python3 ReleaseCandidate/scripts/generate_candidate_stage_evidence.py \
  --repository-root . \
  --evidence-root /protected/candidate \
  --candidate-version 1.0.0-rc.1 \
  --build YYYYMMDDNN \
  --tag v1.0.0-rc.1 \
  --commit FULL_COMMIT_SHA \
  --architecture-freeze public/architecture-freeze.json \
  --dmg public/updates/Vela-1.0.0-rc.1-arm64.dmg \
  --app-archive private/Vela-1.0.0-rc.1-YYYYMMDDNN-app-notary.zip \
  --archive-container private/Vela-1.0.0-rc.1-YYYYMMDDNN.xcarchive.zip \
  --appcast public/updates/appcast.xml \
  --sbom public/Vela-1.0.0-rc.1.spdx.json \
  --signed-release-notes public/updates/release-notes-1.0.0-rc.1.html \
  --updates-root public/updates \
  --updates-checksums public/updates-checksums.txt \
  --app-receipt private/release-manifest-1.0.0-rc.1.json \
  --archive-receipt private/dsym-inventory.json \
  --archive-directory build/Vela.xcarchive \
  --app-notary-receipt private/notary/notary-app-result.json \
  --dmg-notary-receipt private/notary/notary-dmg-result.json \
  --sparkle-sign-update /protected/tools/sign_update \
  --sparkle-ed-key-file /protected/ephemeral/sparkle-ed-key \
  --signing-certificate-sha256 CERTIFICATE_SHA256 \
  --output private/candidate-stage-1.0.0-rc.1.json
```

The generator invokes the tracked
`Release/scripts/verify_signed_appcast_artifacts.py` against the complete updates
directory. A successful receipt records only the controlled verification status,
verifier protocol version, and exact appcast SHA-256. It never records the Sparkle key
path, key material, Keychain names, or machine-local identity. A claimed `verified`
field cannot be supplied through the CLI or copied from another receipt.

The output must be a new file below `evidence-root/private`, is created with mode
`0600`, and is never published with the update feed. Existing receipts are not
overwritten.

The archive receipt binds the archived Vela executable and embedded VelaHelper UUIDs
to exactly one matching dSYM each. It binds `Contents/Helpers/vela` only when the frozen
public contract declares the CLI present. With the current `productionCLI` absent
freeze, both the binary and a synthetic `vela.dSYM` are forbidden and absence is
recorded explicitly. UUID scans use fixed `/usr/bin/dwarfdump`, never a PATH-selected
substitute.

## Promotion

Promotion must re-read the same private receipt and every retained byte:

```sh
python3 ReleaseCandidate/scripts/validate_candidate_stage_evidence.py \
  /protected/candidate/private/candidate-stage-1.0.0-rc.1.json \
  --evidence-root /protected/candidate \
  --verify-files \
  --candidate-version 1.0.0-rc.1 \
  --build YYYYMMDDNN \
  --tag v1.0.0-rc.1 \
  --commit FULL_COMMIT_SHA \
  --architecture-sha256 ARCHITECTURE_FREEZE_SHA256
```

`--verify-files` verifies the architecture freeze, DMG, appcast, SBOM, signed notes,
sealed App archive, complete xcarchive container, external App receipt, dSYM archive
receipt, notary receipts, checksum inventory, and every updates subject. It also rejects
any newly added or removed updates file. The external manifest is cross-checked against
the exact App archive, DMG, and appcast records; the complete checksum inventory binds
the DMG, appcast, signed notes, and all other updates bytes. The sealed xcarchive is
treated as one regular immutable file, so legitimate bundle-internal symlinks are
preserved inside the container rather than rejected by a whole-tree traversal.
The validator also reopens `build/Vela.xcarchive` and revalidates every published
Mach-O/dSYM UUID and binary hash against the retained archive receipt.

Promotion does not re-sign and does not require the private Sparkle key. It verifies
that the retained, real Sparkle verification receipt is bound to the byte-identical
appcast and that all artifacts remain byte-identical. This validator still does not
claim Go: final installation results, audit closure, attestations, accountable approval,
and the separate promotion closure remain required.
