# Vela visual baselines

These images are historical review evidence kept with the UI-test target. They are
not approved targets for Visual Recovery v2.

## Safety contract

Visual captures use the strict Debug-only `-VelaVisualTestMode YES` contract with an
explicit fixture, page, state, appearance, locale, window, inspector, fixed clock,
and UUID seed. The runtime recreates a temporary application root/defaults suite and
denies live Controller/Core/subscription networking, subprocesses, Keychain,
privileged helper/TUN, System Proxy, host-interface enumeration, login-item mutation,
and automatic updater/schedulers. Malformed or incomplete controls fail closed.

Visual XCUI builds use the Debug-only `dev.yilin.Vela.VisualTests` bundle preferences
domain. The harness clears only that dedicated domain and its saved state before and
after each visual test run; it does not clear or reuse the production
`dev.yilin.Vela` domain. AppKit window and split-view restoration shadowing plus
asynchronous autosave detachment remain deterministic-capture defenses within the
dedicated test domain. The PID-scoped direct fallback has captured the current
routed matrix, while final end-to-end verification through a functioning XCTest
automation channel is still pending.

## Before

- `Before/overview-stopped-dark-960x640@2x.png`
  - Representative Overview stopped state before Visual System v1 shell changes.
  - Captured at the former 960 by 640 default size.

The pre-change app had no deterministic appearance or window-size harness. This is a
single historical representative, not a complete pre-change matrix.

## After (historical harness output)

`After/` contains 66 historical PNG attachments:

- 60 main-window captures across ten routed pages, Light/Dark, and three sizes.
- 6 independent Menu Bar, Settings, and TUN captures in Light/Dark.

They predate the latest Visual Recovery implementation and remain audit material
only. The old Profiles image expanded to 1083 by 680; the recovered Profiles layout
now has a 673-point internal minimum. These old images must not be inherited as proof
for either the current direct matrix or the pending XCTest-driven matrix.

## Current evidence

`VisualRecovery/Vela-Visual-Review-Final-20260715/` is the current direct review
evidence. It contains all 132 canonical routed scenarios: 120 main-window captures
plus 12 Menu Bar, Settings, and TUN captures. Its `coverage.json` binds the pack to
the observed dedicated Debug executable SHA-256
`e21e0697759eea7a1f7d6949aa04b5525524ff800aa696a92e695bf8a2d672d0` and records
PID-scoped Accessibility plus app-owned CoreGraphics capture boundaries. The pack
does not claim a passing XCTest result, an approved target, a visual diff, or human
approval.

`/tmp/Vela-Visual-System-Final-20260715-0430.xcresult` remains historical XCTest
capture evidence. It passed all 12 independent-surface captures: Menu Bar, Settings,
and TUN in en/zh-Hans and Light/Dark. The same historical run captured Overview at
exactly 2080 by 1360 pixels, then stopped because Proxies requested at 1040 by 680
restored a 1040 by 1387 outer window. Seven visually inspected representatives are
registered under `VisualRecovery/Audit/current/`; they remain historical evidence,
not targets or evidence of the latest executable.

The matrix now checks the requested window frame at 1pt accuracy and verifies that
the screenshot boundary matches that frame at 1x or 2x. The reference sizes are
1040 by 680, 1280 by 820, and 1600 by 1000.

The Fixture Registry contains 108 IDs, while the current UI test owns only 13
dedicated capture/data routes. Ninety-five IDs remain independently uncaptured or
uninjected. Locale, appearance, and size repetitions must not be described as full
state coverage.

## Reproduction

Run only while the macOS console session is unlocked:

```sh
xcodebuild test \
  -project Vela.xcodeproj \
  -scheme Vela \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/Vela-Visual-Recovery-Final-DD \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/Vela-Visual-Recovery-Final.xcresult \
  VELA_APP_BUNDLE_IDENTIFIER=dev.yilin.Vela.VisualTests \
  VELA_VISUAL_TEST_BUILD=YES \
  -only-testing:VelaUITests/VelaVisualSystemUITests
```

A complete green run should keep 120 main-window and 12 independent-surface capture
attachments. The current host is on-console and reports no locked-session indicator,
but XCTest times out globally with `Timed out while enabling automation mode` before
any test method or `setUp` executes. Repeated dedicated-visual-bundle smoke attempts
and a production-ID control fail identically, which isolates the current blocker to
the macOS/XCTest automation channel rather than a Vela page, startup path, or the
alternate visual bundle identifier. The full XCTest-driven 120-main-window plus
12-independent-surface matrix remains pending; the separate direct path has already
captured its 132 routed scenarios.

Visual comparison and approval remain deliberate human review steps. No PNG in this
tree is a pixel-comparison golden master.
