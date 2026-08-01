#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
state_dir="$HOME/watchdog-fixture"
mkdir -p "$state_dir"

increment_counter() {
  local name="$1"
  local file="$state_dir/$name"
  local count=0

  [ ! -f "$file" ] || count="$(cat "$file")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$file"
  printf '%s\n' "$count"
}

tls_ok() {
  local host="$1"
  {
    printf '* CONNECT %s:443 HTTP/1.1\n' "$host"
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Google Trust Services; CN=WE1\n'
  } >&2
}

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi

if printf '%s' "$args" | grep -q 'https://ipinfo.io/ip'; then
  count="$(increment_counter ip-count)"
  mode="$(cat "$state_dir/mode")"
  if [ "$count" -eq 1 ]; then
    printf '203.0.113.10\n'
    exit 0
  fi
  case "$mode:$count" in
    recover:2)
      exit 28
      ;;
    recover:3)
      printf '198.51.100.55\n'
      exit 0
      ;;
    recover:*)
      printf '203.0.113.10\n'
      exit 0
      ;;
    healthy:*)
      printf '203.0.113.10\n'
      exit 0
      ;;
    outage:*)
      exit 28
      ;;
  esac
fi

if printf '%s' "$args" | grep -q 'https://api.anthropic.com/'; then
  increment_counter api-count >/dev/null
  tls_ok api.anthropic.com
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://platform.claude.com/'; then
  tls_ok platform.claude.com
  exit 0
fi

exit 1
EOF
chmod +x "$TMP_DIR/bin/curl"

cat >"$TMP_DIR/bin/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME/watchdog-fixture"
printf '%s\n' "$*" >>"$HOME/watchdog-fixture/notifications.log"
EOF
chmod +x "$TMP_DIR/bin/osascript"

cat >"$TMP_DIR/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  printf '2.1.220 (Claude Code)\n'
  exit 0
fi

mode="$(cat "$HOME/watchdog-fixture/mode")"
case "$mode" in
  outage) sleep 7 ;;
  recover) sleep 8 ;;
  healthy) sleep 3 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/fake-claude"

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
printf '{"command":"%s","allowed_ips":["203.0.113.10"],"notify":true}\n' \
  "$TMP_DIR/bin/fake-claude" >"$TMP_DIR/config.json"

run_case() {
  local mode="$1"
  local max_bytes="${2:-1048576}"
  local prefill="${3:-0}"
  local log_file="$TMP_DIR/$mode.log"
  local output_file="$TMP_DIR/$mode.out"
  local state_dir="$TMP_DIR/home/watchdog-fixture"

  rm -rf "$state_dir"
  mkdir -p "$state_dir"
  printf '%s\n' "$mode" >"$state_dir/mode"
  if [ "$prefill" = "1" ]; then
    {
      printf 'ROTATION_MARKER\n'
      head -c 2048 /dev/zero | tr '\0' x
      printf '\n'
    } >"$log_file"
  fi

  if ! (
    cd "$TMP_DIR"
    HOME="$TMP_DIR/home" \
      USER="guard-test" \
      PATH="$TMP_DIR/bin:$PATH" \
      CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
      CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
      CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
      CLAUDE_GUARD_UI=never \
      CLAUDE_GUARD_ASSUME_YES=1 \
      CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
      CLAUDE_GUARD_IP_CHECK_URLS="https://ipinfo.io/ip" \
      CLAUDE_GUARD_IP_RETRIES=1 \
      CLAUDE_GUARD_TLS_RETRIES=1 \
      CLAUDE_GUARD_WATCHDOG=1 \
      CLAUDE_GUARD_WATCHDOG_DRY_RUN=1 \
      CLAUDE_GUARD_IP_INTERVAL=1 \
      CLAUDE_GUARD_API_INTERVAL=100 \
      CLAUDE_GUARD_RECOVERY_INTERVAL=2 \
      CLAUDE_GUARD_WATCHDOG_TICK_SECONDS=1 \
      CLAUDE_GUARD_IP_BAD_THRESHOLD=2 \
      CLAUDE_GUARD_API_BAD_THRESHOLD=3 \
      CLAUDE_GUARD_RESUME_GOOD_THRESHOLD=2 \
      CLAUDE_GUARD_LOG_FILE="$log_file" \
      CLAUDE_GUARD_LOG_MAX_BYTES="$max_bytes" \
      "$ROOT_DIR/bin/claude-guard" >"$output_file" 2>&1
  ); then
    cat "$output_file" >&2
    printf 'watchdog runtime case failed: %s\n' "$mode" >&2
    exit 1
  fi

  sleep 2
  [ -f "$log_file" ] || {
    printf 'watchdog runtime case produced no log: %s\n' "$mode" >&2
    exit 1
  }
}

run_case outage
grep -q 'exit ip unavailable count=1/2' "$TMP_DIR/outage.log"
grep -q 'DRY RUN: would pause Claude' "$TMP_DIR/outage.log"
grep -q 'watchdog exited.*reason=target-gone' "$TMP_DIR/outage.log"
api_calls="$(cat "$TMP_DIR/home/watchdog-fixture/api-count")"
if [ "$api_calls" -gt 5 ]; then
  printf 'paused recovery probes were amplified: api_calls=%s\n' "$api_calls" >&2
  exit 1
fi

run_case recover
grep -q 'exit ip unavailable count=1/2' "$TMP_DIR/recover.log"
grep -q 'exit ip not allowed ip=198.51.100.55 count=2/2' "$TMP_DIR/recover.log"
grep -q 'DRY RUN: would pause Claude' "$TMP_DIR/recover.log"
grep -q 'DRY RUN: would resume Claude' "$TMP_DIR/recover.log"
notification_count="$(wc -l <"$TMP_DIR/home/watchdog-fixture/notifications.log" | tr -d '[:space:]')"
if [ "$notification_count" -ne 2 ]; then
  printf 'expected exactly two pause/resume notifications, got %s\n' "$notification_count" >&2
  exit 1
fi
grep -q 'would pause Claude' "$TMP_DIR/home/watchdog-fixture/notifications.log"
grep -q 'would resume Claude' "$TMP_DIR/home/watchdog-fixture/notifications.log"

if awk '!/pid=[0-9]+/ {print; bad=1} END {exit bad}' "$TMP_DIR/recover.log"; then
  :
else
  printf 'watchdog runtime log contains entries without pid context\n' >&2
  exit 1
fi

run_case healthy 512 1
[ -f "$TMP_DIR/healthy.log.1" ] || {
  printf 'watchdog log rotation did not create an archive\n' >&2
  exit 1
}
grep -q 'ROTATION_MARKER' "$TMP_DIR/healthy.log.1"
grep -q 'watchdog started pid=' "$TMP_DIR/healthy.log"
grep -q 'watchdog exited.*reason=target-gone' "$TMP_DIR/healthy.log"

printf 'watchdog runtime integration ok\n'
