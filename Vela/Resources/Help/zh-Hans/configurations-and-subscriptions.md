# 配置与订阅


Vela 支持完整的 Mihomo YAML、Base64 编码的 Mihomo YAML，以及明文或 Base64 编码的
代理链接列表。支持 Shadowsocks、ShadowsocksR、VMess、VLESS、Trojan、Hysteria、
Hysteria2、TUIC、WireGuard、AnyTLS、Snell 和 SSH 链接。

对于链接列表，Vela 会确定性地生成 `PROXY` 选择组和 `MATCH,PROXY` 兜底规则。如果来源
并非完全可信，请在使用前检查生成的配置。

## 本地配置

导入后，Vela 会把内容复制到 Application Support 目录，并且不会修改原始文件。YAML
会原样保留；Base64 或链接列表来源会在副本中转换为完整的 Mihomo YAML。

## 订阅

添加 HTTPS 地址和可选鉴权信息。地址与凭据保存在钥匙串中。Vela 会下载候选配置、生成运行
配置并执行 `mihomo -t`，只有成功后才提交更新。

部分服务器会错误地把有效 YAML 或编码正文标记为 `text/html`，Vela 会检查正文并继续
解析。真正的 HTML 页面（例如登录页或 GitHub 文件展示页）仍会被拒绝，请改用供应商的
原始内容或下载地址。

如果校验或热加载失败，Vela 会继续使用上一份可用版本。可打开更新详情，或
[运行诊断](help:diagnostics-and-support)。
