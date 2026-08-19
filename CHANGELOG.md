# Changelog

更完整的版本目标、设计边界和验证说明见 README 的“版本历史”部分。

## Unreleased

- 出口 IP 探测改为默认只使用 `api.anthropic.com/cdn-cgi/trace`，不再默认依赖
  `ipinfo.io` / `api.ipify.org`。按规则分流的代理（Clash、Mihomo、Surge 等）依目标
  域名选择出站策略，第三方查询域名通常落到兜底策略，导致探测到的出口与 Claude 实际
  使用的出口无关，白名单校验因此失去意义（既可能误拒，也可能漏过真实漂移）。
  默认不配兜底域名：换个 hostname 再问一次不再满足「与 API 流量同策略」这个前提，
  主端点探不到时的正确行为是 fail-closed。
- `get_current_ip_once` 同时接受裸 IP 响应体和 `/cdn-cgi/trace` 的 `key=value` 格式，
  用户仍可通过 `CLAUDE_GUARD_IP_CHECK_URLS` 覆盖为任意查询源。
- `get_current_ip_once` 不再忽略 curl 的退出状态：curl 因 `--max-time` 超时（退出码
  28）吐出包含 `ip=` 的部分响应体时不再被采信，改为按探测失败处理。
- 新增 `tests/ip_probe_format.sh`，覆盖两种响应体格式、默认值、单源默认下不触碰
  `claude.ai`、curl 部分响应加非零退出，以及 trace 解析结果不在白名单时仍然 fail-closed。

## 2.0.4 - 2026-08-01

- 新增离线 `status`，显示总体健康、活动 Claude 会话、watchdog 覆盖、PID 状态、
  日志大小和最近异常/恢复。
- 新增 `status --json` 机器可读输出。
- 新增 `doctor`，复用完整启动前门禁并在成功后追加状态快照，不启动 Claude。
- 新增离线 `diagnose`，输出脱敏环境与日志摘要；遮蔽 IPv4、HOME、绝对路径和
  常见 token/key/auth/secret 赋值。
- 安全配置支持可选布尔字段 `notify`，环境变量 `CLAUDE_GUARD_NOTIFY=0|1` 可覆盖。
- 新增可见性 fixture，覆盖零网络 status/diagnose、doctor 无模型启动、活动进程树、
  JSON 契约、脱敏和单次 pause/resume 通知。
- 保持 watchdog dry-run，不新增信号，不改变 endpoint、OAuth、profile、session、
  网络探测频率、失败阈值或 CC Switch 行为。

## 2.0.3 - 2026-08-01

- paused / resume-pending 状态改为默认每 30 秒成对探测出口 IP 与 Anthropic API，
  不再按 5 秒 watchdog tick 重复 API 探测。
- 恢复计数只接受新完成的成对健康结果，避免复用旧状态连续递增。
- runtime 日志统一加入目标 Claude PID。
- 将 IP 查询源不可用与拿到非白名单 IP 分成不同事件和 pause reason。
- 失败计数在阈值处封顶；持续恢复失败只记录首次和每第 10 次。
- 新增 HUP、INT、TERM 与 target-gone 退出原因记录。
- `guard.log` 默认超过 1MB 后并发安全地轮转为 `guard.log.1`。
- 新增真实 launcher 的 watchdog runtime 集成测试，覆盖长故障、恢复、探测上限、
  PID 归因、退出记录和日志轮转；fixture 不访问真实网络。
- 保持 dry-run，不新增 pause/resume/kill 信号，不改变官方 endpoint、OAuth、profile、
  session、启动前 fail-closed 或 Claude Code 参数。

## 2.0.2 - 2026-07-30

- 官方通道新增 8 步可视化预检，以固定宽度进度条显示检查进度。
- 新增通过、警告、阻挡状态，并在预检结束时输出结果、步数和耗时。
- 真实 TTY 中原地刷新检查状态；实现不创建 spinner 或其他后台子进程。
- 新增 `CLAUDE_GUARD_UI=auto|always|never`；默认 `auto`。
- 支持 `NO_COLOR` 和非 UTF-8 ASCII 回退。
- 非 TTY、重定向输出和 `TERM=dumb` 继续使用旧版纯文字契约。
- 新增 `tests/preflight_ui.sh`，覆盖成功、软警告、未授权 IP、退出码、自动回退和
  无颜色输出。
- 本版本不改变路由、代理、OAuth、配置目录、客户端校验、watchdog、网络请求数量
  或 fail-closed 策略。

## 2.0.1 - 2026-07-27

- 修正 `v2.0.0` 过度保守的 profile 隔离默认值。
- 官方通道默认沿用既有稳定 profile、settings、登录状态和 session，仅替换经过
  验包的 Claude Code 客户端。
- `require_unpinned_model` 在示例配置中改为 `false`，避免客户端升级同时改变
  已经稳定使用的模型偏好。
- 版本化空 profile 仍可用于独立排障，但不再作为正常升级要求。
- 明确 session resume 是 Claude Code 的正常本地功能，不将新建空 session
  描述为账号安全措施。

## 2.0.0 - 2026-07-26

- 官方通道新增版本化 `config_dir`，让新内核不自动继承旧 session、history、
  plugin cache 或 marketplace。
- 取消未授权出口 IP 的 `unsafe` 绕过，错误网络环境始终 fail-closed。
- 新增 `require_unpinned_model`，可拒绝 profile 中遗留的固定模型设置。
- CC Switch 通道新增监听进程路径、macOS Team ID、Bundle ID、应用版本验证。
- 将端点检查从根路径可达升级为可配置的 `/v1/messages` 协议探针。
- `2.1.220` 作为验包候选内核，保存原始 npm tarball、npm integrity、签名元数据、
  SHA-1、SHA-256 和 Developer ID；继续保留 `2.1.170` 回退基线。
- 新增 `tests/v2_upgrade_policy.sh`，验证 profile 隔离、模型取消固定和 IP
  fail-closed。
- 日常入口仍为 `claude` / `claude-cc`；已经运行的旧进程不会被中断。

## 1.0.0 - 2026-07-26

- 将项目从单一官方入口门禁升级为明确的双通道版本策略。
- `claude` / `claude-official` 继续进入受守护的官方 profile，并固定经过验包的客户端。
- 新增独立 `claude-cc` launcher，面向本机 CC Switch compatibility endpoint，可独立跟进较新的 Claude Code 工程能力。
- CC 通道固定客户端版本、SHA-256 和可选 macOS Team ID，关闭自动更新，升级必须经过显式验包和测试。
- CC 通道要求 base URL 与配置中的本机 loopback 端点完全一致，并在启动前检查端点可达。
- CC 通道默认要求 `PROXY_MANAGED` token 模式且 profile 不存在 `.credentials.json`，避免官方 OAuth/API 凭据混入第三方兼容链路。
- 清除父进程继承的官方路由、provider 和生命周期限制变量，再显式加载固定的 CC Switch profile。
- CC 通道关闭 telemetry、OTel exporter、非必要网络流量和自动更新，不影响核心工程能力。
- 拒绝项目设置或命令行参数覆盖 CC Switch 路由和 settings source。
- 新增 `scripts/install-cc-entrypoint.sh`、示例配置和完整 CC 通道回归测试。
- 将 Claude Code `2.1.170` 定义为重要的历史回退基线；它不是“官方安全认证版本”，也不应被自动覆盖或误删。
- 发布时验证的双通道客户端为 `2.1.220`；模型是否出现或可用仍由对应服务端/网关决定。
- 移除旧版硬编码模型名称拦截，改为可选 `blocked_models` 清单，避免模型代际更新后 Guard 误伤新模型。

## 0.2.4 - 2026-07-26

- 新增生命周期 fail-closed：要求关闭 background agents、background tasks、cron、dynamic workflows、Remote Control、deep-link registration 和自动更新。
- 拒绝 `--bg`、`claude agents`、Remote Control、额外 `--settings` 与 `--setting-sources` 覆盖。
- 新增当前项目 settings 扫描，阻止项目级 base URL、凭据、代理、CA、provider 和 retry watchdog 注入。
- 新增客户端 `client_version`、`client_sha256` 与 macOS `client_macos_team_id` 可选固定校验。
- 新增 `blocked_plugins`，可拒绝已知会派生 detached process 的插件；本机官方 profile 将 `codex@openai-codex` 列入阻止清单。
- 要求 `CLAUDE_CODE_RETRY_WATCHDOG` 不存在，避免无人值守时产生长时间自动重试。
- 限制子代理嵌套深度和并发数，并关闭 MCP 自动后台化。
- 风险设置报告只打印键路径，不再回显可能包含 token 的整行。
- 新增生命周期策略、项目设置污染、CLI 绕过、客户端身份与前台退出 sidecar 清理测试。
- 明确政策边界：不清洗指纹、不改写请求、不规避封禁，也不保证账号状态。

## 0.2.3 - 2026-07-01

- 开源发布整理：新增 MIT License、Contributing、Security Policy 和 GitHub Actions 检查。
- 将 README、示例配置、测试和技术文档中的本机路径 / 真实 IP 改为通用占位。
- 移除脚本里的本机用户名默认值。

## 0.2.2 - 2026-07-01

- 新增 `scripts/install-entrypoint-shims.sh`，把 `claude` 与 `claude-official` 两个入口统一收敛到同一个 `claude-guard`。
- 安装入口 shim 前自动备份旧文件，默认备份后缀为 `.bak-before-claude-guard-v0.2.2`。
- 将“入口收敛”与 `v0.2.1` 的客户端指纹 tripwire 分开发布，避免版本语义混在一起。
- 新增入口 shim 安装 smoke test。

## 0.2.1 - 2026-07-01

- 新增客户端 date/time watermark tripwire。
- 默认 `CLAUDE_GUARD_FINGERPRINT_MODE=fail-active`，只在已知 watermark-capable 客户端与激活条件同时存在时拒绝启动。
- 新增 `CLAUDE_GUARD_LEGACY_PROFILE_MODE=warn`，提示 `~/.claude/settings.json` 的旧 CC Switch/base URL 残留，但不阻断官方隔离入口。
- 新增 active/strict 指纹检测回归测试。

## 0.2.0 - 2026-07-01

- 新增运行中 dry-run guardian。
- 默认低频检查出口 IP 和 `api.anthropic.com` 官方路径。
- 新增 sleep/wake gap 检测。
- 新增本地日志 `~/.claude-guard/guard.log`。
- 新增 dry-run pause/resume 决策记录。
- 新增备用 IP 查询源，默认从 `ipinfo.io` fallback 到 `api.ipify.org`。
- 新增 `allowed_cidrs` 支持，固定节点换末段 IP 时可降低误伤。
- dry-run 运行中告警默认只写日志；需要 TUI 提示时可设置 `CLAUDE_GUARD_DRY_RUN_STDERR=1`。
- macOS 通知默认关闭；需要通知时可设置 `CLAUDE_GUARD_NOTIFY=1`。
- 明确拒绝不安全 action mode，避免只暂停 Claude 主 PID。
- 修复 Clash/Mihomo fake-ip `::ffff:198.18.x.x` 被误判为公网 IPv6 泄漏的问题。
- 新增 watchdog 状态机测试。

## 0.1.0 - 2026-06-28

初始版本。

- 新增 `claude-guard` 启动前门禁。
- 支持出口 IP 白名单检查。
- 支持官方 API TLS/CONNECT 检查。
- 支持 IPv6 泄漏检查。
- 支持官方 settings 高风险残留检查。
- 支持 `--precheck-only`、`--version`、`--help`。
- 新增安装脚本、示例配置、smoke test。
