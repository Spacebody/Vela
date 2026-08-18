# Vela third-party notices

Vela's release manifest and SPDX SBOM must identify every bundled third-party
component. The release gate currently knows about:

- Sparkle 2.9.4 — main license MIT, with bundled portions under MIT,
  BSD-2-Clause, and Zlib-compatible terms. The exact upstream license is stored
  at `Release/licenses/Sparkle-2.9.4-LICENSE.txt`.
- Yams 6.2.2 — MIT. The exact upstream license is stored at
  `Release/licenses/Yams-6.2.2-LICENSE.txt`.
- Mihomo v1.19.29 — GPL-3.0-only. Its pinned upstream license and notice remain
  in `Vendor/Mihomo/LICENSE` and `Vendor/Mihomo/NOTICE.md`.

The App integration must copy these exact notices into the final bundle. The
production bundle verifier intentionally fails if the Sparkle/Yams notices are
not present in the shipped App. Adding a dependency requires updating
`Release/config/third-party-components.json`, the bundled notice resources, and
the SBOM review in the same change.
