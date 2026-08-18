# Configurations and Subscriptions


Vela accepts complete Mihomo YAML, Base64-encoded Mihomo YAML, and plain or Base64-encoded
proxy link lists. Supported links include Shadowsocks, ShadowsocksR, VMess, VLESS, Trojan,
Hysteria, Hysteria2, TUIC, WireGuard, AnyTLS, Snell, and SSH.

For a link list, Vela creates a deterministic `PROXY` select group and a `MATCH,PROXY`
fallback rule. Review the generated configuration before using it when the source is not
fully trusted.

## Local configuration

Vela copies an imported source into Application Support and never edits the original. YAML
is preserved; Base64 or link-list sources are normalized into a complete Mihomo YAML copy.

## Subscription

Add an HTTPS URL and optional authentication. The URL and credentials are stored in
Keychain. Vela downloads a candidate, builds the runtime configuration, runs `mihomo -t`,
and commits only a successful update.

A server may incorrectly label valid YAML or encoded content as `text/html`; Vela inspects
the body and can still accept it. A genuine HTML page, such as a sign-in page or a GitHub
file viewer, is rejected. Use the provider's raw or download URL instead.

If validation or hot reload fails, Vela keeps the previous working revision. Open update
details or [run diagnostics](help:diagnostics-and-support).
