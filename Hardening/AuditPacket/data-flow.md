# Data flows and trust transitions

1. User/local profile or remote subscription bytes are untrusted. Vela applies size and
   schema limits, protected-path checks, compiles a candidate, runs `mihomo -t`, and only
   then atomically commits. Subscription URL/authentication material stays in Keychain.
2. User-mode Core control uses an ephemeral loopback HTTP/WebSocket controller and a
   session secret. Evidence must not record the secret, host data, destinations, or raw
   configuration values.
3. Privileged TUN configuration crosses authenticated XPC as bounded DTO/Data/FileHandle
   arguments. The Helper stages into a fixed root, verifies hashes and file identities,
   sanitizes configuration, commits a journaled generation, and owns the started PID.
4. App updates arrive from an HTTPS Sparkle feed but become trusted only after signed-feed,
   EdDSA, code-signing, and notarization verification. Production feed/key provisioning is
   currently Stop-Ship.
5. Core catalog/artifact bytes are untrusted until independent raw-byte Ed25519,
   sequence/expiry, hash, compatibility, thin-arm64, code-signing, and smoke checks pass.
   The production keyring/endpoints are currently Stop-Ship.
6. Help is a signed offline bundle resource validated by manifest hashes and a bounded
   parser. Support bundles are explicit local exports, redacted, previewed, bounded, and
   never uploaded automatically.
7. Reliability evidence is a bounded local ledger of stable result codes/counters. It has
   no remote scheduler and its export must pass the Support redactor and privacy scanner.
