# UI and Rendered Runtime Qualification

Date: 2026-08-22
Source baseline: `bcc0c25b15535edf2930b5bfc2f2e9b15226c949`

## Evidence reused

`EngineeringReview/17_RENDERED_RUNTIME_EVIDENCE.md` measured the same production source because drift from its source to this baseline is documentation-only. Its isolated Overview, Proxies, Connections, Rules, Logs and Workbench traces found no sustained CPU, MainActor, memory or stall threshold breach. This run did not create a second profiler framework.

## Current regression gate

The initial full suite exposed a stale visual-route contract: production route `overview.loadedHealthy` is now valid, while the test still expected rejection. The source route was correct. The test now proves the supported route resolves to production feature views and unsupported `overview.loading` remains rejected. Focused `VisualUITestConfigurationTests` passes; no production UI code changed.

## Live visual scope

No signed exact candidate was launched. Minimum-window, 1280×800, 1440×900, continuous resize, real traffic, long-name/international-text and page-by-page manual checks are therefore not claimed. They remain candidate-host work.

No new measured UI performance regression was reproduced, so no architecture or feature-view refactor was made.
