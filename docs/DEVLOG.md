# DEVLOG

决策链路与指针。各版本的完整改动见 `CHANGELOG.md`，单版本的设计论证见 `docs/v<版本>-*.md`。

## #1 · 2026-08-28 · PR #11（Windows/Schannel）首轮复审：三条安全门禁绕过
- **背景**：v2.1.3 发布当天，社区贡献者提交 draft PR #11，用 curl 的 `%{certs}` 在 Schannel 后端上恢复 issuer/MITM 检查，并让启动预检与 watchdog 探针共用 `tls_probe_once`。分支里另带两个 v2.1.3 的 cherry-pick（tree 与 main 逐字节相同）。方向正确，12 个 fixture 全绿，macOS 真机 `doctor` PASS。
- **决策**：以普通 review comment（非 Request changes）提出三条合并阻断项，并附上两条已验证 load-bearing 的 fixture。
- **理由**：三条都用变异测试拿到了实证，不是风格意见——把安全判定改坏后现有测试**仍然全绿**：
  1. **证书链取值未锁**。`%{certs}` 输出整条链（真实 curl 上 `api.anthropic.com` 有 3 条 `Issuer:`），`head -1` 取叶证书是唯一正确性支点，但所有 fixture 都只有一条 issuer。`head -1` → `tail -1` 仍全绿，意味着可能拿链尾公共根去比对黑名单，MITM 判定空转。
  2. **curl 退出码未锁**。删掉旧的 `SSL certificate verify ok` 字符串检查后，`curl_status -ne 0` 是它唯一的接替者（成立的前提是 v2.1.3 的 `-q` + 显式 `--cacert`）。改成永假条件仍全绿——`curl-fail` fixture 同时缺 CONNECT 和 issuer，失败被后面的门兜住了。
  3. **verbose 与 `%{certs}` 混流可注入**。`%{certs}` 会把未识别的证书扩展原始字节不转义地倒出，且可换行（真实输出里 SCT 扩展 OID `1.3.6.1.4.1.11129.2.4.2` 就跨了行）。issuer 提取有 marker 圈定，但 CONNECT 与 schannel 两条 grep 没有——实测证书内容即可伪造隧道证据并放行。修法是两个证据源物理分流，marker 随之不再需要。
- **否掉的备选**：
  - **正式 Request changes**：PR 明确标为 draft 且作者自述会收敛，draft 本就不能合并，blocking review 机制上无效、姿态上偏重。改为 comment 正文直书「三条为合并阻断项」。
  - **把能力判据改成「certs 块为空且无 legacy issuer」**：形态与一次网络握手失败完全相同，会把临时故障误判为确定性不兼容并跳过重试。降级为非阻断建议，并在正文中明确写出这个反例。
  - **在 PR 中安排贡献者分工**：人事不进公开技术线程。
- **教训**：
  - 给外部贡献者的 rebase 指令必须先核对其 fork 的 `main` 实际位置。本轮拟稿里的 `--onto origin/main` 会把改动 rebase 到该 fork 停留的 v2.1.2，正好抽掉阻断 2 所依赖的加固；改为显式 `upstream/main` 才成立。
  - 「断言某个 flag/字符串出现过」不等于「该安全判定被测试保护」。判断一条门禁是否真被锁住，唯一可靠的办法是把它改坏再跑一遍。
  - 结构化输出（`%{certs}`）与诊断输出（verbose）混进同一个流，就等于把攻击者可控的字节喂给所有针对该流的 grep。
- **身份未确认，暂不协调**：早前站外私信中讨论过 Windows 兼容性方向，但无法确认与本 PR 提交者的对应关系，GitHub 上也无相关记录。在确认之前不做任何跨人协调，也不在 PR 中提及。
