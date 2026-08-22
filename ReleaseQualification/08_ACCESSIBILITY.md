# Accessibility Qualification

Date: 2026-08-23

## Repository contract evidence

The focused repository lane passed 15 tests in two suites. Four critical-control
accessibility contracts verify:

- stateful accessibility labels, values and identifiers for Overview System Proxy,
  系统网卡/TUN and route-mode controls;
- pointer, assistive and keyboard activation paths for proxy-node rows;
- discoverability of Logs filters and Configuration Apply;
- Reduce Motion consumption by Overview, Proxies and Connections.

Command:

```sh
xcodebuild test \
  -project Vela.xcodeproj \
  -scheme Vela \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/Vela-RQ-Repository-Evidence-DD \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/Vela-RQ-Repository-Evidence.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:VelaTests/ProfileMigrationTests \
  -only-testing:VelaTests/CriticalControlsAccessibilityTests
```

Result: **PASS — 15 tests, 2 suites, 0 failures**. The test execution itself
completed in 3.983 seconds. The 11 migration tests are recorded separately as
repository-controlled upgrade evidence; they are not counted as accessibility
runtime coverage.

An earlier cold test-host launch took 205.578 seconds before the first contract
completed and emitted unavailable `com.apple.linkd.autoShortcut` diagnostics. The
same four-test suite then passed warm in 0.103 seconds, and the focused lane above
passed again. The delay did not reproduce and is classified as host/test
infrastructure noise, not an application assertion failure.

## Isolated rendered UI evidence

The dedicated Debug UI fixture (`dev.yilin.Vela.VisualTests`) passed four focused
rendered scenarios. Its fail-closed launch contract uses a separate preference
domain and does not access production Keychain, Helper, TUN, System Proxy or network
dependencies.

Covered scenarios:

- Overview increased contrast and Reduce Motion markers;
- Settings keyboard traversal, increased contrast and Reduce Motion;
- Help keyboard search under increased contrast and Reduce Motion;
- Core/update recovery labels, actionable controls and keyboard-accessible detail.

Result bundle: `/tmp/Vela-RQ-Accessibility.xcresult`

Result: **PASS — 4 tests, 0 failures**, 35.274 seconds of test execution.

This proves the isolated rendered UI contract. It does not substitute for VoiceOver
and focus verification on the exact signed, notarized Release candidate.

## Healthy-host runtime evidence

`NOT EXECUTED — HEALTHY SIGNED RELEASE-CANDIDATE UI HOST REQUIRED`

The previous signed-host runtime accessibility attempt stalled for 600.857 seconds
before an application assertion and was classified as infrastructure failure, not
application pass or fail. This continuation did not launch an exact signed candidate
or enable VoiceOver, and it does not claim signed-candidate keyboard/focus/Reduce-
Motion success from the isolated fixture results.

Closure requires VoiceOver labels, keyboard focus/operation, visible focus, Reduce Motion and contrast verification for network controls, route/node selectors, Core/profile operations, configuration apply and Logs controls.
