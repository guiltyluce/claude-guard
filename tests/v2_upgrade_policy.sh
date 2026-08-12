#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/profile-stable/projects/sample"
printf 'old-session-sentinel\n' >"$TMP_DIR/profile-stable/projects/sample/session.jsonl"

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
  printf 'h=api.anthropic.com\n'
  printf 'ip=%s\n' "${FAKE_EXIT_IP:-203.0.113.10}"
  printf 'visit_scheme=https\n'
  exit 0
fi
if printf '%s' "$args" | grep -Eq 'https://(ipinfo.io/ip|api.ipify.org)'; then
  printf '%s\n' "${FAKE_EXIT_IP:-203.0.113.10}"
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

cat >"$TMP_DIR/profile-stable/settings.json" <<'EOF'
{
  "model": "fable",
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

if command -v shasum >/dev/null 2>&1; then
  client_sha="$(shasum -a 256 "$TMP_DIR/fake-claude" | awk '{print $1}')"
else
  client_sha="$(sha256sum "$TMP_DIR/fake-claude" | awk '{print $1}')"
fi

cat >"$TMP_DIR/config.json" <<EOF
{
  "command": "$TMP_DIR/fake-claude",
  "config_dir": "$TMP_DIR/profile-stable",
  "allowed_ips": ["203.0.113.10"],
  "client_version": "2.1.220",
  "client_sha256": "$client_sha",
  "require_unpinned_model": false
}
EOF

run_guard() {
  PATH="$TMP_DIR/bin:$PATH" \
    CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
    CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
    CLAUDE_GUARD_ASSUME_YES=1 \
    CLAUDE_GUARD_WATCHDOG=0 \
    "$ROOT_DIR/bin/claude-guard" "$@"
}

run_guard --fake-run >"$TMP_DIR/launch.out" 2>&1
grep -qx "CLAUDE_CONFIG_DIR=$TMP_DIR/profile-stable" "$TMP_DIR/fake-claude.env"
grep -qx -- '--settings' "$TMP_DIR/fake-claude.args"
grep -qx "$TMP_DIR/profile-stable/settings.json" "$TMP_DIR/fake-claude.args"
grep -qx 'old-session-sentinel' "$TMP_DIR/profile-stable/projects/sample/session.jsonl"

jq '.require_unpinned_model = true' "$TMP_DIR/config.json" \
  >"$TMP_DIR/config.unpinned.json"
mv "$TMP_DIR/config.unpinned.json" "$TMP_DIR/config.json"
if run_guard --precheck-only >"$TMP_DIR/pinned-model.out" 2>&1; then
  printf 'opt-in unpinned-model policy unexpectedly passed\n' >&2
  exit 1
fi
grep -q '固定 model' "$TMP_DIR/pinned-model.out"
jq '.require_unpinned_model = false' "$TMP_DIR/config.json" \
  >"$TMP_DIR/config.continuity.json"
mv "$TMP_DIR/config.continuity.json" "$TMP_DIR/config.json"

rm -f "$TMP_DIR/fake-claude.started"
jq '.allowed_ips = ["198.51.100.20"]' "$TMP_DIR/config.json" \
  >"$TMP_DIR/config.bad-ip.json"
mv "$TMP_DIR/config.bad-ip.json" "$TMP_DIR/config.json"
if printf 'unsafe\n' | run_guard \
  >"$TMP_DIR/unsafe.out" 2>&1; then
  printf 'unsafe override unexpectedly passed\n' >&2
  exit 1
fi
grep -q '不提供 unsafe 绕过' "$TMP_DIR/unsafe.out"
if [ -e "$TMP_DIR/fake-claude.started" ]; then
  printf 'unsafe override started the client\n' >&2
  exit 1
fi

printf 'v2 continuity policy ok\n'
