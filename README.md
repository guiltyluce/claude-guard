# Claude 守护

[![check](https://github.com/wetlink/claude-guard/actions/workflows/check.yml/badge.svg)](https://github.com/wetlink/claude-guard/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Claude 守护是一套 Claude Code 双通道版本与启动策略。它让官方 Claude
通道保持严格、可审计和固定版本，同时允许本机 CC Switch 通道独立跟进较新的
Claude Code 工程能力。两条通道共享客户端形态，但不共享 profile 和路由。

当前版本：`2.0.4`

> 本项目不是 Anthropic 或 Claude Code 官方项目。

## v2.0 稳定升级架构

| 入口 | 用途 | Profile | 请求目标 | 客户端策略 | 生命周期策略 |
| --- | --- | --- | --- | --- | --- |
| `claude` / `claude-official` | 官方 Claude 模型 | 显式固定的稳定官方 profile | `api.anthropic.com` | 固定经过验包的版本 | 前台 fail-closed |
| `claude-cc` | 本机 CC Switch 兼容链路 | 独立 CC Switch profile | 固定 loopback endpoint | 独立跟进经过验包的新版本 | 保留工程能力 |

核心边界：

- 官方通道不读取 CC Switch 的 base URL 或 token；`v2.0.1` 默认沿用原稳定
  profile、settings 和 session，只替换经过验包的客户端内核。
- CC Switch 通道不加载官方 profile 或文件凭据。macOS Keychain 是系统级边界，
  因此最终以实际 endpoint 和进程身份验证为准，不把“文件不存在”当作唯一证明。
- 官方通道继续检查出口 IP、HTTP CONNECT、TLS issuer、IPv6 和生命周期策略。
- CC Switch 通道检查客户端身份、本机 endpoint、监听进程路径、签名、Bundle ID、
  应用版本、profile 路由和 credentials 污染；它不会把第三方兼容链路描述成
  Anthropic 官方链路。
- 两条通道都关闭客户端自动更新。任何版本切换都必须先验版本、SHA-256、
  macOS 签章和回归测试，再修改固定指针。
- CC Switch 通道有意保留 background agent、plugin、hook 等工程能力，因此它
  不受官方通道的前台 fail-closed 生命周期保护；后台任务应由使用者明确启动和
  回收。
- CC Switch 通道关闭 telemetry、OTel exporter、非必要网络流量和自动更新，
  但不关闭核心推理、工具、agent、plugin 或 hook。

发布 `v2.0.0` 时，[Claude Code 验证版本](https://github.com/anthropics/claude-code/releases/tag/v2.1.220)
是 `2.1.220`。这只是本次发布的验证矩阵，不代表仓库永远把某个版本写死为
“最新”。

客户端切换不会中断已经运行的旧进程，只在下一次执行 `claude` 时生效。

## 为什么必须保留 2.1.170

`2.1.170` 是本项目的重要历史回退基线：

- 它记录了双通道架构建立前已经长期实际运行过的客户端行为。
- 新版本发生 TUI、TLS、session resume、插件、background process 或 gateway
  兼容性回归时，可以用它区分“客户端变化”和“网络/服务端变化”。
- 它适合作为短期诊断与回滚参照，不应被自动更新程序覆盖，也不应在升级时删除。

这里的“重要”不等于 Anthropic 官方安全认证，也不表示 `2.1.170` 永远优于新版本。
它是一份可复现基线。项目不会把二进制提交进 Git 仓库；维护者应在本机安全目录
保存原始包、二进制 SHA-256、签章信息和恢复说明。

## 客户端、模型与政策是三件事

- 客户端升级带来 CLI、TUI、tools、plugin、agent 和稳定性修复。
- 模型是否出现在选择器、能否调用、名称如何映射，由对应服务端或网关决定。
- 使用哪个账号、凭据和服务必须符合对应服务的条款。

因此，升级 `claude-cc` 不会自动让某个模型可用，也不会改变官方 Claude 通道的
账号状态。`claude-cc` 只允许本机 CC Switch profile，不应放入 Anthropic 官方
OAuth token。项目不提供封禁规避、token 转发或风控绕过能力。

## 官方通道做什么

官方通道继承 `v0.2.4` 的启动前门禁、客户端指纹 tripwire、生命周期
fail-closed 策略和运行中 dry-run guardian。启动 Claude Code 前会检查：

- 当前出口 IP 是否在 `allowed_ips` 或 `allowed_cidrs` 白名单中。
- 未授权出口直接 fail-closed；`v2.0.0` 不再提供 `unsafe` 绕过。
- Claude 官方 API 是否通过指定代理的 HTTP CONNECT 隧道访问。
- TLS 证书是否由正常公共 CA 签发，且未出现 Charles、mitmproxy、Fiddler、ZScaler 等中间人痕迹。
- `api.anthropic.com` 是否无法通过公网 IPv6 直连，确保官方链路压在 IPv4；Mihomo/Clash fake-ip 的 `::ffff:198.18.x.x` 不会被误判为公网 IPv6。
- 官方 profile 的 `settings.json` 是否包含 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`apiKeyHelper`、`127.0.0.1:15721`、`PROXY_MANAGED` 等高风险残留。
- 原始 Claude Code 客户端是否存在异常的 date/time 相关注入逻辑；如同时存在 `ANTHROPIC_BASE_URL` 或高风险时区等激活条件，则拒绝启动。
- 模型参数是否命中本机显式配置的 `blocked_models`；未列入的模型名称交由
  官方服务端判断，不在 Guard 中硬编码猜测。
- 可选要求官方 settings 不固定 `model`，让客户端升级后使用新的模型选择结果；
  单次模型选择仍可通过 `--model` 显式传入。
- 客户端版本、SHA-256，以及 macOS 上可选的 Anthropic Team ID 是否与安全配置一致。
- 官方 settings 是否明确关闭 background agents、background tasks、cron、dynamic workflows、Remote Control、deep-link registration 和自动更新。
- 当前项目的 `.claude/settings.json` / `.claude/settings.local.json` 是否试图覆盖官方路由、证书、凭据、重试或生命周期策略。
- 命令行是否试图通过 `--settings`、`--setting-sources`、`--bg`、`agents` 或 `remote-control` 绕过守门。
- `blocked_plugins` 中列出的、已知会使用 detached process 的插件是否被启用。

启动后会默认启动 dry-run guardian：

- 每 60 秒低频检查出口 IP。
- 每 180 秒低频检查 `api.anthropic.com` 官方路径。
- 进入逻辑 paused 状态后，每 30 秒成对检查一次 IP 与 API，不再跟随 5 秒 tick
  重复探测。
- 检测长时间 sleep/wake gap。
- 记录“本来会 pause/resume”的动作，默认只写日志，不污染 Claude Code TUI。
- 每条运行中日志带目标 Claude PID，区分 IP 查询不可用和实际非白名单出口。
- 写入本地日志 `~/.claude-guard/guard.log`；超过 1MB 自动轮转为 `guard.log.1`。

它不会调用模型，不会使用账号 token，也不会消耗 Claude 额度。

## 不做什么

Claude 守护只做本地启动前检查和 dry-run 观察。它不做：

- TLS 中间人解包。
- Claude 请求转发、清洗或改写。
- `ANTHROPIC_BASE_URL` 改写。
- OAuth token 提取或转交第三方客户端。
- timezone、locale、设备指纹伪装。
- 风控标记清洗、归因字段移除或封禁规避。

请只在符合服务条款和本地法规的场景中使用。守门程序只能降低本机配置和进程生命周期风险，不能保证账号不会被限制，也不能把换号绕过封禁变成合规行为。

## 版本历史

### 2.0.4 - 可见性维护

`2.0.4` 在 `2.0.3` 的低噪声日志基础上增加本地状态、主动诊断和脱敏报告。
本版本不改变门禁、路由、OAuth、profile、session、探测阈值或 dry-run 边界。

主要更新：

- `claude-guard status` 离线读取进程表与 Guard 日志，显示 `OK/WARN/IDLE`、活动
  Claude 会话、watchdog 覆盖、每个 PID 的最近状态和历史异常/恢复。
- `claude-guard status --json` 提供相同快照的机器可读格式，方便后续本地工具集成。
- `claude-guard doctor` 复用原有 8 步官方链路预检，成功后追加运行时快照；不会
  启动 Claude，也不会调用模型。
- `claude-guard diagnose` 完全离线生成可分享的脱敏摘要，隐藏真实 IPv4、HOME、
  绝对路径和常见 token/key/auth/secret 赋值。
- 安全配置新增可选布尔字段 `notify`；也可用 `CLAUDE_GUARD_NOTIFY=0|1` 覆盖。
- pause/resume 通知继续只跟随状态转换触发，不按 watchdog tick 重复发送。
- 新增 fake Claude、fake curl 和临时进程树 fixture，验证离线命令不访问网络、
  doctor 不启动客户端、脱敏输出不泄漏敏感值、通知不重复。

详细命令、输出语义和脱敏边界见
[`docs/v2.0.4-visibility.md`](docs/v2.0.4-visibility.md)。

### 2.0.3 - Watchdog 观测加固

`2.0.3` 根据真实长期日志收敛 dry-run watchdog 的探测与记录方式。本版本仍不发送
pause、resume 或 kill 信号，不改变启动前门禁、官方路由、OAuth、客户端或 session。

主要更新：

- paused / resume-pending 状态改为每 30 秒执行一次成对 IP+API 恢复探测，取消
  原先每个 5 秒 tick 重复 API 探测的放大行为。
- 恢复计数只在完成一轮新的 IP+API 探测后递增，避免复用旧结果过早判定恢复。
- 所有 runtime 日志加入目标 Claude PID，多终端会话可以分别归因。
- 将 `exit ip unavailable` 与 `exit ip not allowed` 分开，避免把查询源失败描述成
  真实出口漂移。
- 失败计数在阈值处封顶；恢复失败只记录首次与每第 10 次，降低日志噪声。
- HUP、INT、TERM 和目标进程消失都会写入明确退出原因。
- 日志默认超过 1MB 后轮转为 `guard.log.1`，使用目录锁避免多个 watchdog 同时轮转。
- 新增实际 launcher + fake Claude + fake curl 的 runtime 集成测试，全程不访问网络。

详细设计和兼容边界见
[`docs/v2.0.3-watchdog-observability.md`](docs/v2.0.3-watchdog-observability.md)。

### 2.0.2 - 启动前门禁视觉升级

`2.0.2` 只升级官方通道的预检呈现，不改变任何安全策略、网络路径、OAuth、
watchdog 或 Claude Code 启动参数。

主要更新：

- 交互终端中将既有门禁整理为 8 个清晰步骤，以固定宽度进度条显示当前进度。
- 使用 `✓`、`!`、`×` 区分通过、可继续的警告和阻挡，并在结尾显示总结果。
- 检查中状态在真实 TTY 内原地刷新，不启动 spinner 子进程，也不增加网络请求。
- `CLAUDE_GUARD_UI=auto|always|never` 可控制呈现；默认 `auto`。
- 支持 `NO_COLOR`，并在非 UTF-8 终端回退为 ASCII 状态符号。
- 非 TTY、重定向输出和 `TERM=dumb` 自动保留旧版纯文字输出，方便日志与自动化解析。
- 未授权 IP、TLS、IPv6、客户端身份和生命周期策略的 fail-closed 条件及退出码均保持不变。

详细行为、兼容矩阵和安全边界见
[`docs/v2.0.2-preflight-ui.md`](docs/v2.0.2-preflight-ui.md)。

### 2.0.1 - Session 连续性修正

`2.0.1` 将稳定官方 profile 和既有 session 视为升级基线。升级客户端不再默认
切换到空 profile；官方的 `--continue`、`--resume` 和 `/resume` 行为保持可用。

主要更新：

- 示例配置默认继续使用既有 `~/.claude-official`。
- 旧 settings、登录状态、项目历史和 session 保持原位，不复制、不迁移。
- `require_unpinned_model` 默认关闭，避免升级同时改变用户已经稳定使用的模型设置。
- 版本化空 profile 保留为可选排障方式，不作为日常升级要求。
- 新内核仍需通过版本、SHA-256、签章、IP、TLS、IPv6 和生命周期门禁。

详细说明见
[`docs/v2.0.1-session-continuity.md`](docs/v2.0.1-session-continuity.md)。

### 2.0.0 - 最新内核的稳定灰度

`2.0.0` 在不改变日常命令的前提下，把最新内核升级从“修改一个二进制路径”
提升为可回滚、可验包、可隔离会话的发布流程。

主要更新：

- 官方通道支持由安全配置指定版本化 `config_dir`；旧 history、session 和插件
  不会自动进入新内核。
- 删除未授权 IP 的 `unsafe` 交互绕过。
- 可要求官方 settings 不固定模型，避免旧模型 pin 覆盖新版默认选择。
- CC Switch 通道新增监听程序路径、Team ID、Bundle ID、应用版本和
  `/v1/messages` 协议探针。
- `2.1.220` 保存原始 npm 包、SHA-1、SHA-256、npm integrity、签名元数据和
  macOS Developer ID；`2.1.170` 继续保留为历史回退基线。
- 新增 `v2_upgrade_policy` 回归测试，验证新 profile、模型取消固定和 IP
  fail-closed。

详细行为与使用影响见
[`docs/v2.0.0-staged-latest-kernel.md`](docs/v2.0.0-staged-latest-kernel.md)。

### 1.0.0 - 双通道版本策略

`1.0.0` 将“官方 Claude 安全入口”和“CC Switch 工程入口”从隐含约定提升为
仓库内可测试、可安装、可回滚的正式架构。

主要更新：

- 新增 `bin/claude-cc` 和 `scripts/install-cc-entrypoint.sh`。
- CC 通道固定独立客户端版本、SHA-256 和可选 macOS Team ID。
- 要求 CC Switch base URL 与配置中的 loopback endpoint 完全一致。
- 启动前确认本机 CC Switch endpoint 可达。
- 默认要求 `PROXY_MANAGED` token 模式，拒绝 profile 中出现官方 credentials。
- 清理从官方入口继承的路由、provider 和生命周期变量。
- 阻止项目 settings 和 CLI settings 参数改写 CC Switch 路由。
- 建立 `2.1.170` 历史回退基线与新版本验包流程。
- 移除旧版硬编码模型名称判断，改为可选 `blocked_models` 清单。
- 新增双通道回归测试，并继续保留 `v0.2.4` 的官方前台生命周期保护。

详细设计与升级边界见
[`docs/v1.0.0-dual-lane-version-policy.md`](docs/v1.0.0-dual-lane-version-policy.md)。

### 0.2.4 - 前台生命周期 Fail-Closed

`0.2.4` 解决终端退出后 Claude 或其扩展仍可能继续运行的问题。默认策略是在官方 `processWrapper` 方案完成独立验证前，只允许受守护的前台会话。

主要更新：

- 关闭 background agents、background tasks、cron、dynamic workflows、Remote Control、deep-link registration、hooks 和自动更新。
- 拒绝 `--bg`、`--background`、`claude agents`、`--tmux`、Remote Control，以及额外 `--settings` / `--setting-sources` 覆盖。
- 扫描当前项目的 settings，阻止 base URL、凭据、代理、CA、provider、retry watchdog 或生命周期降级配置。
- 支持固定客户端版本、SHA-256 和 macOS Team ID，更新必须先验包再切换。
- 支持 `blocked_plugins`；已知使用 detached process 的插件可以在启动前被拒绝。
- 阻止 `CLAUDE_CODE_RETRY_WATCHDOG`，关闭 MCP 自动后台化，并限制子代理嵌套深度和并发数。
- 新增真实 PTY close 验收，确认终端断开后没有 Claude supervisor、worker 或同进程组 sidecar 残留。
- 风险报告只输出设置键路径，不回显可能包含 token 的配置行。

边界说明：

- 继续使用官方 Claude Code、官方 OAuth 和 `api.anthropic.com`；网络层仍是端到端 TLS 的 HTTP CONNECT。
- 不修改请求正文、客户端归因、timezone、locale 或设备指纹。
- 不提供封禁规避能力，也不承诺账号不会受到平台限制。
- `watchdog` 仍为 dry-run；本版本通过关闭可脱离终端的入口来收敛风险，不实现不可靠的单 PID pause/kill。

验证：

- `./scripts/check.sh`
- `python3 scripts/verify-terminal-exit.py`
- 客户端版本、SHA-256 和 macOS Developer ID 签名核对。
- 无模型 prompt 的官方 IP/TLS/IPv6 预检。

### 0.2.3 - 开源发布整理

`0.2.3` 是首个公开发布版本，重点是把原本面向个人本机环境的项目整理成可以公开阅读、复用和贡献的开源仓库。

主要更新：

- 新增 MIT License，明确项目可以被复制、修改、分发和二次使用。
- 新增 `CONTRIBUTING.md`，说明如何提交 issue、PR、测试变更和处理文档更新。
- 新增 `SECURITY.md`，说明安全问题报告方式，以及本项目不接收 token、凭据、真实账号配置等敏感信息。
- 新增 `CODE_OF_CONDUCT.md`，补齐公开协作的基本行为约束。
- 新增 GitHub Actions workflow，push 和 PR 时自动运行 `./scripts/check.sh`。
- 将 README、示例配置、测试和技术文档中的本机路径、真实出口 IP、个人用户名等内容替换成通用示例。
- 移除脚本里的本机用户名默认值，避免新用户在默认环境里看到个人机器痕迹。

边界说明：

- 这是开源整理版本，不改变 `claude-guard` 的核心启动逻辑。
- 不新增请求转发、TLS 解包、base URL 改写、token 托管或指纹伪装能力。
- 公开仓库使用干净的单提交历史发布，避免把早期本机调试历史带入公共仓库。

验证：

- `./scripts/check.sh`
- GitHub Actions `check`
- fresh clone 后重新运行 smoke test 和敏感痕迹扫描。

### 0.2.2 - 入口收敛

`0.2.2` 解决的是入口一致性问题：避免用户有时从 `claude` 进入、有时从 `claude-official` 进入，导致其中一条路径绕过 guard。

主要更新：

- 新增 `scripts/install-entrypoint-shims.sh`。
- 将 `claude` 与 `claude-official` 两个入口统一收敛到同一个 `claude-guard` wrapper。
- 安装 shim 前自动备份已有入口，默认备份后缀为 `.bak-before-claude-guard-v0.2.2`。
- 保持原始 Claude CLI 路径写在配置文件的 `command` 字段里，避免 wrapper 递归调用自己。
- 新增入口 shim 安装 smoke test，验证 shim 可以正确生成并指向 guard。

设计意图：

- `0.2.2` 只处理“入口从哪里进”的问题。
- 客户端指纹检查仍归属于 `0.2.1`。
- 运行中 guardian 仍归属于 `0.2.0`。
- 这样每个版本的风险边界更清楚，回滚时可以按入口、指纹、watchdog 分层处理。

边界说明：

- 入口 shim 不改变 Claude Code 的请求目标。
- 入口 shim 不写入 `ANTHROPIC_BASE_URL`、不托管 OAuth token，也不替代官方 Claude CLI。

### 0.2.1 - 客户端指纹 Tripwire

`0.2.1` 新增客户端指纹预检，用来在启动前发现高风险客户端环境，而不是在请求已经发出后再补救。

主要更新：

- 新增 date/time watermark tripwire。
- 新增 `CLAUDE_GUARD_FINGERPRINT_MODE`，默认值为 `fail-active`。
- 新增 `CLAUDE_GUARD_LEGACY_PROFILE_MODE=warn`，用于提示旧 `~/.claude/settings.json` 中可能存在的 CC Switch/base URL 残留。
- 新增 active/strict 指纹检测回归测试。

默认判定逻辑：

- 如果当前 Claude Code 包没有已知 date/time watermark 逻辑，直接通过。
- 如果包含已知逻辑，但当前官方启动环境干净，只警告并继续。
- 如果包含已知逻辑，且当前环境存在 `ANTHROPIC_BASE_URL` 或高风险时区等激活条件，则拒绝启动。

可选模式：

- `off`：完全关闭该检查。
- `warn`：只提示风险，不阻断启动。
- `fail-active`：只在 watermark-capable 客户端和激活条件同时存在时阻断。
- `strict`：只要客户端含有已知逻辑就阻断。

边界说明：

- 该版本只做启动前风险判断。
- 不读取、清洗、转发或改写 Claude Code 发出的请求。
- 不尝试伪装 timezone、locale、设备指纹或系统环境。

### 0.2.0 - 运行中 Dry-Run Guardian

`0.2.0` 是从“启动前检查”扩展到“运行中观察”的版本。它关注 coffee time、休眠唤醒、网络波动、出口漂移等启动后才会发生的问题。

主要更新：

- 新增运行中 dry-run guardian。
- 默认每 60 秒低频检查出口 IP。
- 默认每 180 秒低频检查 `api.anthropic.com` 官方路径。
- 新增 sleep/wake gap 检测，识别长时间休眠、断网或系统暂停后的恢复场景。
- 新增本地日志 `~/.claude-guard/guard.log`。
- 新增 dry-run pause/resume 决策记录：记录“如果 action mode 可用，本来会 pause/resume”的状态变化。
- 新增备用 IP 查询源，默认从 `ipinfo.io` fallback 到 `api.ipify.org`。
- 新增 `allowed_cidrs` 支持，适合固定节点偶尔更换末段 IP 的场景。
- 修复 Clash/Mihomo fake-ip `::ffff:198.18.x.x` 被误判为公网 IPv6 泄漏的问题。
- 新增 watchdog 状态机测试。

默认行为：

- guardian 默认只观察和记录，不会暂停、恢复或 kill Claude Code。
- 运行中告警默认只写日志，不向 Claude Code TUI 输出内容。
- 如需终端提示，可设置 `CLAUDE_GUARD_DRY_RUN_STDERR=1`。
- 如需 macOS 通知，可在安全配置中设置 `"notify": true`，或临时设置
  `CLAUDE_GUARD_NOTIFY=1`。

边界说明：

- `0.2.0` 有意拒绝不安全 action mode。
- 如果用户设置 `CLAUDE_GUARD_WATCHDOG_DRY_RUN=0`，当前版本会拒绝启动 action mode，而不是给出虚假的保护。
- 真正 pause/resume 必须由未来的 process-group runner 实现，确保 Claude 主进程和其子进程一起暂停或恢复。

### 0.1.0 - 启动前门禁

`0.1.0` 是初始版本，目标是在 Claude Code 启动前做一组 fail-closed 检查，避免在明显不安全或不符合预期的网络/配置环境里启动官方 Claude Code。

主要更新：

- 新增 `bin/claude-guard`。
- 支持从配置文件读取原始 Claude CLI 绝对路径。
- 支持出口 IP 白名单检查。
- 支持官方 API TLS/CONNECT 检查。
- 支持 IPv6 泄漏检查。
- 支持官方 settings 高风险残留检查。
- 支持 `--precheck-only`，只运行预检，不启动 Claude Code。
- 支持 `--version` 和 `--help`。
- 新增安装脚本、示例配置和 smoke test。

启动前检查覆盖：

- 当前出口 IP 是否在 `allowed_ips` 白名单内。
- `command` 是否是原始 Claude CLI 的绝对路径，避免递归调用 wrapper。
- `api.anthropic.com` 的 TLS 证书是否正常。
- 是否存在中间人证书、异常 issuer 或代理解包迹象。
- 是否存在公网 IPv6 泄漏。
- 官方 profile 的 settings 是否含有 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN`、`apiKeyHelper`、`PROXY_MANAGED` 等高风险残留。

边界说明：

- 初始版本只负责启动前检查。
- 不做运行中监控。
- 不管理 Claude Code 进程生命周期。
- 不替代用户的代理、VPN 或 Clash/Mihomo 配置。

## 安装

```bash
./scripts/install.sh
```

默认安装到：

```bash
~/.local/bin/claude-guard
```

如果要把日常入口也收敛到同一套 guard：

```bash
./scripts/install-entrypoint-shims.sh
```

它会安装或更新：

```bash
~/.local/bin/claude
~/.local/bin/claude-official
```

两个入口都会先进入 `~/.local/bin/claude-guard`。安装前会自动备份旧入口，默认备份后缀会跟随当前版本，例如 `.bak-before-claude-guard-v2.0.0`。

`v0.2.2` 只负责入口收敛；`v0.2.1` 负责客户端指纹 tripwire。这样两个风险边界分开，后续回滚也更清楚。

安装独立 CC Switch 入口：

```bash
./scripts/install-cc-entrypoint.sh
```

它只安装 `~/.local/bin/claude-cc`，不会修改 `claude`、官方 profile 或 CC Switch
应用本身。

## 配置

### 官方通道

复制示例配置：

```bash
cp config/safe-claude.example.json ~/.safe-claude-official.json
```

然后把 `command` 改成原始 Claude CLI 的绝对路径，不能写 `claude`，也不能写当前 wrapper 路径，否则会递归。

示例：

```json
{
  "command": "/usr/local/bin/claude",
  "config_dir": "/Users/your-name/.claude-official",
  "allowed_ips": ["203.0.113.10"],
  "allowed_cidrs": ["203.0.113.0/24"],
  "client_version": "2.1.220",
  "client_sha256": "<replace-with-the-reviewed-binary-sha256>",
  "client_macos_team_id": "Q6L2SF6YDW",
  "blocked_plugins": ["codex@openai-codex"],
  "blocked_models": [],
  "require_unpinned_model": false,
  "notify": false
}
```

`203.0.113.0/24` 是文档示例网段。实际使用时请替换成你自己的固定出口 IP 或 CIDR。

出口探测默认只打 `api.anthropic.com/cdn-cgi/trace`，而不是第三方 IP 查询服务。原因是
Clash、Mihomo、Surge 这类按规则分流的代理会依据目标域名选择出站策略：如果探测打的是
`ipinfo.io`，它很可能落到兜底策略，量到的是另一条线路的出口，和 Claude 实际使用的出口
无关。打 API 自己的域名，探测流量与 API 流量命中同一条分流策略（在固定／黏性出口下即
同一出口；策略组是 url-test 或负载均衡时，同一条策略的两次请求仍可能出不同 IP）。

默认不配任何兜底域名。换一个 hostname 再问一次就不再满足「与 API 流量同策略」这个前提，
拿一条不确定链路的出口去判定白名单，正是这里要避免的问题；主端点探不到时的正确行为是
fail-closed（退出码 3）。

如果要换回第三方查询源或自行添加兜底，`CLAUDE_GUARD_IP_CHECK_URLS` 同时支持裸 IP 响应体
和 `/cdn-cgi/trace` 的 `key=value` 格式；但请自行确认这些域名在你的代理配置里与
`api.anthropic.com` 走同一条策略，否则白名单校验的是错误链路。

客户端身份字段是可选的，但安全入口建议全部填写。更新 Claude Code 时应先离线核对新版本、哈希和签名，再一起更新配置；`v2.0.0` 会把不匹配视为失败，不会静默运行新二进制。

`blocked_models` 只用于阻止你明确知道不能进入官方通道的本地 alias。保持空数组
时，Guard 不猜测模型是否存在；模型选择器和服务端负责最终校验。

`require_unpinned_model` 默认建议为 `false`，让客户端升级只更换内核，不同时
改动已经稳定使用的模型设置。需要专门测试新版默认模型选择时才设为 `true`；
如需单次指定模型，使用 `claude --model <name>`。

`notify` 默认 `false`。设为 `true` 后，macOS 会在 dry-run watchdog 记录
would-pause / would-resume 状态转换时发送通知；它不会改变进程状态，也不会向
Claude Code TUI 写入内容。环境变量 `CLAUDE_GUARD_NOTIFY=0|1` 的优先级更高。

官方 profile 还必须合并 [`config/official-settings-lifecycle.example.json`](config/official-settings-lifecycle.example.json) 中的生命周期字段。不要直接覆盖自己的权限等其他设置。

### CC Switch 通道

复制示例配置：

```bash
cp config/safe-claude-cc.example.json ~/.safe-claude-cc.json
```

必须填写：

- `command`：经过验包的 Claude Code 客户端绝对路径。
- `config_dir`：CC Switch 专用 profile，通常是 `~/.claude` 的绝对路径。
- `expected_base_url`：CC Switch 的本机 loopback endpoint。
- `client_version`、`client_sha256`：当前批准使用的客户端身份。
- macOS 建议同时固定 `client_macos_team_id=Q6L2SF6YDW`。
- macOS 建议固定 CC Switch 的执行路径、Team ID、Bundle ID 和应用版本。
- 使用无模型请求的 `OPTIONS /v1/messages` 协议探针，不只检查根路径能否返回。

默认还会要求 `PROXY_MANAGED` token 模式、profile 中不存在
`.credentials.json`，并检查本机 endpoint 可达。

## 使用

离线查看当前会话、watchdog 覆盖和最近历史：

```bash
claude-guard status
claude-guard status --json
```

运行完整官方链路检查并追加状态快照，不启动 Claude：

```bash
claude-guard doctor
```

生成适合分享的离线脱敏诊断摘要：

```bash
claude-guard diagnose
```

`status` 和 `diagnose` 不访问网络。`doctor` 会执行与正常启动相同的 IP、TLS、
IPv6 和配置检查，但不会启动 Claude Code，也不会提交 prompt。

官方通道只做预检，不启动 Claude：

```bash
claude-guard --precheck-only
```

预检通过后启动官方 Claude Code：

```bash
claude-guard
```

传递 Claude 参数：

```bash
claude-guard --model opus
```

CC Switch 通道只做预检：

```bash
claude-cc --precheck-only
```

启动 CC Switch 通道：

```bash
claude-cc
```

查看实际 CC 客户端版本：

```bash
claude-cc --version
```

查看 launcher 自身版本：

```bash
claude-cc --launcher-version
```

## 关键环境变量

```bash
CLAUDE_GUARD_CONFIG=~/.safe-claude-official.json
CLAUDE_GUARD_SETTINGS=~/.claude-official/settings.json
CLAUDE_GUARD_PROXY=http://127.0.0.1:7897
CLAUDE_GUARD_IP_CHECK_URLS="https://api.anthropic.com/cdn-cgi/trace"
CLAUDE_GUARD_ASSUME_YES=1
CLAUDE_GUARD_WATCHDOG=1
CLAUDE_GUARD_WATCHDOG_DRY_RUN=1
CLAUDE_GUARD_RECOVERY_INTERVAL=30
CLAUDE_GUARD_DRY_RUN_STDERR=0
CLAUDE_GUARD_NOTIFY=0
CLAUDE_GUARD_FINGERPRINT_MODE=fail-active
CLAUDE_GUARD_LEGACY_PROFILE_MODE=warn
CLAUDE_GUARD_LOG_FILE=~/.claude-guard/guard.log
CLAUDE_GUARD_LOG_MAX_BYTES=1048576
```

## 生命周期 Fail-Closed

官方通道从 `v0.2.4` 起默认要求：

- `claude agents`、`--bg`、`/background` 和 on-demand supervisor 关闭。
- Bash/subagent 后台任务、自动后台化和 `Ctrl+B` 关闭。
- cron、dynamic workflows、Remote Control 和 deep-link registration 关闭。
- MCP 长调用的自动后台化关闭。
- 自动更新和手动自更新关闭，由维护者先验包后再更新固定版本。
- `CLAUDE_CODE_RETRY_WATCHDOG` 必须不存在，避免无人值守时持续数小时重试。
- 子代理嵌套深度为 `1`，同时运行上限为 `3`。
- 所有 hooks 暂停，避免第三方 hook 在终端退出期间派生独立进程。

这些设置来自 Claude Code 的公开配置接口，不改写请求、不伪装客户端，也不绕过保护措施。代价是不能使用后台 session、Remote Control、dynamic workflows 和 hooks；普通前台交互、内置工具与受限子代理仍可使用。

当前官方 profile 中的 `codex@openai-codex` 插件包含 detached broker/background worker，因此建议列入 `blocked_plugins` 并在该 profile 中关闭。Codex App、Codex CLI 和 `claude-cc` 不受影响。

## 客户端指纹 Tripwire

`v0.2.1` 新增客户端指纹预检。它不会转发、修改、清洗或拦截 Claude Code 请求，只做启动前风险判断。

默认模式是：

```bash
CLAUDE_GUARD_FINGERPRINT_MODE=fail-active
```

含义：

- 如果当前 Claude Code 包没有已知 date/time watermark 逻辑，直接通过。
- 如果包含有已知逻辑，但官方启动环境干净，只给警告并继续。
- 如果包含有已知逻辑，且当前环境存在 `ANTHROPIC_BASE_URL` 或 `Asia/Shanghai` / `Asia/Urumqi` 等激活条件，则拒绝启动。

可选模式：

- `off`：关闭该检查。
- `warn`：只警告，不拒绝。
- `fail-active`：默认值，只在激活条件存在时拒绝。
- `strict`：只要客户端含有已知逻辑就拒绝。

`CLAUDE_GUARD_LEGACY_PROFILE_MODE=warn` 会检查 `~/.claude/settings.json` 的旧 CC Switch 残留并提示，但不会阻断官方入口，因为官方入口使用配置指定的独立 profile。

## 当前边界

运行中 guardian 仍然只做 dry-run，不会真的暂停、恢复或 kill 正在运行的 Claude Code。

这是有意为之：当前 launcher 保持 Claude Code 作为前台 TUI 运行，不能安全地只暂停主 PID。真正 action mode 必须暂停整个 Claude 进程组，否则子进程可能继续执行或联网。`v2.0.0` 仍会在用户设置 `CLAUDE_GUARD_WATCHDOG_DRY_RUN=0` 时拒绝启动 action mode，而不是给出虚假的安全感。

在背景功能关闭的情况下，正常前台 Claude 随终端退出；真实 pause/resume 或官方 `processWrapper` 支持会作为独立版本评估。

## 验证

```bash
./scripts/check.sh
```

当前测试覆盖：

- shell 语法检查。
- `--version` 输出。
- `--help` 输出。
- 入口 shim 安装路径。
- 缺失配置失败路径。
- `command` 非绝对路径失败路径。
- 客户端指纹 tripwire active/strict 失败路径。
- 生命周期必需设置失败路径。
- `CLAUDE_CODE_RETRY_WATCHDOG` 拒绝路径。
- 客户端版本和 SHA-256 不匹配失败路径。
- 已知 detached 插件拒绝路径。
- 项目级官方路由覆盖拒绝路径。
- 命令行 settings/background 绕过拒绝路径。
- IP 检查备用源 fallback。
- `allowed_cidrs` 放行路径。
- dry-run guardian 状态机。
- paused 状态探测退避、IP 状态分类、PID 日志归因和恢复路径集成测试。
- 并发安全的日志轮转。
- 离线 `status`、JSON 状态、`doctor`、脱敏 `diagnose` 和通知去重。
- 模拟前台 Claude 退出后 watchdog sidecar 在限定时间内退出。
- CC Switch 客户端版本、SHA-256 与签章固定。
- CC Switch loopback endpoint 和 `PROXY_MANAGED` profile 固定。
- CC Switch 监听进程路径与协议探针拒绝路径。
- CC profile 官方 credentials 污染拒绝路径。
- CC 项目设置、CLI settings 与父进程环境污染拒绝路径。
- 官方版本化 profile、模型取消固定和未授权 IP 不可绕过。

版本切换后还应运行一次不发模型请求的实机 PTY 验收：

```bash
python3 scripts/verify-terminal-exit.py
```

它会启动 `--safe-mode` TUI、关闭伪终端并检查残留进程；不会提交 prompt。
