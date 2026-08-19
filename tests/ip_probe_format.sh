#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home"

# 出口探测的两种响应体格式：
#   - 裸 IP：https://api.ipify.org
#   - Cloudflare /cdn-cgi/trace：key=value 多行文本
# trace 分支必须排在 api.anthropic.com 的 TLS 分支之前，否则会被后者吞掉。
cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi

if printf '%s' "$args" | grep -q '/cdn-cgi/trace'; then
  printf 'fl=1f2\n'
  printf 'h=api.anthropic.com\n'
  printf 'ip=203.0.113.10\n'
  printf 'ts=1700000000.000\n'
  printf 'visit_scheme=https\n'
  exit 0
fi

if printf '%s' "$args" | grep -Eq 'https://(ipinfo\.io/ip|api\.ipify\.org)'; then
  printf '203.0.113.10\n'
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://api.anthropic.com/'; then
  {
    printf '* CONNECT api.anthropic.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Google Trust Services; CN=WE1\n'
  } >&2
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://platform.claude.com/'; then
  {
    printf '* CONNECT platform.claude.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Let'\''s Encrypt; CN=YE1\n'
  } >&2
  exit 0
fi

exit 1
EOF
chmod +x "$TMP_DIR/bin/curl"

cat >"$TMP_DIR/settings.json" <<'EOF'
{
  "disableAgentView": true,
  "disableRemoteControl": true,
  "disableDeepLinkRegistration": "disable",
  "disableAllHooks": true,
  "disableWorkflows": true,
  "env": {
    "DISABLE_UPDATES": "1",
    "CLAUDE_CODE_DISABLE_AGENT_VIEW": "1",
    "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
    "CLAUDE_CODE_DISABLE_CRON": "1",
    "CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF": "1",
    "CLAUDE_DISABLE_ADOPT": "1",
    "CLAUDE_CODE_DISABLE_WORKFLOWS": "1",
    "CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS": "0",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1",
    "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "3"
  }
}
EOF

printf 'fake ca\n' >"$TMP_DIR/cert.pem"
printf '{"command":"/bin/echo","allowed_ips":["203.0.113.10"]}\n' >"$TMP_DIR/allowed.json"
printf '{"command":"/bin/echo","allowed_ips":["198.51.100.20"]}\n' >"$TMP_DIR/denied.json"

run_precheck() {
  (
    cd "$TMP_DIR"
    HOME="$TMP_DIR/home" \
      USER="guard-test" \
      PATH="${3:-$TMP_DIR/bin}:$PATH" \
      LANG="en_US.UTF-8" \
      CLAUDE_GUARD_CONFIG="$1" \
      CLAUDE_GUARD_IP_CHECK_URLS="$2" \
      CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
      CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
      CLAUDE_GUARD_IP_RETRIES=1 \
      CLAUDE_GUARD_TLS_RETRIES=1 \
      CLAUDE_GUARD_UI=never \
      "$ROOT_DIR/bin/claude-guard" --precheck-only
  )
}

# 1. /cdn-cgi/trace 响应体可解析出出口 IP。
run_precheck "$TMP_DIR/allowed.json" "https://api.anthropic.com/cdn-cgi/trace" >"$TMP_DIR/trace.out" 2>&1
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/trace.out"

# 2. 裸 IP 响应体仍然可解析（向后兼容，用户可继续覆盖为第三方查询源）。
run_precheck "$TMP_DIR/allowed.json" "https://api.ipify.org" >"$TMP_DIR/plain.out" 2>&1
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/plain.out"

# 3. 默认值走 trace 端点，与 API 流量共用代理分流策略。
run_precheck "$TMP_DIR/allowed.json" "" >"$TMP_DIR/default.out" 2>&1
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/default.out"

# 4. trace 解析出的 IP 不在白名单时仍然 fail-closed。
set +e
run_precheck "$TMP_DIR/denied.json" "https://api.anthropic.com/cdn-cgi/trace" >"$TMP_DIR/denied.out" 2>&1
status=$?
set -e
if [ "$status" -ne 4 ]; then
  printf 'trace denied-IP test returned %s instead of 4\n' "$status" >&2
  cat "$TMP_DIR/denied.out" >&2
  exit 1
fi
grep -q 'IP 检查失败：203.0.113.10' "$TMP_DIR/denied.out"

# 5. 默认配置下主端点探测失败必须 fail-closed（exit 3），且全程不得请求 claude.ai。
#    默认值是单源的：换个 hostname 再问一次就不再与 API 流量同策略，等于用一条不确定
#    的链路去判定白名单。用户把两个域名都写进 CLAUDE_GUARD_IP_CHECK_URLS 是主动选择，
#    不在本用例射程内。
mkdir -p "$TMP_DIR/bin-trace-fail"
cat >"$TMP_DIR/bin-trace-fail/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >>"$HOME/trace-fail-curl.log"

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi

# 主端点探测失败：解析不到主机，无响应体。
if printf '%s' "$args" | grep -q '/cdn-cgi/trace'; then
  exit 6
fi

if printf '%s' "$args" | grep -q 'https://api.anthropic.com/'; then
  {
    printf '* CONNECT api.anthropic.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Google Trust Services; CN=WE1\n'
  } >&2
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://platform.claude.com/'; then
  {
    printf '* CONNECT platform.claude.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Let'\''s Encrypt; CN=YE1\n'
  } >&2
  exit 0
fi

exit 1
EOF
chmod +x "$TMP_DIR/bin-trace-fail/curl"

: >"$TMP_DIR/home/trace-fail-curl.log"
set +e
run_precheck "$TMP_DIR/allowed.json" "" "$TMP_DIR/bin-trace-fail" >"$TMP_DIR/trace_fail.out" 2>&1
status=$?
set -e
if [ "$status" -ne 3 ]; then
  printf 'default-URL trace failure returned %s instead of 3\n' "$status" >&2
  cat "$TMP_DIR/trace_fail.out" >&2
  exit 1
fi
grep -q 'IP 检查失败：无法获取当前出口 IP' "$TMP_DIR/trace_fail.out"
if grep -q 'claude\.ai' "$TMP_DIR/home/trace-fail-curl.log"; then
  printf 'default URL list must not fall back to claude.ai\n' >&2
  cat "$TMP_DIR/home/trace-fail-curl.log" >&2
  exit 1
fi

# 6. curl 吐出部分响应体后以 28（--max-time 超时）退出时不得采信该响应体。
#    这里白名单里正好有部分响应中的那个 IP：一旦采信就会 exit 0 放行，因此本用例
#    要求 exit 3。
mkdir -p "$TMP_DIR/bin-partial"
cat >"$TMP_DIR/bin-partial/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi

# 超时中断：响应体已经包含完整的 ip= 字段，但 curl 以 28 退出。
if printf '%s' "$args" | grep -q '/cdn-cgi/trace'; then
  printf 'fl=1f2\n'
  printf 'h=api.anthropic.com\n'
  printf 'ip=203.0.113.10\n'
  exit 28
fi

if printf '%s' "$args" | grep -q 'https://api.anthropic.com/'; then
  {
    printf '* CONNECT api.anthropic.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Google Trust Services; CN=WE1\n'
  } >&2
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://platform.claude.com/'; then
  {
    printf '* CONNECT platform.claude.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Let'\''s Encrypt; CN=YE1\n'
  } >&2
  exit 0
fi

exit 1
EOF
chmod +x "$TMP_DIR/bin-partial/curl"

set +e
run_precheck "$TMP_DIR/allowed.json" "" "$TMP_DIR/bin-partial" >"$TMP_DIR/partial.out" 2>&1
status=$?
set -e
if [ "$status" -ne 3 ]; then
  printf 'partial body with curl exit 28 returned %s instead of 3\n' "$status" >&2
  cat "$TMP_DIR/partial.out" >&2
  exit 1
fi
grep -q 'IP 检查失败：无法获取当前出口 IP' "$TMP_DIR/partial.out"

printf 'ip probe format ok\n'
