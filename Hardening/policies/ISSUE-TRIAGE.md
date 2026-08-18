# Beta issue triage and severity

- S0: privilege/signature/trust bypass, secret exposure, arbitrary root operation, or
  supply-chain compromise. Stop-Ship immediately and use the private Security channel.
- S1: data loss/migration corruption, TUN/route/system-proxy residue, unusable network
  after rollback, crash/recovery loop, unknown PID kill, or multi-user ownership/privacy
  failure. Stop-Ship immediately.
- S2: major feature failure with safe recovery/workaround, or substantial approved
  performance, energy, or accessibility regression.
- S3: minor isolated and recoverable UI, localization, documentation, or performance bug.

Priority is scheduling and never lowers Severity. Public issues contain version/build/
channel, macOS and Apple Silicon category, App location, backend, Core/helper/protocol,
configuration source kind (not name), reproducibility, regression range, safe recovery,
Support Bundle ID (not contents), crash signature, and test/fault point. Never cluster or
deduplicate using a user's node, domain, profile, or SSID.

S0/S1 receive same-day internal assessment and feed freeze when appropriate. Security
reports must not use public issue forms.
