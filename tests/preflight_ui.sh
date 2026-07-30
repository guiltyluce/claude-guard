#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
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
  if [ -f "$HOME/fail-platform-tls" ]; then
    printf 'curl: (35) simulated TLS connection error\n' >&2
    exit 35
  fi
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
      PATH="$TMP_DIR/bin:$PATH" \
      LANG="en_US.UTF-8" \
      CLAUDE_GUARD_CONFIG="$1" \
      CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
      CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
      CLAUDE_GUARD_IP_RETRIES=1 \
      CLAUDE_GUARD_TLS_RETRIES=1 \
      CLAUDE_GUARD_UI="$2" \
      "$ROOT_DIR/bin/claude-guard" --precheck-only
  )
}

if [ "${CLAUDE_GUARD_TEST_LIVE:-0}" = "1" ]; then
  run_precheck "$TMP_DIR/allowed.json" auto
  exit 0
fi

run_precheck "$TMP_DIR/allowed.json" always >"$TMP_DIR/ui.out" 2>&1
grep -q 'Claude Guard · Official Preflight' "$TMP_DIR/ui.out"
grep -q '✓' "$TMP_DIR/ui.out"
grep -q '8/8' "$TMP_DIR/ui.out"
grep -q '预检已通过' "$TMP_DIR/ui.out"
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/ui.out"

run_precheck "$TMP_DIR/allowed.json" never >"$TMP_DIR/plain.out" 2>&1
if grep -q 'Claude Guard · Official Preflight' "$TMP_DIR/plain.out"; then
  printf 'plain UI mode unexpectedly rendered the visual preflight\n' >&2
  exit 1
fi
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/plain.out"
grep -q '预检完成：未启动 Claude。' "$TMP_DIR/plain.out"
if grep -q '出口 IP 已获取' "$TMP_DIR/plain.out"; then
  printf 'plain UI mode changed the legacy output contract\n' >&2
  exit 1
fi

run_precheck "$TMP_DIR/allowed.json" auto >"$TMP_DIR/auto.out" 2>&1
if grep -q 'Official Preflight' "$TMP_DIR/auto.out"; then
  printf 'auto UI mode rendered visual output without a TTY\n' >&2
  exit 1
fi
grep -q '预检完成：未启动 Claude。' "$TMP_DIR/auto.out"

NO_COLOR=1 run_precheck "$TMP_DIR/allowed.json" always >"$TMP_DIR/no-color.out" 2>&1
if LC_ALL=C grep -q "$(printf '\033')" "$TMP_DIR/no-color.out"; then
  printf 'NO_COLOR output contains ANSI escape sequences\n' >&2
  exit 1
fi
grep -q 'Claude Guard · Official Preflight' "$TMP_DIR/no-color.out"

touch "$TMP_DIR/home/fail-platform-tls"
run_precheck "$TMP_DIR/allowed.json" always >"$TMP_DIR/warn.out" 2>&1
rm "$TMP_DIR/home/fail-platform-tls"
grep -q 'TLS 预检警告：platform.claude.com' "$TMP_DIR/warn.out"
grep -q '含 1 条警告' "$TMP_DIR/warn.out"
grep -q '预检已通过' "$TMP_DIR/warn.out"

set +e
run_precheck "$TMP_DIR/denied.json" always >"$TMP_DIR/denied.out" 2>&1
status=$?
set -e
if [ "$status" -ne 4 ]; then
  printf 'visual denied-IP test returned %s instead of 4\n' "$status" >&2
  cat "$TMP_DIR/denied.out" >&2
  exit 1
fi
grep -q 'IP 检查失败：203.0.113.10' "$TMP_DIR/denied.out"
grep -q '预检未通过' "$TMP_DIR/denied.out"
if grep -q '预检已通过' "$TMP_DIR/denied.out"; then
  printf 'visual denied-IP test rendered a false success state\n' >&2
  exit 1
fi

if [ "${CLAUDE_GUARD_TEST_DUMP:-0}" = "1" ]; then
  printf '%s\n' '--- visual pass ---'
  cat "$TMP_DIR/ui.out"
  printf '%s\n' '--- visual fail ---'
  cat "$TMP_DIR/denied.out"
fi

printf 'preflight ui ok\n'
