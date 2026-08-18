# Known limitations policy

The authoritative machine-readable list is `config/known-limitations.json`. Each item
states security, data, and network impact, an available workaround, an owner, and a Help
topic. A limitation may be informational, low, or medium; it may never be used to accept
privilege escalation, signature bypass, secret exposure, data corruption, unsafe network
residue, rollback failure, or a crash loop.

Any such issue remains Stop-Ship and belongs in the Go/No-Go packet, not this list.
