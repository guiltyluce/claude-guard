#!/usr/bin/env bash
set -euo pipefail

# bin/claude-guard 的 client_macos_team_id 分支此前没有任何测试覆盖。它是平台相关的：
# 在 Darwin 上走真实 codesign，在其他平台上必须 fail-closed。因此本用例按平台分流断言，
# 两条分支合起来才是完整覆盖 —— 少跑任何一个平台都会留下盲区。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/home" "$TMP_DIR/bin"

EXPECTED_TEAM="Q6L2SF6YDW"

# 直接复用仓库里的官方 settings 示例：生命周期策略升级时它会一起更新，fixture 不会过期。
cp "$ROOT_DIR/config/official-settings-lifecycle.example.json" "$TMP_DIR/settings.json"
printf 'fake ca\n' >"$TMP_DIR/cert.pem"

printf '#!/usr/bin/env bash\nprintf "9.9.9 (fake)\\n"\n' >"$TMP_DIR/bin/claude"
chmod +x "$TMP_DIR/bin/claude"

cat >"$TMP_DIR/allowed.json" <<JSON
{"command":"$TMP_DIR/bin/claude","allowed_ips":["203.0.113.10"],"client_macos_team_id":"$EXPECTED_TEAM"}
JSON

# $1 = verify 退出码，$2 = TeamIdentifier 值
make_codesign() {
  local dir="$TMP_DIR/cs-$3"
  mkdir -p "$dir"
  cat >"$dir/codesign" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "--verify" ]; then
    exit $1
  fi
done
# 真实 codesign 的 -dv 输出走 stderr，实现里用 2>&1 收，这里保持一致。
printf 'Executable=%s\n' "\$2" >&2
printf 'Identifier=com.example.fake\n' >&2
printf 'TeamIdentifier=%s\n' '$2' >&2
exit 0
EOF
  chmod +x "$dir/codesign"
  printf '%s\n' "$dir"
}

run_precheck() {
  (
    cd "$TMP_DIR"
    HOME="$TMP_DIR/home" \
      USER="guard-test" \
      PATH="${1:-$TMP_DIR/bin}:$PATH" \
      LANG="en_US.UTF-8" \
      CLAUDE_GUARD_CONFIG="$TMP_DIR/allowed.json" \
      CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings.json" \
      CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
      CLAUDE_GUARD_IP_RETRIES=1 \
      CLAUDE_GUARD_TLS_RETRIES=1 \
      CLAUDE_GUARD_UI=never \
      "$ROOT_DIR/bin/claude-guard" --precheck-only
  )
}

fail() {
  printf '%s\n' "$1" >&2
  shift
  cat "$@" >&2
  exit 1
}

if [ "$(uname -s)" = "Darwin" ]; then
  # --- 1. 签名有效且 Team ID 匹配：签名这一步必须放行 ---
  out="$TMP_DIR/out-pass"
  set +e
  run_precheck "$(make_codesign 0 "$EXPECTED_TEAM" pass)" >"$out" 2>&1
  status=$?
  set -e
  # 后续的网络检查会失败（没有真代理），这里只断言签名这一关过了，且不是 12。
  if [ "$status" -eq 12 ]; then
    fail 'valid signature must not exit 12' "$out"
  fi
  if ! grep -q "team=$EXPECTED_TEAM" "$out"; then
    fail 'valid signature must report the pinned team id' "$out"
  fi

  # --- 2. codesign --verify 不通过：必须 exit 12，且指名 codesign ---
  out="$TMP_DIR/out-verify"
  set +e
  run_precheck "$(make_codesign 1 "$EXPECTED_TEAM" verify)" >"$out" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 12 ]; then
    fail "codesign verify failure returned $status instead of 12" "$out"
  fi
  if ! grep -q 'codesign 未通过' "$out"; then
    fail 'codesign verify failure must name codesign' "$out"
  fi

  # --- 3. 签名有效但 Team ID 不匹配：这是伪装成官方客户端的形态，必须 exit 12 ---
  #     断言里带上两个 Team ID，因为「报错出现了」不等于「报的是对的那一个」。
  out="$TMP_DIR/out-team"
  set +e
  run_precheck "$(make_codesign 0 "AAAAAAAAAA" team)" >"$out" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 12 ]; then
    fail "team mismatch returned $status instead of 12" "$out"
  fi
  if ! grep -q "期望 Team ID $EXPECTED_TEAM" "$out"; then
    fail 'team mismatch must report the expected team id' "$out"
  fi
  if ! grep -q 'AAAAAAAAAA' "$out"; then
    fail 'team mismatch must report the actual team id' "$out"
  fi

  printf 'client signature ok (darwin: 3 cases)\n'
else
  # --- 非 Darwin：配置要求 Team ID 但平台无法执行 codesign，必须 fail-closed ---
  # 这一支只有 Linux runner 能覆盖，正是平台矩阵存在的理由之一。
  out="$TMP_DIR/out-nondarwin"
  set +e
  run_precheck "$TMP_DIR/bin" >"$out" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 12 ]; then
    fail "non-darwin with pinned team id returned $status instead of 12" "$out"
  fi
  if ! grep -q '当前平台无法使用 codesign' "$out"; then
    fail 'non-darwin failure must name the platform limitation' "$out"
  fi
  # 不得静默降级为 unpinned 放行。
  if grep -q 'team=unpinned' "$out"; then
    fail 'pinned team id must never degrade to unpinned' "$out"
  fi

  printf 'client signature ok (non-darwin: fail-closed)\n'
fi
