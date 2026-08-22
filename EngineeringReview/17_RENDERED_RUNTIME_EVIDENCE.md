# Rendered Runtime Evidence

Date: 2026-08-22  
Source baseline: `d1ed1fa183300b64f83e4dd9857183e0099a7bdb`

## Method

- Hardware: MacBook Pro 14-inch (`MacBookPro18,3`), Apple M1 Pro, 10 CPU cores, 16 GB RAM.
- OS: macOS 26.5.2 (25F84).
- Toolchain: Xcode 26.6 (17F113).
- Build: unsigned optimized Debug visual fixture using the production views (`SWIFT_OPTIMIZATION_LEVEL=-O`).
- Isolation: temporary app at `/tmp/vela-release-evidence.zslvup/VelaVisualEvidence.app`; no user profile, Controller, helper, System Proxy or TUN mutation.
- Capture: 8-second traces unless noted; Activity Monitor, Time Profiler, hang and hitch instruments.
- Raw local evidence: `/tmp/Vela-ReleaseEvidence-Traces/metrics.tsv` and sibling trace bundles.

Xcode 26.6 reported no SwiftUI instrument table for these traces. Therefore this report records sampled main-thread cost, CPU, memory, hangs and hitches; it does not claim exact SwiftUI body-re-evaluation counts.

No approved absolute performance budget exists (`performanceCalibrationMissing` remains active). The closure criterion used here is observational: no reproducible steady-state stall above 250 ms and no monotonic short-run memory growth. It is not a substitute for an approved release budget or soak test.

## Overview

| Scenario | Duration | CPU avg/peak | Main thread | Memory start/peak/end | Hot symbols | Observed stall | Threshold | Conclusion |
|---|---:|---:|---:|---:|---|---|---|---|
| Connected combined launch, traffic/churn/route/node changes | 10 s | 6.89% / 55.19% | 6.21% | 26.03 / 133.67 / 129.47 MiB | Swift type instantiation 17.9 ms; localization lookup 7.6 ms | 6 launch hitches, max 550 ms | Recheck steady state; do not treat launch attach as sustained defect | Launch/attach cost observed; no persistent app hot symbol. |
| Connected steady traffic | 8 s | 0.02% / 0.09% | 0.01% | 101.08 / 101.08 / 93.09 MiB | None sampled | No hang or hitch | No reproducible >250 ms steady stall | Within observational criterion. |
| Window resize | 8 s | 0.08% / 0.21% | 0.07% | 121.00 / 121.02 / 121.00 MiB | None sampled | No hang or hitch | No reproducible >250 ms steady stall | Within observational criterion. |

## Proxies

| Scenario | Duration | CPU avg/peak | Main thread | Memory start/peak/end | Hot symbols | Observed stall | Threshold | Conclusion |
|---|---:|---:|---:|---:|---|---|---|---|
| 500 nodes | 8 s | 0.27% / 2.02% | 0.58% | 103.67 / 104.42 / 102.64 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |
| 2,000 nodes with latency updates | 8 s | 0.53% / 6.86% | 0.18% | 100.31 / 107.47 / 106.94 MiB | Visual fixture environment witness, 0.1 ms | 8 hitches, max 8.33 ms; no hang | At most one-frame transient; no >250 ms stall | No refactor gate triggered. |
| 10,000 nodes | 8 s | 0.01% / 0.04% | 0.00% | 100.67 / 100.67 / 100.47 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |
| 10,000-node scrolling | 8 s | 0.03% / 0.21% | 0.04% | 100.80 / 100.80 / 87.72 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |

## Connections

| Scenario | Duration | CPU avg/peak | Main thread | Memory start/peak/end | Hot symbols | Observed stall | Threshold | Conclusion |
|---|---:|---:|---:|---:|---|---|---|---|
| 1,000 entries with churn | 8 s | 1.18% / 4.32% | 1.21% | 112.56 / 112.56 / 107.83 MiB | None sampled | Initial 1,027.97 ms hang, 37 hitches | Must reproduce outside launch/attach | Not reproduced in steady repeat; classified as harness/attach transient. |
| 5,000 entries sort | 8 s | 0.79% / 6.94% | 0.05% | 91.75 / 109.06 / 109.00 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion; short-run allocation rise requires soak budget, not speculative refactor. |
| 10,000 entries search | 8 s | 0.14% / 0.56% | 0.17% | 78.81 / 82.19 / 82.19 MiB | None sampled | Initial 260.62 ms hang | Repeat must remain clear | Initial transient did not reproduce. |
| 10,000 entries search repeat | 8 s | 0.01% / 0.05% | 0.01% | 91.84 / 91.84 / 91.66 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |

## Rules

| Scenario | Duration | CPU avg/peak | Main thread | Memory start/peak/end | Hot symbols | Observed stall | Threshold | Conclusion |
|---|---:|---:|---:|---:|---|---|---|---|
| 10,000 rules, filter/group activity | 8 s | 0.04% / 0.21% | 0.00% | 81.50 / 83.17 / 83.17 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |
| 50,000 rules, search | 8 s | 0.01% / 0.04% | 0.01% | 100.45 / 100.45 / 90.06 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |

## Logs

| Scenario | Duration | CPU avg/peak | Main thread | Memory start/peak/end | Hot symbols | Observed stall | Threshold | Conclusion |
|---|---:|---:|---:|---:|---|---|---|---|
| 2,000 retained entries, search/filter | 8 s | 0.01% / 0.09% | 0.01% | 93.98 / 93.98 / 89.89 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |
| Inspector/selection | 8 s | 0.04% / 0.12% | 0.02% | 79.53 / 79.53 / 79.31 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |
| Export | 8 s | 0.01% / 0.06% | 0.00% | 89.69 / 89.83 / 89.80 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Export IO boundary is responsive and bounded in this run. |

Pause/resume and high-rate append are exercised by the existing bounded presentation pipeline; this pass found no separate rendered bottleneck requiring a new synthetic framework.

## Configuration Workbench

| Scenario | Duration | CPU avg/peak | Main thread | Memory start/peak/end | Hot symbols | Observed stall | Threshold | Conclusion |
|---|---:|---:|---:|---:|---|---|---|---|
| 10,000-line YAML, churn/typing/navigation | 8 s | 0.05% / 0.16% | 0.02% | 79.14 / 81.11 / 81.11 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |
| 50,000-line YAML, validation/search | 8 s | 0.02% / 0.07% | 0.01% | 89.80 / 90.02 / 90.02 MiB | None sampled | No hang or hitch | No reproducible >250 ms stall | Within criterion. |

## Runtime Conclusion

- Initial launch/trace attachment produced isolated transients in Overview and Connections.
- Repeated steady scenarios eliminated the Connections stall and showed no sustained Overview stall.
- No scenario exposed a repeatable production-code hot symbol or monotonic short-run allocation growth.
- The evidence does not justify an EngineStore split, Core lifecycle rewrite, new global state owner or page-pipeline refactor.
- Approved absolute budgets and long-run soak evidence remain release-configuration work.
