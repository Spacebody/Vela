# Public Beta operations policy

Vela uses four waves: internal dogfood, invite-only Beta, Public Beta, and Stable. The App
does not persist a cohort ID; invitations and release publication manage the audience.

Every candidate identifies an immutable build/channel, entry and exit evidence, known
issues, migration coverage, support readiness, rollback artifact, previous Stable URL,
and issue dashboard. Beta automatic update checks may be enabled only through the signed
Beta appcast; automatic installation remains off by default.

No wave may add remote analytics, automatic diagnostics/crash upload, remote feature
flags, or a silent TUN kill switch. A participant exports redacted evidence or a Support
Bundle only after explicit action.

The machine-readable criteria and current blockers are `config/beta-policy.json`,
`config/stop-ship-policy.json`, and `config/release-readiness.json`. S0/S1 and named
Stop-Ship conditions override schedule or wave size.
