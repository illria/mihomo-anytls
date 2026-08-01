#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT_DIR/tools/self-update.sh"
INSTALLER="$ROOT_DIR/install.sh"
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
assert_no_update_temps(){
  [ -z "$(find "$TEST_ROOT" -type f \( -name 'update.*' -o -name '.*.update.*' -o -name '.*.backup.*' -o -name '.mihomo-anytls-self-update.*' \) -print -quit)" ] ||
    fail "temporary update file remained"
}

bash -n "$TOOL"
bash -n "$INSTALLER"
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
CRON_SCHEDULE="17 4 * * *"

LOCK_CALLS="$TEST_ROOT/lock.calls"
has(){
  if [ "$1" = flock ]; then return 0; fi
  command -v "$1" >/dev/null 2>&1
}
flock(){
  printf '%s\n' "$*" >> "$LOCK_CALLS"
  [ "$1" = -n ]
}
valid_download(){
  printf '%s\n' '#!/usr/bin/env bash' 'echo updated' > "$1"
}

# The manual entrypoint and the non-interactive entrypoint share install_command/flock.
download_install(){ valid_download "$1"; }
run_update
assert_file_contains 'echo updated' "$BIN_MAIN"
assert_file_contains 'echo updated' "$BIN_SHORT"
cmp -s "$BIN_MAIN" "$BIN_SHORT" || fail "successful command contents differ"
assert_contains '-n 9' "$LOCK_CALLS"
assert_no_update_temps
assert_contains '--self-update-run' "$INSTALLER"
assert_contains 'run_remote_script "$SELF_UPDATE_URL" run-update' "$INSTALLER"

# A lock miss returns nonzero, prints a clear state, and writes the same log.
flock(){
  printf '%s\n' "$*" >> "$LOCK_CALLS"
  return 1
}
if lock_output="$(run_update 2>&1)"; then
  fail "lock contention returned success"
fi
assert_contains '跳过本次更新' <(printf '%s\n' "$lock_output")
assert_file_contains '跳过本次更新' "$LOG_FILE"
flock(){
  printf '%s\n' "$*" >> "$LOCK_CALLS"
  [ "$1" = -n ]
}

# Download failure and syntax failure preserve both old commands.
printf '%s\n' 'old-main' > "$BIN_MAIN"
printf '%s\n' 'old-short' > "$BIN_SHORT"
download_install(){ return 1; }
if run_update >"$TEST_ROOT/download-failure.out" 2>&1; then fail "download failure returned success"; fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
assert_no_update_temps

download_install(){ printf '%s\n' 'this is not valid shell (' > "$1"; }
if run_update >"$TEST_ROOT/syntax-failure.out" 2>&1; then fail "syntax failure returned success"; fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
assert_no_update_temps

# Failure while preparing the second staged file leaves both old commands unchanged.
download_install(){ valid_download "$1"; }
install(){
  case "$*" in
    *".en-mi.update."*) return 1 ;;
  esac
  command install "$@"
}
if run_update >"$TEST_ROOT/stage-failure.out" 2>&1; then fail "stage failure returned success"; fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
unset -f install
assert_no_update_temps

# If the first final rename succeeds and the second fails, both files roll back.
FAIL_SHORT_MOVE=true
mv(){
  local destination="${!#}"
  if [ "$FAIL_SHORT_MOVE" = true ] && [ "$destination" = "$BIN_SHORT" ]; then
    FAIL_SHORT_MOVE=false
    return 1
  fi
  command mv "$@"
}
if run_update >"$TEST_ROOT/rename-failure.out" 2>&1; then fail "rename failure returned success"; fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
unset -f mv
assert_no_update_temps

# With no old files, a failed update leaves no half-installed pair.
rm -f -- "$BIN_MAIN" "$BIN_SHORT"
install(){
  case "$*" in
    *".en-mi.update."*) return 1 ;;
  esac
  command install "$@"
}
if run_update >"$TEST_ROOT/absent-stage-failure.out" 2>&1; then fail "absent-file failure returned success"; fi
[ ! -e "$BIN_MAIN" ] || fail "main command remained after absent-file rollback"
[ ! -e "$BIN_SHORT" ] || fail "shortcut remained after absent-file rollback"
unset -f install
assert_no_update_temps

# A signal after the first final rename rolls both commands back before cleanup.
printf '%s\n' 'old-main' > "$BIN_MAIN"
printf '%s\n' 'old-short' > "$BIN_SHORT"
BACKUP_SEEN="$TEST_ROOT/update-backup-seen"
after_main_replaced_hook(){
  find "$BIN_DIR" -type f -name '.*.backup.*' -print -quit > "$BACKUP_SEEN"
  kill -INT "$BASHPID"
}
if run_update >"$TEST_ROOT/signal-update.out" 2>&1; then fail "signal update returned success"; fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
[ -s "$BACKUP_SEEN" ] || fail "signal hook did not see rollback backups"
assert_no_update_temps
unset -f after_main_replaced_hook

# Success installs two identical executable commands.
run_update
[ -x "$BIN_MAIN" ] && [ -x "$BIN_SHORT" ] || fail "success did not install both commands"
cmp -s "$BIN_MAIN" "$BIN_SHORT" || fail "successful command contents differ"
assert_no_update_temps

# write_cron atomically writes only the safe entrypoint, not duplicated update logic.
write_cron
assert_file_contains 'SHELL=/bin/bash' "$CRON_FILE"
assert_file_contains 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$CRON_FILE"
assert_file_contains '17 4 * * *' "$CRON_FILE"
assert_file_contains "\"$BIN_MAIN\" --self-update-run" "$CRON_FILE"
assert_not_contains 'mktemp' "$CRON_FILE"
assert_not_contains 'curl' "$CRON_FILE"
[ "$(cron_file_mode "$CRON_FILE")" = 644 ] || fail "cron mode is not 0644"
assert_no_update_temps

OLD_CRON="$TEST_ROOT/old-cron"
printf '%s\n' 'old cron content' > "$OLD_CRON"
cp -p "$OLD_CRON" "$CRON_FILE"
cat(){
  return 1
}
if write_cron >/dev/null 2>&1; then fail "cat failure returned success"; fi
unset -f cat
cmp -s "$OLD_CRON" "$CRON_FILE" || fail "cat failure replaced old cron"
assert_no_update_temps

chmod(){
  if [ "$1" = 644 ]; then return 1; fi
  command chmod "$@"
}
if write_cron >/dev/null 2>&1; then fail "chmod failure returned success"; fi
unset -f chmod
cmp -s "$OLD_CRON" "$CRON_FILE" || fail "chmod failure replaced old cron"
assert_no_update_temps

mv(){
  return 1
}
if write_cron >/dev/null 2>&1; then fail "mv failure returned success"; fi
unset -f mv
cmp -s "$OLD_CRON" "$CRON_FILE" || fail "mv failure replaced old cron"
assert_no_update_temps

# install_cron checks the daemon before writing, so a stopped daemon leaves no new file.
install_command(){ :; }
ensure_cron_daemon(){ :; }
start_enable_cron(){ :; }
cron_daemon_running(){ return 1; }
rm -f -- "$CRON_FILE"
if install_cron >"$TEST_ROOT/daemon-stopped.out" 2>&1; then fail "stopped daemon returned success"; fi
[ ! -e "$CRON_FILE" ] || fail "stopped daemon left a new cron file"

# If post-write validation fails, an existing cron file is restored.
cron_daemon_running(){ return 0; }
write_cron
cp -p "$CRON_FILE" "$OLD_CRON"
ORIGINAL_CRON_FILE_VALID="$(declare -f cron_file_valid)"
cron_file_valid(){ return 1; }
if install_cron >"$TEST_ROOT/post-write-failure.out" 2>&1; then fail "post-write validation returned success"; fi
cmp -s "$OLD_CRON" "$CRON_FILE" || fail "post-write failure did not restore old cron"
eval "$ORIGINAL_CRON_FILE_VALID"
assert_no_update_temps

# A stopped Alpine backend is explicitly rejected without installing or writing cron.
install_command(){ :; }
detect_pkg(){ PKG_MANAGER=apk; }
cron_daemon_running(){ return 1; }
rm -f -- "$CRON_FILE"
if alpine_output="$(install_cron 2>&1)"; then fail "Alpine backend was incorrectly accepted"; fi
assert_contains '尚未实现 Alpine cron 后端' <(printf '%s\n' "$alpine_output")
[ ! -e "$CRON_FILE" ] || fail "Alpine rejection left a cron file"

# A signal after cron replacement restores the previous cron file before cleanup.
detect_pkg(){ PKG_MANAGER=unknown; }
cron_daemon_running(){ return 0; }
write_cron
cp -p "$CRON_FILE" "$OLD_CRON"
CRON_BACKUP_SEEN="$TEST_ROOT/cron-backup-seen"
after_cron_replaced_hook(){
  find "$(dirname "$CRON_FILE")" -type f -name '.*.backup.*' -print -quit > "$CRON_BACKUP_SEEN"
  kill -INT "$BASHPID"
}
if install_cron >"$TEST_ROOT/signal-cron.out" 2>&1; then fail "signal cron update returned success"; fi
cmp -s "$OLD_CRON" "$CRON_FILE" || fail "signal cron update did not restore old cron"
[ -s "$CRON_BACKUP_SEEN" ] || fail "cron signal hook did not see rollback backup"
assert_no_update_temps
unset -f after_cron_replaced_hook

# Status marks bad permissions and missing entrypoint as invalid.
write_cron
chmod 600 "$CRON_FILE"
STATUS_DAEMON=true
cron_daemon_running(){ [ "${STATUS_DAEMON:-false}" = true ]; }
status > "$TEST_ROOT/status-bad-mode"
assert_file_contains '状态: cron 配置无效' "$TEST_ROOT/status-bad-mode"
write_cron
sed -i.bak 's/--self-update-run/--wrong-entrypoint/' "$CRON_FILE"
rm -f -- "$CRON_FILE.bak"
status > "$TEST_ROOT/status-bad-entrypoint"
assert_file_contains '状态: cron 配置无效' "$TEST_ROOT/status-bad-entrypoint"

# Status distinguishes missing commands, partial installs, mismatched commands, and healthy update.
rm -f -- "$BIN_MAIN" "$BIN_SHORT" "$CRON_FILE"
STATUS_DAEMON=false
status > "$TEST_ROOT/status-none"
assert_file_contains '状态: 未安装' "$TEST_ROOT/status-none"

printf '%s\n' 'main-only' > "$BIN_MAIN"
chmod 755 "$BIN_MAIN"
status > "$TEST_ROOT/status-main-only"
assert_file_contains '状态: 命令安装不完整' "$TEST_ROOT/status-main-only"

rm -f -- "$BIN_MAIN"
printf '%s\n' 'short-only' > "$BIN_SHORT"
chmod 755 "$BIN_SHORT"
status > "$TEST_ROOT/status-short-only"
assert_file_contains '状态: 命令安装不完整' "$TEST_ROOT/status-short-only"

printf '%s\n' 'main-version' > "$BIN_MAIN"
chmod 755 "$BIN_MAIN"
status > "$TEST_ROOT/status-mismatch"
assert_file_contains '状态: 两个管理命令版本不一致' "$TEST_ROOT/status-mismatch"

write_cron
rm -f -- "$BIN_MAIN"
STATUS_DAEMON=true
status > "$TEST_ROOT/status-cron-main-missing"
assert_file_contains '状态: 命令安装不完整' "$TEST_ROOT/status-cron-main-missing"

printf '%s\n' 'same-version' > "$BIN_MAIN"
chmod 755 "$BIN_MAIN"
printf '%s\n' 'same-version' > "$BIN_SHORT"
chmod 755 "$BIN_SHORT"
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

printf 'PASS: self-update locking, atomic rollback, cron atomic write, and status tests\n'
