# Approved Visual Targets

本目录在真实 Vela 仓库中应包含：

```text
approved/<page>/<screenshot>.png
approved/<page>/<screenshot>.json
masks/<page>/<mask>.png
```

本开发包不伪造逐页高保真 Target。`reference/` 海报裁切只用于结构审计。

Target JSON 必须注册到 `visual-baseline-manifest.json`。

没有 approved target 的页面：

- 可以修功能、布局和 Accessibility；
- 不能标为视觉完成；
- 最终报告必须列为 `targetApprovalPending`。
