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
assert_not_contains 'install_shortcuts' "$INSTALLER"
assert_not_contains 'install -m 755 "$tmp" "$BIN_MAIN"' "$INSTALLER"
assert_not_contains 'install -m 755 "$tmp" "$BIN_SHORT"' "$INSTALLER"
lock_line="$(grep -n 'flock -n 9' "$TOOL" | head -n1 | cut -d: -f1)"
replace_line="$(grep -n 'replace_main_target' "$TOOL" | tail -n1 | cut -d: -f1)"
[ "$lock_line" -lt "$replace_line" ] || fail "flock is not before the first target replacement"
STRIPPED="$TEST_ROOT/self-update-no-main.sh"
sed '/^main "\$@"$/d' "$TOOL" > "$STRIPPED"
# shellcheck disable=SC1090
source "$STRIPPED"
ORIGINAL_ENSURE_CRON_DAEMON="$(declare -f ensure_cron_daemon)"

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
assert_contains 'run_remote_script_noninteractive "$SELF_UPDATE_URL" run-update' "$INSTALLER"
assert_contains 'bash "$file" "$@" </dev/null' "$INSTALLER"
assert_contains 'execute_remote_script_from_tty "$file" "$@"' "$INSTALLER"
assert_contains 'bash "$file" "$@" </dev/tty' "$INSTALLER"
assert_not_contains '/dev/tty' "$TOOL"
assert_not_contains 'run_remote_script "$SELF_UPDATE_URL" run-update' "$INSTALLER"

# The full install.sh entry dispatches once and never initializes shortcut installation.
ENTRY_STRIPPED="$TEST_ROOT/install-no-main.sh"
sed '/^main "$@"$/d' "$INSTALLER" > "$ENTRY_STRIPPED"
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  need_root(){ :; }
  install_shortcuts(){ fail "legacy shortcut installer was called"; }
  ENTRY_CALLS=0
  run_self_update_once(){ ENTRY_CALLS=$((ENTRY_CALLS + 1)); }
  main --self-update-run
  [ "$ENTRY_CALLS" -eq 1 ] || fail "self-update entry was not called exactly once"
)

# The complete install.sh self-update entry is noninteractive and never opens /dev/tty.
ENTRY_STRIPPED="$TEST_ROOT/install-no-main.sh"
sed '/^main "\$@"$/d' "$INSTALLER" > "$ENTRY_STRIPPED"
REMOTE_PAYLOAD="$TEST_ROOT/fake-self-update.sh"
REMOTE_SCRIPT="$TEST_ROOT/downloaded-self-update.sh"
REMOTE_RESULT="$TEST_ROOT/remote-result"
cat > "$REMOTE_PAYLOAD" <<'EOF'
#!/usr/bin/env bash
[ "$1" = run-update ] || exit 41
[ ! -t 0 ] || exit 42
printf '%s\n' "$1" > "$REMOTE_RESULT"
EOF
chmod 755 "$REMOTE_PAYLOAD"
export REMOTE_RESULT
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  need_root(){ :; }
  make_tmp(){ printf '%s' "$REMOTE_SCRIPT"; }
  download_file(){ cp "$REMOTE_PAYLOAD" "$2"; }
  execute_remote_script_interactive(){ fail "interactive executor was called"; }
  main --self-update-run
)
assert_file_contains 'run-update' "$REMOTE_RESULT"

# A noninteractive download failure returns nonzero and does not enter the menu.
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  need_root(){ :; }
  make_tmp(){ printf '%s' "$REMOTE_SCRIPT"; }
  download_file(){ return 1; }
  execute_remote_script_interactive(){ fail "interactive executor was called"; }
  if output="$(main --self-update-run 2>&1)"; then
    fail "noninteractive download failure returned success"
  fi
  assert_not_contains '统一管理菜单' <(printf '%s\n' "$output")
)

# Exercise the production download_file implementation with curl/wget mocks.
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  DOWNLOAD_OUT="$TEST_ROOT/raw-download"
  RESULT="$TEST_ROOT/raw-result"
  export RESULT
  MODE=curl-fail
  CHMOD_CALLED=false
  has(){
    case "$1" in
      curl) [[ "$MODE" == curl-* ]] && return 0 ;;
      wget) [[ "$MODE" == wget-* ]] && return 0 ;;
    esac
    return 1
  }
  chmod(){
    CHMOD_CALLED=true
    command chmod "$@"
  }
  curl(){
    case "$MODE" in
      curl-fail) return 7 ;;
      curl-empty) : > "$8" ;;
      curl-syntax) printf '%s\n' '#!/usr/bin/env bash' 'if (' > "$8" ;;
      curl-valid) printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1" > "$RESULT"' > "$8" ;;
    esac
  }
  wget(){
    case "$MODE" in
      wget-fail) return 8 ;;
      wget-empty) : > "$3" ;;
      wget-syntax) printf '%s\n' '#!/usr/bin/env bash' 'if (' > "$3" ;;
      wget-valid) printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$1" > "$RESULT"' > "$3" ;;
    esac
  }

  MODE=curl-fail
  rm -f -- "$DOWNLOAD_OUT"
  if download_file https://example.invalid/curl "$DOWNLOAD_OUT"; then fail "curl failure returned success"; fi
  [ "$CHMOD_CALLED" = false ] || fail "curl failure reached chmod"
  [ ! -e "$DOWNLOAD_OUT" ] || fail "curl failure left output"

  MODE=wget-fail
  CHMOD_CALLED=false
  rm -f -- "$DOWNLOAD_OUT"
  if download_file https://example.invalid/wget "$DOWNLOAD_OUT"; then fail "wget failure returned success"; fi
  [ "$CHMOD_CALLED" = false ] || fail "wget failure reached chmod"
  [ ! -e "$DOWNLOAD_OUT" ] || fail "wget failure left output"

  MODE=curl-empty
  CHMOD_CALLED=false
  if download_file https://example.invalid/empty "$DOWNLOAD_OUT"; then fail "empty curl download returned success"; fi
  [ "$CHMOD_CALLED" = false ] || fail "empty download reached chmod"
  [ ! -e "$DOWNLOAD_OUT" ] || fail "empty download left output"

  MODE=curl-syntax
  CHMOD_CALLED=false
  if download_file https://example.invalid/syntax "$DOWNLOAD_OUT"; then fail "syntax error returned success"; fi
  [ "$CHMOD_CALLED" = false ] || fail "syntax error reached chmod"
  [ ! -e "$DOWNLOAD_OUT" ] || fail "syntax error left output"

  MODE=wget-valid
  CHMOD_CALLED=false
  download_file https://example.invalid/valid "$DOWNLOAD_OUT"
  [ -x "$DOWNLOAD_OUT" ] || fail "valid download was not executable"
  bash "$DOWNLOAD_OUT" run-update
  assert_file_contains 'run-update' "$RESULT"

  MODE=curl-valid
  chmod(){
    return 1
  }
  rm -f -- "$DOWNLOAD_OUT"
  if download_file https://example.invalid/chmod "$DOWNLOAD_OUT"; then fail "chmod failure returned success"; fi
  [ ! -e "$DOWNLOAD_OUT" ] || fail "chmod failure left output"
)
# The production interactive executor selects direct stdin, controlling TTY, or a clear error.
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  FAKE_SCRIPT="$TEST_ROOT/interactive-script"
  DIRECT_RESULT="$TEST_ROOT/direct-stdin"
  TTY_RESULT="$TEST_ROOT/tty-stdin"
  printf '%s\n' '#!/usr/bin/env bash' > "$FAKE_SCRIPT"
  stdin_is_interactive(){ return 0; }
  bash(){
    if [ "$1" = "$FAKE_SCRIPT" ]; then
      : > "$DIRECT_RESULT"
      return 0
    fi
    command bash "$@"
  }
  execute_remote_script_interactive "$FAKE_SCRIPT" direct
  [ -f "$DIRECT_RESULT" ] || fail "TTY stdin branch was not selected"
)
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  FAKE_SCRIPT="$TEST_ROOT/interactive-script-tty"
  TTY_RESULT="$TEST_ROOT/tty-stdin"
  printf '%s\n' '#!/usr/bin/env bash' > "$FAKE_SCRIPT"
  stdin_is_interactive(){ return 1; }
  controlling_tty_available(){ return 0; }
  execute_remote_script_from_tty(){
    [ "$1" = "$FAKE_SCRIPT" ] || fail "wrong TTY script"
    : > "$TTY_RESULT"
  }
  execute_remote_script_interactive "$FAKE_SCRIPT" tty
  [ -f "$TTY_RESULT" ] || fail "controlling TTY branch was not selected"
  controlling_tty_available(){ return 1; }
  if execute_remote_script_interactive "$FAKE_SCRIPT" no-tty; then
    fail "interactive executor succeeded without a TTY"
  fi
)
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
  handle_update_signal 130
}
if run_update >"$TEST_ROOT/signal-update.out" 2>&1; then fail "signal update returned success"; fi
assert_file_contains 'old-main' "$BIN_MAIN"
assert_file_contains 'old-short' "$BIN_SHORT"
[ -s "$BACKUP_SEEN" ] || fail "signal hook did not see rollback backups"
assert_no_update_temps
unset -f after_main_replaced_hook
after_main_replaced_hook(){ :; }

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
eval "$ORIGINAL_ENSURE_CRON_DAEMON"
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
  handle_cron_signal 130
}
if install_cron >"$TEST_ROOT/signal-cron.out" 2>&1; then fail "signal cron update returned success"; fi
cmp -s "$OLD_CRON" "$CRON_FILE" || fail "signal cron update did not restore old cron"
[ -s "$CRON_BACKUP_SEEN" ] || fail "cron signal hook did not see rollback backup"
assert_no_update_temps
unset -f after_cron_replaced_hook
after_cron_replaced_hook(){ :; }

# An Alpine marker makes status reject even a legacy cron.d file and running daemon.
detect_pkg(){ PKG_MANAGER=apk; }
cron_daemon_running(){ return 0; }
write_cron
status > "$TEST_ROOT/status-alpine"
assert_file_contains '状态: 当前版本不支持 Alpine 自动更新后端' "$TEST_ROOT/status-alpine"
assert_file_not_contains '状态: 自动更新正常' "$TEST_ROOT/status-alpine"
detect_pkg(){ PKG_MANAGER=unknown; }

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
