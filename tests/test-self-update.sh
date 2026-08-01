#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT_DIR/tools/self-update.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail(){
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
assert_contains(){
  local needle="$1" file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "expected '$needle' in $file"
}
assert_not_contains(){
  local needle="$1" file="$2"
  ! grep -F -- "$needle" "$file" >/dev/null || fail "did not expect '$needle' in $file"
}
assert_file_contains(){
  local needle="$1" file="$2"
  [ -f "$file" ] || fail "expected file $file"
  assert_contains "$needle" "$file"
}
assert_file_not_contains(){
  local needle="$1" file="$2"
  [ -f "$file" ] || fail "expected file $file"
  assert_not_contains "$needle" "$file"
}

bash -n "$TOOL"
STRIPPED="$TEST_ROOT/self-update-no-main.sh"
sed '/^main "\$@"$/d' "$TOOL" > "$STRIPPED"
# shellcheck disable=SC1090
source "$STRIPPED"

BIN_DIR="$TEST_ROOT/bin"
mkdir -p "$BIN_DIR"
BIN_MAIN="$BIN_DIR/mihomo-anytls"
BIN_SHORT="$BIN_DIR/en-mi"
CRON_FILE="$TEST_ROOT/cron/mihomo-anytls-self-update"
LOG_FILE="$TEST_ROOT/self-update.log"
LOCK_FILE="$TEST_ROOT/self-update.lock"
UPDATE_TMP_TEMPLATE="$TEST_ROOT/update.XXXXXX"
INSTALL_URL="https://example.invalid/install.sh"

valid_download(){
  printf '%s\n' '#!/usr/bin/env bash' 'echo updated' > "$1"
}

# Successful install must not trigger the EXIT-trap/local-variable bug.
download_install(){ valid_download "$1"; }
install_command
[ -x "$BIN_MAIN" ] || fail "main command was not installed"
[ -x "$BIN_SHORT" ] || fail "shortcut command was not installed"
assert_file_contains 'echo updated' "$BIN_MAIN"
assert_file_contains 'echo updated' "$BIN_SHORT"
[ -z "$(find "$TEST_ROOT" -maxdepth 1 -name 'update.*' -print -quit)" ] ||
  fail "temporary update file was not removed"

# Download failure keeps both existing commands unchanged.
printf '%s\n' 'old-main' > "$BIN_MAIN"
printf '%s\n' 'old-short' > "$BIN_SHORT"
download_install(){ return 1; }
if install_command >"$TEST_ROOT/download-failure.out" 2>&1; then
  fail "download failure returned success"
fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
assert_file_not_contains 'updated' "$BIN_MAIN"
assert_file_not_contains 'updated' "$BIN_SHORT"
[ -z "$(find "$TEST_ROOT" -maxdepth 1 -name 'update.*' -print -quit)" ] ||
  fail "temporary file remained after download failure"

# Syntax failure also keeps both existing commands unchanged.
download_install(){ printf '%s\n' 'this is not valid shell (' > "$1"; }
if install_command >"$TEST_ROOT/syntax-failure.out" 2>&1; then
  fail "syntax failure returned success"
fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
assert_file_not_contains 'this is not valid shell' "$BIN_MAIN"
assert_file_not_contains 'this is not valid shell' "$BIN_SHORT"
[ -z "$(find "$TEST_ROOT" -maxdepth 1 -name 'update.*' -print -quit)" ] ||
  fail "temporary file remained after syntax failure"

# The cron command keeps runtime variables literal and escapes cron's percent.
write_cron
assert_file_contains '$tmp' "$CRON_FILE"
assert_file_contains '$(date +\%s)' "$CRON_FILE"
assert_not_contains "$(date +%s)" "$CRON_FILE"
[ "$(cron_file_mode "$CRON_FILE")" = 644 ] || fail "cron mode is not 0644"

# Cron must not be reported enabled if its daemon is not running.
install_command(){ return 0; }
cron_daemon_present(){ return 0; }
start_enable_cron(){ return 0; }
cron_daemon_running(){ return 1; }
if cron_output="$(install_cron 2>&1)"; then
  fail "install_cron succeeded while daemon was stopped"
fi
assert_not_contains '已启用每日自动更新' <(printf '%s\n' "$cron_output")

# A running daemon permits the enabled state.
cron_daemon_running(){ return 0; }
cron_output="$(install_cron 2>&1)" || fail "install_cron failed with a running daemon"
assert_contains '已启用每日自动更新' <(printf '%s\n' "$cron_output")
[ "$(cron_file_mode "$CRON_FILE")" = 644 ] || fail "cron mode changed from 0644"

# Status distinguishes all four states without touching system paths.
cron_daemon_running(){ [ "${STATUS_DAEMON:-false}" = true ]; }
rm -f -- "$BIN_MAIN" "$BIN_SHORT" "$CRON_FILE"
STATUS_DAEMON=false
status > "$TEST_ROOT/status-none"
assert_file_contains '状态: 未安装' "$TEST_ROOT/status-none"

install -m 755 /bin/sh "$BIN_MAIN"
install -m 755 /bin/sh "$BIN_SHORT"
rm -f -- "$CRON_FILE"
status > "$TEST_ROOT/status-commands"
assert_file_contains '状态: 命令已安装但 cron 未启用' "$TEST_ROOT/status-commands"

write_cron
STATUS_DAEMON=false
status > "$TEST_ROOT/status-stopped"
assert_file_contains '状态: cron 文件存在但 daemon 未运行' "$TEST_ROOT/status-stopped"

STATUS_DAEMON=true
status > "$TEST_ROOT/status-normal"
assert_file_contains '状态: 自动更新正常' "$TEST_ROOT/status-normal"

printf 'PASS: self-update cleanup, safe install, cron, and status tests\n'
