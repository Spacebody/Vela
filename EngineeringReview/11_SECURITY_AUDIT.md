# Security Audit

## Scope and method

This review covers the real trust boundaries in `Vela/Core/Privileged`, `VelaHelper`, `VelaIPC`, Core download/install, imported configuration, subscription transport and exported/runtime logging. The existing Hardening contracts remain authoritative. GitNexus's persisted PDG taint scan returned no findings, but its documented closure/property/implicit-flow limits mean that result is supporting evidence rather than a proof of absence.

## Findings

### SEC-XPC-001

- **Severity:** Verified control
- **File:** `Vela/Core/Privileged/PrivilegedXPCClient.swift`; `VelaHelper/VelaHelperSigningIdentity.swift`; `VelaIPC/VelaHelperProtocol.swift`
- **Line/Type:** XPC identity, request correlation, timeout and invalidation boundary
- **Evidence:** The app client validates the helper endpoint and correlates bounded requests; the helper checks its signing validity with Security.framework; IPC payload classes are explicitly frozen by the Objective-C protocol. The detailed request/lease evidence and tests are recorded in `06_PRIVILEGED_AUDIT.md`.
- **Impact:** A substituted helper, stale reply or unbounded request cannot silently become an authorized privileged operation through the reviewed route.
- **Fix:** Preserve the existing protocol and identity checks. Do not expand the privileged API for convenience.
- **Test:** Existing XPC timeout, interruption, identity and protocol-contract suites.
- **Status:** Verified; no P0/P1 defect found.

### SEC-CORE-001

- **Severity:** Verified control
- **File:** `Vela/Core/CoreLifecycle/CoreDownloader.swift:40-129`; `VelaIPC/Sources/VelaPrivilegedCore/PrivilegedCoreCatalogVerifier.swift`; `VelaIPC/Sources/VelaPrivilegedCore/RootCoreStore.swift:121-200`
- **Line/Type:** remote Core trust and install chain
- **Evidence:** Core downloads use an ephemeral, cookie-free, cache-free session; redirect count and URL policy are bounded; response sizes are checked while streaming; catalogue bytes are authenticated before parsing; installed files are checked against catalogue SHA-256 values; the final executable identity is re-inspected against the expected signing identifier and team.
- **Impact:** A network response, redirect or staged file does not become an executable Core solely because it downloaded successfully.
- **Fix:** None. Keep trust verification on both download and privileged promotion paths.
- **Test:** Core catalogue verifier, root Core store, download bounds, signature and rollback suites.
- **Status:** Verified; no P0/P1 defect found.

### SEC-PATH-001

- **Severity:** Verified control
- **File:** `VelaIPC/Sources/VelaPrivilegedCore/POSIXRootFileSystem.swift:118-1255`
- **Line/Type:** privileged filesystem traversal and mutation
- **Evidence:** Ancestor directories are descriptor-relative and opened with `O_NOFOLLOW`; existing entries are checked with `fstatat(..., AT_SYMLINK_NOFOLLOW)`; leaf opens also use `O_NOFOLLOW`; ownership/mode identity is rechecked around promotion and replacement operations.
- **Impact:** Imported names and staged resources cannot use symlink substitution or ordinary `..` traversal to escape the trusted root through the reviewed API.
- **Fix:** None. Retain descriptor-relative operations and reject symlinks rather than resolving them.
- **Test:** Existing path traversal, symlink, root ownership and transaction-store tests in `VelaIPC/Tests/VelaPrivilegedCoreTests`.
- **Status:** Verified; no P0/P1 defect found.

### SEC-URL-001

- **Severity:** Verified control
- **File:** `Vela/Core/Subscriptions/SubscriptionHTTPClient.swift:131-258`; `Vela/Core/CoreLifecycle/CoreDownloader.swift:40-129`
- **Line/Type:** subscription and Core URL handling
- **Evidence:** Subscription logging uses `SubscriptionURLNormalizer.maskedDescription` rather than a raw URL; the transport enforces response limits and validates status/content before conversion. Core URLs and every redirect target pass `CoreCatalogURLPolicy`, and Core responses are streamed into a bounded sink.
- **Impact:** Subscription credentials/query tokens are not intentionally emitted by the reviewed transport logs, and Core update redirects cannot bypass the catalogue URL policy.
- **Fix:** None for the reviewed paths. All future URL diagnostics must use the existing masked-description policy.
- **Test:** Subscription compatibility/header/access-denied tests and Core redirect/download bound tests.
- **Status:** Verified; no P0/P1 defect found.

### SEC-LOG-001

- **Severity:** Verified control
- **File:** `Vela/Core/Controller/MihomoControllerSession.swift:720-755`; `Vela/Core/Controller/MihomoTelemetryService.swift:149-171`; `Vela/Core/Subscriptions/SubscriptionHTTPClient.swift`; `Vela/Core/Logging/SensitiveTextRedactor.swift`
- **Line/Type:** runtime, user-visible and exported log privacy
- **Evidence:** Controller application logs are passed through the existing `SensitiveTextRedactor(context: .log)` before public OS logging and storage; telemetry payloads are redacted before creating `LogEntry`; subscription diagnostics use masked URLs. Repository search found no production `print`, `debugPrint` or `NSLog` calls in the app/helper/IPC targets.
- **Impact:** The reviewed user-visible/export path does not preserve raw subscription URLs, credentials or configuration payloads merely because the source is Mihomo or a remote server.
- **Fix:** Preserve the single redaction policy. Do not add a second sanitizer.
- **Test:** Existing log redaction/export and subscription diagnostic tests.
- **Status:** Verified; no P0/P1 defect found.

### SEC-TAINT-001

- **Severity:** P2 proof limitation
- **File:** repository-wide
- **Line/Type:** static taint coverage
- **Evidence:** `gitnexus explain` over the refreshed `--pdg` index returned zero persisted taint findings. The analyser explicitly does not model every closure/callback, property or implicit flow, so an empty result is not a security certification.
- **Impact:** A future source-to-sink regression outside the model could escape this scan even while Hardening and unit tests remain green.
- **Fix:** Keep targeted trust-boundary review and tests as the primary proof; treat PDG taint as an additive CI signal only.
- **Test:** Hardening gates plus path, XPC, URL, signature and redaction suites.
- **Status:** Accepted tooling limitation; no concrete vulnerability reproduced.

### SEC-SILENT-001

- **Severity:** P2 audit debt
- **File:** repository-wide `try?` call sites
- **Line/Type:** best-effort cleanup and fallback classification
- **Evidence:** The codebase contains numerous `try?` uses. Reviewed critical lifecycle/config/proxy cases either occur in bounded best-effort cleanup, optional decode probes or are paired with durable recovery state. Two update paths suppressed failure to persist their diagnostic terminal journal: `UpdateRecoveryCoordinator.enterRecoveryRequired` and `UpdateInstallationCoordinator.performPreparation`. Both already fail closed in memory, but the secondary persistence failure was invisible. They now emit a code-only message through the existing private `UpdateLog` categories without logging the journal, URL, profile, configuration, or localized error text.
- **Impact:** A future correctness-relevant operation could be accidentally added to a best-effort path and become silent.
- **Fix:** Preserve fail-closed behavior and explicitly diagnose secondary journal-persistence failure. Continue classifying touched `try?` sites as expected cleanup, diagnostic, retryable or correctness-critical; replace only correctness-critical suppression with the existing error models.
- **Test:** Existing update recovery/preparation state tests retain the same terminal behavior; build and Hardening verify the diagnostic-only change. Fault-injection behavior remains owned by the journal-store tests and coordinator terminal-state tests rather than a second logging abstraction.
- **Status:** Reviewed for update/configuration/Core/privileged owners. The two correctness-adjacent silent update journal writes are diagnosed; no current P0/P1 silent-failure path was identified. Remaining `try?` sites are recorded as bounded cleanup/decode probes or lower-priority owner-local review debt.

## Conclusion

The reviewed privileged, Core trust, filesystem and logging boundaries are materially hardened and must not be replaced. No known P0/P1 security defect was found. Remaining work is proof depth and disciplined classification, not a replacement security architecture.
