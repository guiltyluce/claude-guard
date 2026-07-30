#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/tests/smoke.sh"
"$ROOT_DIR/tests/preflight_ui.sh"
"$ROOT_DIR/tests/watchdog_state_machine.sh"
"$ROOT_DIR/tests/lifecycle_policy.sh"
"$ROOT_DIR/tests/cc_lane.sh"
"$ROOT_DIR/tests/v2_upgrade_policy.sh"
