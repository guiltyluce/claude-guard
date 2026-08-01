# Roadmap

## v2.0.3

基于真实长期日志加固 dry-run watchdog 的可观测性。

- paused 状态使用 30 秒成对恢复探测，避免 5 秒 tick 放大。
- runtime 日志加入 Claude PID，并区分 IP unavailable / not allowed。
- 恢复失败按里程碑降噪，日志超过 1MB 自动轮转。
- 记录 sidecar 的信号和 target-gone 退出原因。
- 保持 dry-run，不发送进程控制信号。

## v2.0.2

启动前门禁视觉升级。

- 交互 TTY 显示 8 步进度条和通过、警告、阻挡状态。
- 非 TTY 与重定向输出保持旧版纯文字契约。
- 支持 `CLAUDE_GUARD_UI`、`NO_COLOR` 和 ASCII 回退。
- 不改变 fail-closed 条件、退出码、路由、网络探测或 watchdog。

## v2.0.1

恢复 session 连续性作为默认升级策略。

- 沿用稳定官方 profile 与既有 session。
- 客户端升级不同时改变模型偏好。
- 版本化空 profile 降为可选排障模式。

## v2.0.0

最新内核的稳定灰度与强身份门禁。

- 官方 profile 按大版本隔离。
- 未授权 IP 不可绕过。
- 可拒绝 settings 固定模型。
- CC Switch 监听程序与协议身份验证。
- 客户端原包、完整性和签名归档。
- `2.1.170` 可复现回退基线。

## v0.1.0

启动前门禁。

- 出口 IP 白名单。
- 官方 API TLS/CONNECT 检查。
- IPv6 泄漏检查。
- 官方 settings 残留检查。
- 预检模式和基础测试。

## v0.2.0

Claude Session Guardian：运行中 dry-run 安全观察。

- 默认 dry-run，记录本来会 pause/resume 的动作。
- 运行时低频检查出口 IP 和 `api.anthropic.com` 官方路径。
- IP 漂移或 API 连续失败后记录 would-pause。
- 网络恢复且连续验证通过后记录 would-resume。
- 检测 macOS 休眠/唤醒 gap，恢复前强制重新验证网络路径。
- 记录本地日志，不记录 token 和会话内容。
- 拒绝不安全 action mode，避免只暂停 Claude 主 PID。

## v0.3.0

进程组 action runner 和更完整的诊断体验。

- 实现可安全暂停/恢复整个 Claude 进程组的 runner。
- 增加 `doctor` 子命令。
- 输出最近一次启动门禁报告。
- 可选生成脱敏诊断包。
