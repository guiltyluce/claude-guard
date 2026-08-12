#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/project/.claude"

cat >"$TMP_DIR/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--version" ]; then
  printf '2.1.220 (Claude Code)\n'
  exit 0
fi

env | sort >"$self_dir/fake-claude.env"
printf '%s\n' "$@" >"$self_dir/fake-claude.args"
touch "$self_dir/fake-claude.started"

for arg in "$@"; do
  if [ "$arg" = "--fake-sleep" ]; then
    exec sleep 30
  fi
done
EOF
chmod +x "$TMP_DIR/fake-claude"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi
if printf '%s' "$args" | grep -q '/cdn-cgi/trace'; then
  printf 'h=api.anthropic.com\nip=203.0.113.10\nvisit_scheme=https\n'
  exit 0
fi
if printf '%s' "$args" | grep -Eq 'https://(ipinfo.io/ip|api.ipify.org)'; then
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

cat >"$TMP_DIR/settings-safe.json" <<'EOF'
{
  "disableAgentView": true,
  "disableRemoteControl": true,
  "disableDeepLinkRegistration": "disable",
  "disableAllHooks": true,
  "disableWorkflows": true,
  "env": {
    "DISABLE_TELEMETRY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
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

printf '{}\n' >"$TMP_DIR/settings-unsafe.json"
printf 'fake ca\n' >"$TMP_DIR/cert.pem"

if command -v shasum >/dev/null 2>&1; then
  client_sha="$(shasum -a 256 "$TMP_DIR/fake-claude" | awk '{print $1}')"
else
  client_sha="$(sha256sum "$TMP_DIR/fake-claude" | awk '{print $1}')"
fi

cat >"$TMP_DIR/config.json" <<EOF
{
  "command": "$TMP_DIR/fake-claude",
  "allowed_ips": ["203.0.113.10"],
  "client_version": "2.1.220",
  "client_sha256": "$client_sha",
  "blocked_plugins": ["codex@openai-codex"]
}
EOF

run_guard() {
  PATH="$TMP_DIR/bin:$PATH" \
    CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
    CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-safe.json" \
    CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
    CLAUDE_GUARD_ASSUME_YES=1 \
    CLAUDE_GUARD_WATCHDOG=0 \
    "$ROOT_DIR/bin/claude-guard" "$@"
}

if PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-unsafe.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/missing-policy.out" 2>&1; then
  printf 'missing lifecycle policy unexpectedly passed\n' >&2
  exit 1
fi
grep -q '生命周期策略' "$TMP_DIR/missing-policy.out"

jq '.env.CLAUDE_CODE_RETRY_WATCHDOG = "1"' \
  "$TMP_DIR/settings-safe.json" >"$TMP_DIR/settings-retry-watchdog.json"
if PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-retry-watchdog.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/retry-watchdog.out" 2>&1; then
  printf 'retry watchdog policy unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'CLAUDE_CODE_RETRY_WATCHDOG' "$TMP_DIR/retry-watchdog.out"

jq '.client_version = "2.1.219"' "$TMP_DIR/config.json" >"$TMP_DIR/config-wrong-version.json"
if PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config-wrong-version.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-safe.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/wrong-version.out" 2>&1; then
  printf 'wrong client version unexpectedly passed\n' >&2
  exit 1
fi
grep -q '客户端版本校验失败' "$TMP_DIR/wrong-version.out"

jq '.client_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$TMP_DIR/config.json" >"$TMP_DIR/config-wrong-sha.json"
if PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config-wrong-sha.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-safe.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/wrong-sha.out" 2>&1; then
  printf 'wrong client SHA-256 unexpectedly passed\n' >&2
  exit 1
fi
grep -q '客户端 SHA-256 校验失败' "$TMP_DIR/wrong-sha.out"

jq '.enabledPlugins = {"codex@openai-codex": true}' \
  "$TMP_DIR/settings-safe.json" >"$TMP_DIR/settings-blocked-plugin.json"
if PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-blocked-plugin.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/blocked-plugin.out" 2>&1; then
  printf 'blocked detached plugin unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'codex@openai-codex' "$TMP_DIR/blocked-plugin.out"

jq '.blocked_models = ["legacy-model-alias"]' \
  "$TMP_DIR/config.json" >"$TMP_DIR/config-blocked-model.json"
if PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config-blocked-model.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-safe.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  "$ROOT_DIR/bin/claude-guard" --model legacy-model-alias \
  >"$TMP_DIR/blocked-model.out" 2>&1; then
  printf 'blocked model unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'blocked_models' "$TMP_DIR/blocked-model.out"

printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:15721"}}\n' \
  >"$TMP_DIR/project/.claude/settings.json"
if (
  cd "$TMP_DIR/project"
  run_guard --precheck-only
) >"$TMP_DIR/project-settings.out" 2>&1; then
  printf 'project settings route override unexpectedly passed\n' >&2
  exit 1
fi
grep -q '项目设置' "$TMP_DIR/project-settings.out"
rm "$TMP_DIR/project/.claude/settings.json"

if run_guard --settings "$TMP_DIR/settings-unsafe.json" \
  >"$TMP_DIR/cli-settings.out" 2>&1; then
  printf 'CLI settings override unexpectedly passed\n' >&2
  exit 1
fi
grep -q '不允许覆盖 --settings' "$TMP_DIR/cli-settings.out"

if run_guard --bg test >"$TMP_DIR/cli-background.out" 2>&1; then
  printf 'CLI background mode unexpectedly passed\n' >&2
  exit 1
fi
grep -q '后台会话已禁用' "$TMP_DIR/cli-background.out"

run_guard --model future-model --fake-run >"$TMP_DIR/launch.out" 2>&1
grep -qx 'future-model' "$TMP_DIR/fake-claude.args"
for expected in \
  'CLAUDE_CODE_DISABLE_AGENT_VIEW=1' \
  'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1' \
  'CLAUDE_CODE_DISABLE_CRON=1' \
  'CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1' \
  'CLAUDE_DISABLE_ADOPT=1' \
  'CLAUDE_CODE_DISABLE_WORKFLOWS=1' \
  'CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=0' \
  'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1' \
  'CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=3' \
  'DISABLE_UPDATES=1'; do
  grep -qx "$expected" "$TMP_DIR/fake-claude.env"
done
if grep -q '^CLAUDE_CODE_RETRY_WATCHDOG=' "$TMP_DIR/fake-claude.env"; then
  printf 'retry watchdog leaked into Claude environment\n' >&2
  exit 1
fi

rm -f "$TMP_DIR/fake-claude.started"
PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-safe.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_ASSUME_YES=1 \
  CLAUDE_GUARD_WATCHDOG=1 \
  CLAUDE_GUARD_WATCHDOG_TICK_SECONDS=1 \
  CLAUDE_GUARD_IP_INTERVAL=60 \
  CLAUDE_GUARD_API_INTERVAL=60 \
  CLAUDE_GUARD_LOG_FILE="$TMP_DIR/guard.log" \
  "$ROOT_DIR/bin/claude-guard" --fake-sleep >"$TMP_DIR/exit.out" 2>&1 &
main_pid=$!

for _ in 1 2 3 4 5; do
  [ -f "$TMP_DIR/fake-claude.started" ] && break
  sleep 1
done
[ -f "$TMP_DIR/fake-claude.started" ]

kill -TERM "$main_pid"
wait "$main_pid" 2>/dev/null || true

for _ in 1 2 3 4 5; do
  if grep -q "watchdog pid=${main_pid} watchdog exited reason=target-gone" "$TMP_DIR/guard.log" 2>/dev/null; then
    break
  fi
  sleep 1
done
grep -q "watchdog pid=${main_pid} watchdog exited reason=target-gone" "$TMP_DIR/guard.log"

printf 'lifecycle policy ok\n'
