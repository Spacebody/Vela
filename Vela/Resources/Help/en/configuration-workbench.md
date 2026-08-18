# Configuration Workbench


The Configuration Workbench compiles an effective Mihomo configuration from the upstream
configuration, Global layer, Configuration layer, Scene layer, Vela runtime values, and
the privileged sanitizer report in TUN mode.

The original configuration is never edited.

Generic layers can't change Vela-managed controller secrets, listener exposure, managed
ports, or privileged TUN safety fields.

Use the Rules Workbench to prepend or append Vela-owned rules. Every save is compiled,
validated with `mihomo -t`, and applied through a rollback-capable transaction.
