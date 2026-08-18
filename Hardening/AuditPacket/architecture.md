# Architecture and privilege overview

The authoritative machine-readable sources are
`Hardening/config/architecture-freeze.json` and
`Hardening/config/attack-surface.json`. Both are deterministically regenerated from the
Xcode project, VelaIPC constants/protocol, Release compatibility/config, embedded Core
keyring, and Mihomo/SwiftPM manifests.

Vela runs as the logged-in user and can run its bundled or verified Core as that user.
`VelaHelper` is a root launch daemon reached only through the fixed
`dev.yilin.Vela.Helper` Mach service. It authenticates the exact App identifier and
Developer Team. The Helper accepts typed, bounded DTOs and fixed-role file handles; it
does not accept an arbitrary root path, command, or PID.

The privileged store is rooted under
`/Library/Application Support/dev.yilin.Vela/Privileged`. User data is rooted under the
user-domain Application Support directory. Subscription credentials use the generic
password Keychain service category `dev.yilin.Vela.subscription`.

The App is not sandboxed. Release uses Hardened Runtime and a thin arm64 deployment. This
is an explicit audit fact, not a recommendation or waiver.
