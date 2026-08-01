#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
CLAUDE_PID=""

cleanup() {
  if [ -n "$CLAUDE_PID" ]; then
    kill -TERM "$CLAUDE_PID" 2>/dev/null || true
    wait "$CLAUDE_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.claude-official" \
  "$TMP_DIR/home/visibility-fixture"

cat >"$TMP_DIR/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  printf '2.1.220 (Claude Code)\n'
  exit 0
fi

if [ "${1:-}" = "hold" ]; then
  bash "$HOME/visibility-fixture/claude-guard" &
  child_pid=$!
  trap 'kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; exit 0' HUP INT TERM
  wait "$child_pid"
  exit 0
fi

printf 'unexpected Claude launch: %s\n' "$*" >>"$HOME/visibility-fixture/claude-launches"
EOF
chmod +x "$TMP_DIR/bin/fake-claude"

cat >"$TMP_DIR/home/visibility-fixture/claude-guard" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' HUP INT TERM
while :; do
  sleep 5
done
EOF
chmod +x "$TMP_DIR/home/visibility-fixture/claude-guard"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$HOME/visibility-fixture/curl-calls"
args="$*"

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
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

cat >"$TMP_DIR/home/.claude-official/settings.json" <<'EOF'
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
printf '{"command":"%s","config_dir":"%s","allowed_ips":["203.0.113.10"],"notify":true}\n' \
  "$TMP_DIR/bin/fake-claude" "$TMP_DIR/home/.claude-official" >"$TMP_DIR/config.json"

HOME="$TMP_DIR/home" "$TMP_DIR/bin/fake-claude" hold &
CLAUDE_PID=$!
for _ in 1 2 3 4 5; do
  if pgrep -P "$CLAUDE_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
pgrep -P "$CLAUDE_PID" >/dev/null

cat >"$TMP_DIR/guard.log" <<EOF
2026-08-01T12:00:00+0800 [INFO] watchdog started pid=${CLAUDE_PID} proxy=http://127.0.0.1:7897 dry_run=1
2026-08-01T12:01:00+0800 [WARN] watchdog pid=${CLAUDE_PID} exit ip not allowed ip=198.51.100.55 count=2/2 state=degraded
2026-08-01T12:01:00+0800 [WARN] DRY RUN: would pause Claude pid=${CLAUDE_PID}; reason=exit IP not allowed ip=198.51.100.55
2026-08-01T12:02:00+0800 [INFO] watchdog pid=${CLAUDE_PID} resume candidate count=2/2 ip=203.0.113.10
2026-08-01T12:02:00+0800 [INFO] DRY RUN: would resume Claude pid=${CLAUDE_PID}; reason=route healthy again ip=203.0.113.10
2026-08-01T12:02:01+0800 [WARN] diagnostic fixture path=${TMP_DIR}/secret token=super-secret-value
EOF

run_guard() {
  (
    cd "$TMP_DIR"
    HOME="$TMP_DIR/home" \
      USER="guard-test" \
      PATH="$TMP_DIR/bin:$PATH" \
      CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
      CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
      CLAUDE_GUARD_LOG_FILE="$TMP_DIR/guard.log" \
      CLAUDE_GUARD_UI=never \
      CLAUDE_GUARD_ASSUME_YES=1 \
      CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
      CLAUDE_GUARD_IP_CHECK_URLS="https://ipinfo.io/ip" \
      CLAUDE_GUARD_IP_RETRIES=1 \
      CLAUDE_GUARD_TLS_RETRIES=1 \
      "$ROOT_DIR/bin/claude-guard" "$@"
  )
}

rm -f "$TMP_DIR/home/visibility-fixture/curl-calls"
run_guard status >"$TMP_DIR/status.out"
grep -q '^Claude Guard Status$' "$TMP_DIR/status.out"
grep -q 'version: 2.0.4' "$TMP_DIR/status.out"
grep -q 'health: OK' "$TMP_DIR/status.out"
grep -q 'mode: dry-run observation' "$TMP_DIR/status.out"
grep -q 'notifications: enabled' "$TMP_DIR/status.out"
grep -q 'active Claude sessions: 1' "$TMP_DIR/status.out" || {
  cat "$TMP_DIR/status.out" >&2
  exit 1
}
grep -q 'active watchdogs: 1' "$TMP_DIR/status.out" || {
  cat "$TMP_DIR/status.out" >&2
  # shellcheck disable=SC2009
  ps -axo pid=,ppid=,pgid=,args= | grep -F "$TMP_DIR" >&2 || true
  exit 1
}
grep -q "pid=${CLAUDE_PID}.*state=healthy" "$TMP_DIR/status.out"
[ ! -e "$TMP_DIR/home/visibility-fixture/curl-calls" ]

run_guard status --json >"$TMP_DIR/status.json"
jq -e --argjson pid "$CLAUDE_PID" '
  .version == "2.0.4" and
  .health == "ok" and
  .mode == "dry-run" and
  .notifications == true and
  .active_sessions == 1 and
  .active_watchdogs == 1 and
  (.sessions | any(.pid == $pid and .state == "healthy"))
' "$TMP_DIR/status.json" >/dev/null
[ ! -e "$TMP_DIR/home/visibility-fixture/curl-calls" ]

CLAUDE_GUARD_NOTIFY=0 run_guard status >"$TMP_DIR/status-notify-override.out"
grep -q 'notifications: disabled' "$TMP_DIR/status-notify-override.out"

cp "$TMP_DIR/config.json" "$TMP_DIR/config.valid.json"
jq '.notify = "yes"' "$TMP_DIR/config.valid.json" >"$TMP_DIR/config.json"
if run_guard status >"$TMP_DIR/status-invalid-notify.out" 2>&1; then
  printf 'invalid notify configuration unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'notify 必须是 true 或 false' "$TMP_DIR/status-invalid-notify.out"
mv "$TMP_DIR/config.valid.json" "$TMP_DIR/config.json"

run_guard diagnose >"$TMP_DIR/diagnose.out"
grep -q '^Claude Guard Diagnostic (redacted)$' "$TMP_DIR/diagnose.out"
grep -q 'x.x.x.x' "$TMP_DIR/diagnose.out"
if grep -Fq "$TMP_DIR" "$TMP_DIR/diagnose.out"; then
  printf 'diagnostic report leaked a temporary path\n' >&2
  exit 1
fi
if grep -Eq '198\.51\.100\.55|203\.0\.113\.10|super-secret-value' "$TMP_DIR/diagnose.out"; then
  printf 'diagnostic report leaked IP or secret data\n' >&2
  exit 1
fi
[ ! -e "$TMP_DIR/home/visibility-fixture/curl-calls" ]

run_guard doctor >"$TMP_DIR/doctor.out" 2>&1
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/doctor.out"
grep -q '^Doctor result: PASS (Claude was not started)$' "$TMP_DIR/doctor.out"
grep -q '^Claude Guard Status$' "$TMP_DIR/doctor.out"
[ -s "$TMP_DIR/home/visibility-fixture/curl-calls" ]
[ ! -e "$TMP_DIR/home/visibility-fixture/claude-launches" ]

printf 'visibility commands ok\n'
