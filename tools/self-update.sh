#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2026-08-02-eianun-en-mi-v5"
BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
INSTALL_URL="$BASE_URL/install.sh"
BIN_MAIN="/usr/local/bin/mihomo-anytls"
BIN_SHORT="/usr/local/bin/en-mi"
CRON_FILE="/etc/cron.d/mihomo-anytls-self-update"
LOG_FILE="/var/log/mihomo-anytls-self-update.log"
LOCK_FILE="/var/lock/mihomo-anytls-self-update.lock"
UPDATE_TMP_TEMPLATE="${UPDATE_TMP_TEMPLATE:-/tmp/mihomo-anytls-update.XXXXXX}"
CRON_SCHEDULE="17 4 * * *"

write_log(){
  local level="$1"
  shift
  [ -n "${LOG_FILE:-}" ] || return 0
  printf '[%s] %s\n' "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
info(){ printf '[INFO] %s\n' "$*"; write_log INFO "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; write_log WARN "$*"; }
err(){ printf '[ERR ] %s\n' "$*" >&2; write_log ERROR "$*"; }
die(){ err "$*"; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行。"; }

download_install(){
  local out="$1" url
  url="${INSTALL_URL}?t=$(date +%s)"
  if has curl; then
    curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$url" -o "$out"
  elif has wget; then
    wget --no-cache -qO "$out" "$url"
  else
    err "缺少 curl/wget。"
    return 1
  fi
}

replace_main_target(){
  mv -f -- "$stage_main" "$BIN_MAIN"
}
replace_short_target(){
  mv -f -- "$stage_short" "$BIN_SHORT"
}
after_main_replaced_hook(){
  :
}
handle_update_signal(){
  local code="$1"
  if [ "${transaction_started:-false}" = true ] &&
     [ "${transaction_committed:-false}" = false ] &&
     [ "${transaction_rolled_back:-false}" = false ]; then
    rollback_update || true
  fi
  exit "$code"
}
install_command() (
  local tmp="" stage_main="" stage_short="" backup_main="" backup_short=""
  local old_main=false old_short=false
  local transaction_started=false transaction_committed=false
  local transaction_rolled_back=false rollback_failed=false
  cleanup_update(){
    local f
    if [ "$transaction_started" = true ] &&
       [ "$transaction_committed" = false ] &&
       [ "$transaction_rolled_back" = false ]; then
      rollback_update || true
    fi
    for f in "$tmp" "$stage_main" "$stage_short"; do
      if [ -n "$f" ] && { [ -e "$f" ] || [ -L "$f" ]; }; then
        rm -f -- "$f"
      fi
    done
    if [ "$rollback_failed" = false ]; then
      for f in "$backup_main" "$backup_short"; do
        if [ -n "$f" ] && { [ -e "$f" ] || [ -L "$f" ]; }; then
          rm -f -- "$f"
        fi
      done
    fi
  }
  rollback_update(){
    local ok=true
    if [ "$transaction_rolled_back" = true ] || [ "$transaction_committed" = true ]; then
      return 0
    fi
    if [ "$old_main" = true ]; then
      [ -n "$backup_main" ] && mv -f -- "$backup_main" "$BIN_MAIN" || ok=false
    else
      rm -f -- "$BIN_MAIN" || ok=false
    fi
    if [ "$old_short" = true ]; then
      [ -n "$backup_short" ] && mv -f -- "$backup_short" "$BIN_SHORT" || ok=false
    else
      rm -f -- "$BIN_SHORT" || ok=false
    fi
    if [ "$ok" = true ]; then
      transaction_rolled_back=true
      info "更新失败，已恢复两个旧命令。"
    else
      rollback_failed=true
      err "高优先级: 更新回滚失败，备份已保留，请立即检查: $BIN_MAIN $BIN_SHORT"
    fi
    [ "$ok" = true ]
  }
  stage_target(){
    local target="$1" outvar="$2" dir base stage
    dir="$(dirname "$target")" || return 1
    [ -d "$dir" ] || { err "目标目录不存在: $dir"; return 1; }
    base="$(basename "$target")"
    stage="$(mktemp "$dir/.${base}.update.XXXXXX")" || return 1
    if ! install -m 755 "$tmp" "$stage"; then
      rm -f -- "$stage"
      return 1
    fi
    printf -v "$outvar" '%s' "$stage"
  }
  backup_target(){
    local target="$1" outvar="$2" dir base backup
    if [ ! -e "$target" ]; then
      printf -v "$outvar" '%s' ""
      return 0
    fi
    dir="$(dirname "$target")" || return 1
    base="$(basename "$target")"
    backup="$(mktemp "$dir/.${base}.backup.XXXXXX")" || return 1
    if ! cp -p "$target" "$backup"; then
      rm -f -- "$backup"
      return 1
    fi
    printf -v "$outvar" '%s' "$backup"
  }
  trap cleanup_update EXIT
  trap 'handle_update_signal 129' HUP
  trap 'handle_update_signal 130' INT
  trap 'handle_update_signal 143' TERM

  if has flock; then
    mkdir -p "$(dirname "$LOCK_FILE")" || { err "无法创建更新锁目录。"; return 1; }
    exec 9>"$LOCK_FILE" || { err "无法创建更新锁。"; return 1; }
    if ! flock -n 9; then
      warn "已有另一个更新任务运行，跳过本次更新。"
      return 1
    fi
  fi

  tmp="$(mktemp "$UPDATE_TMP_TEMPLATE")" || { err "无法创建临时文件。"; return 1; }
  if ! download_install "$tmp"; then
    err "下载最新管理脚本失败，保留现有命令。"
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    err "下载文件为空，保留现有命令。"
    return 1
  fi
  if ! bash -n "$tmp"; then
    err "下载脚本语法检查失败，保留现有命令。"
    return 1
  fi
  old_main=false
  old_short=false
  [ -e "$BIN_MAIN" ] && old_main=true
  [ -e "$BIN_SHORT" ] && old_short=true
  if ! stage_target "$BIN_MAIN" stage_main ||
     ! stage_target "$BIN_SHORT" stage_short; then
    err "无法准备两个原子更新文件，保留现有命令。"
    return 1
  fi
  if ! backup_target "$BIN_MAIN" backup_main ||
     ! backup_target "$BIN_SHORT" backup_short; then
    err "无法保存旧命令状态，保留现有命令。"
    return 1
  fi
  transaction_started=true
  if ! replace_main_target; then
    rollback_update || true
    return 1
  fi
  if ! after_main_replaced_hook; then
    rollback_update || true
    return 1
  fi
  if ! replace_short_target; then
    rollback_update || true
    return 1
  fi
  if ! cmp -s "$BIN_MAIN" "$BIN_SHORT"; then
    err "两个命令内容不一致，开始回滚。"
    rollback_update || true
    return 1
  fi
  transaction_committed=true
  info "已安装/更新主命令: $BIN_MAIN"
  info "已安装/更新快捷命令: $BIN_SHORT"
  info "以后可直接运行: en-mi"
  return 0
)

detect_pkg(){
  if has apt-get; then PKG_MANAGER=apt
  elif has dnf; then PKG_MANAGER=dnf
  elif has yum; then PKG_MANAGER=yum
  elif has apk; then PKG_MANAGER=apk
  elif has pacman; then PKG_MANAGER=pacman
  elif has zypper; then PKG_MANAGER=zypper
  else PKG_MANAGER=unknown
  fi
}

cron_backend_supported(){
  detect_pkg
  [ "$PKG_MANAGER" != apk ] && [ ! -f /etc/alpine-release ]
}

cron_daemon_present(){
  local daemon
  for daemon in cron crond cronie; do
    has "$daemon" && return 0
  done
  return 1
}

install_cron_package(){
  case "$PKG_MANAGER" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y cron ;;
    dnf) dnf install -y cronie ;;
    yum) yum install -y cronie ;;
    apk) err "当前版本尚未实现 Alpine cron 后端。"; return 1 ;;
    pacman) pacman -Sy --noconfirm --needed cronie ;;
    zypper) zypper --non-interactive install cron ;;
    *) err "未识别包管理器，无法安装 cron。"; return 1 ;;
  esac
}

ensure_cron_daemon(){
  if ! cron_backend_supported; then
    err "当前版本尚未实现 Alpine cron 后端，未启用每日自动更新。"
    return 1
  fi
  cron_daemon_present && return 0
  install_cron_package || return 1
  cron_daemon_present || { err "cron 安装后仍未发现 cron/crond/cronie。"; return 1; }
}

start_enable_cron(){
  local service
  if has systemctl; then
    for service in cronie cron crond; do
      systemctl enable --now "$service" >/dev/null 2>&1 && return 0
    done
  fi
  if has rc-service; then
    for service in crond cron; do
      rc-update add "$service" default >/dev/null 2>&1 || true
      rc-service "$service" start >/dev/null 2>&1 && return 0
    done
  fi
  if has service; then
    for service in cron crond cronie; do
      service "$service" start >/dev/null 2>&1 && return 0
    done
  fi
  for service in cron crond cronie; do
    if [ -x "/etc/init.d/$service" ]; then
      "/etc/init.d/$service" start >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

cron_daemon_running(){
  local daemon
  for daemon in cron crond cronie; do
    if has pgrep && pgrep -x "$daemon" >/dev/null 2>&1; then return 0; fi
    if has systemctl && systemctl is-active --quiet "$daemon" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

write_cron() (
  local cron_dir="" tmp=""
  cleanup_cron_temp(){
    if [ -n "$tmp" ] && { [ -e "$tmp" ] || [ -L "$tmp" ]; }; then
      rm -f -- "$tmp"
    fi
  }
  trap cleanup_cron_temp EXIT
  trap 'exit 130' HUP INT TERM

  cron_dir="$(dirname "$CRON_FILE")" || return 1
  if ! mkdir -p "$cron_dir"; then
    err "无法创建 cron 目录: $cron_dir"
    return 1
  fi
  tmp="$(mktemp "$cron_dir/.mihomo-anytls-self-update.XXXXXX")" || {
    err "无法创建 cron 临时文件。"
    return 1
  }
  if ! cat > "$tmp" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$CRON_SCHEDULE root "$BIN_MAIN" --self-update-run >> "$LOG_FILE" 2>&1
EOF
  then
    err "写入 cron 临时文件失败，保留旧配置。"
    return 1
  fi
  if ! grep -Fq 'SHELL=/bin/bash' "$tmp" ||
     ! grep -Fq 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$tmp" ||
     ! grep -Fq "$CRON_SCHEDULE" "$tmp" ||
     ! grep -Fq "\"$BIN_MAIN\" --self-update-run" "$tmp"; then
    err "cron 临时文件内容校验失败，保留旧配置。"
    return 1
  fi
  if ! chmod 644 "$tmp"; then
    err "设置 cron 临时文件权限失败，保留旧配置。"
    return 1
  fi
  if ! mv -f -- "$tmp" "$CRON_FILE"; then
    err "替换 cron 文件失败，保留旧配置。"
    return 1
  fi
  tmp=""
  return 0
)

cron_file_mode(){
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true)"
  printf '%s' "$mode"
}
cron_content_valid(){
  local file="$1"
  grep -Fq 'SHELL=/bin/bash' "$file" &&
    grep -Fq 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$file" &&
    grep -Fq "$CRON_SCHEDULE" "$file" &&
    grep -Fq "\"$BIN_MAIN\" --self-update-run" "$file"
}
cron_file_valid(){
  [ -f "$CRON_FILE" ] &&
    [ "$(cron_file_mode "$CRON_FILE")" = "644" ] &&
    cron_content_valid "$CRON_FILE"
}

rollback_cron_update(){
  local ok=true
  if [ "${cron_transaction_rolled_back:-false}" = true ] ||
     [ "${cron_transaction_committed:-false}" = true ]; then
    return 0
  fi
  if [ "$cron_old_exists" = true ]; then
    [ -n "$cron_backup" ] && mv -f -- "$cron_backup" "$CRON_FILE" || ok=false
  else
    rm -f -- "$CRON_FILE" || ok=false
  fi
  if [ "$ok" = true ]; then
    cron_transaction_rolled_back=true
  else
    cron_rollback_failed=true
    err "高优先级: cron 回滚失败，备份已保留，请立即检查: $CRON_FILE"
  fi
  [ "$ok" = true ]
}
handle_cron_signal(){
  local code="$1"
  if [ "${cron_transaction_started:-false}" = true ] &&
     [ "${cron_transaction_committed:-false}" = false ] &&
     [ "${cron_transaction_rolled_back:-false}" = false ]; then
    rollback_cron_update || true
  fi
  exit "$code"
}
after_cron_replaced_hook(){
  :
}
save_cron_backup(){
  local cron_dir="$1" outvar="$2" saved
  if [ ! -e "$CRON_FILE" ]; then
    printf -v "$outvar" '%s' ""
    return 0
  fi
  saved="$(mktemp "$cron_dir/.mihomo-anytls-self-update.backup.XXXXXX")" || return 1
  if ! cp -p "$CRON_FILE" "$saved"; then
    rm -f -- "$saved"
    return 1
  fi
  printf -v "$outvar" '%s' "$saved"
}
install_cron() (
  local cron_dir="" cron_backup="" cron_old_exists=false
  local cron_transaction_started=false cron_transaction_committed=false
  local cron_transaction_rolled_back=false cron_rollback_failed=false
  cleanup_cron_transaction(){
    if [ "$cron_transaction_started" = true ] &&
       [ "$cron_transaction_committed" = false ] &&
       [ "$cron_transaction_rolled_back" = false ]; then
      rollback_cron_update || true
    fi
    if [ "$cron_rollback_failed" = false ] &&
       [ -n "$cron_backup" ] &&
       { [ -e "$cron_backup" ] || [ -L "$cron_backup" ]; }; then
      rm -f -- "$cron_backup"
    fi
  }
  trap cleanup_cron_transaction EXIT
  trap 'handle_cron_signal 129' HUP
  trap 'handle_cron_signal 130' INT
  trap 'handle_cron_signal 143' TERM

  install_command || return 1
  ensure_cron_daemon || { err "无法安装 cron，未启用每日自动更新。"; return 1; }
  start_enable_cron || { err "无法启动或启用 cron，未启用每日自动更新。"; return 1; }
  cron_daemon_running || { err "cron daemon 未运行，未启用每日自动更新。"; return 1; }

  cron_dir="$(dirname "$CRON_FILE")" || return 1
  if ! mkdir -p "$cron_dir"; then
    err "无法创建 cron 目录，未启用每日自动更新。"
    return 1
  fi
  [ -e "$CRON_FILE" ] && cron_old_exists=true
  if ! save_cron_backup "$cron_dir" cron_backup; then
    err "无法保存旧 cron 配置，未启用每日自动更新。"
    return 1
  fi
  cron_transaction_started=true
  if ! write_cron; then
    rollback_cron_update || true
    err "写入 cron 失败，未启用每日自动更新。"
    return 1
  fi
  if ! after_cron_replaced_hook; then
    rollback_cron_update || true
    return 1
  fi
  if ! cron_file_valid || ! cron_daemon_running; then
    rollback_cron_update || true
    err "cron 配置验证失败，已恢复旧配置，未启用每日自动更新。"
    return 1
  fi
  cron_transaction_committed=true
  [ -n "$cron_backup" ] && rm -f -- "$cron_backup"
  cron_backup=""
  info "已启用每日自动更新: $CRON_FILE"
)

remove_cron(){
  rm -f -- "$CRON_FILE"
  info "已关闭每日自动更新。"
}

next_schedule(){
  [ -f "$CRON_FILE" ] || { printf '未设置\n'; return 0; }
  awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "每天 %02d:%02d\n", $2, $1; found=1; exit } END { if (!found) print "未知" }' "$CRON_FILE"
}

status(){
  local main_exists=false short_exists=false main_ok=false short_ok=false commands_match=false
  local cron_exists=false cron_ok=false daemon_ok=false backend_supported=true
  echo "主命令: $BIN_MAIN"
  if [ -e "$BIN_MAIN" ]; then main_exists=true; fi
  if [ -x "$BIN_MAIN" ]; then main_ok=true; echo "  已安装且可执行"; else echo "  未安装或不可执行"; fi
  echo "快捷命令: $BIN_SHORT"
  if [ -e "$BIN_SHORT" ]; then short_exists=true; fi
  if [ -x "$BIN_SHORT" ]; then short_ok=true; echo "  已安装且可执行"; else echo "  未安装或不可执行"; fi
  if [ "$main_ok" = true ] && [ "$short_ok" = true ] && cmp -s "$BIN_MAIN" "$BIN_SHORT"; then
    commands_match=true
  fi
  echo "当前脚本版本: $SCRIPT_VERSION"
  if ! cron_backend_supported; then
    backend_supported=false
    echo "cron 后端: Alpine/apk（当前版本不支持）"
  fi
  echo "cron 文件: $CRON_FILE"
  if [ -e "$CRON_FILE" ]; then
    cron_exists=true
    echo "  存在"
    if cron_file_valid; then
      cron_ok=true
      echo "  格式、权限和入口有效"
      echo "下一次计划更新时间: $(next_schedule)"
    else
      echo "  配置无效"
      echo "下一次计划更新时间: 未验证"
    fi
  else
    echo "  不存在"
    echo "下一次计划更新时间: 未设置"
  fi
  if cron_daemon_running; then daemon_ok=true; echo "cron daemon: 运行中"; else echo "cron daemon: 未运行"; fi
  if [ "$backend_supported" = false ]; then
    echo "状态: 当前版本不支持 Alpine 自动更新后端"
  elif [ "$main_exists" = false ] && [ "$short_exists" = false ]; then
    echo "状态: 未安装"
  elif [ "$main_ok" = false ] || [ "$short_ok" = false ]; then
    echo "状态: 命令安装不完整"
  elif [ "$commands_match" = false ]; then
    echo "状态: 两个管理命令版本不一致"
  elif [ "$cron_exists" = true ] && [ "$cron_ok" = false ]; then
    echo "状态: cron 配置无效"
  elif [ "$cron_exists" = false ]; then
    echo "状态: 命令已安装但 cron 未启用"
  elif [ "$daemon_ok" = false ]; then
    echo "状态: cron 文件存在但 daemon 未运行"
  else
    echo "状态: 自动更新正常"
  fi
}

menu(){
  echo "============================================================"
  echo " mihomo-anytls 自动更新"
  echo " 作者: Eianun"
  echo "============================================================"
  echo "  1) 立即更新本机管理命令"
  echo "  2) 启用每日自动更新（同时立即更新一次）"
  echo "  3) 关闭每日自动更新"
  echo "  4) 查看自动更新状态"
  echo "  0) 退出"
  read -r -p "输入序号 [1]: " c
  c="${c:-1}"
  case "$c" in
    1) install_command ;;
    2) install_cron ;;
    3) remove_cron ;;
    4) status ;;
    0) exit 0 ;;
    *) die "无效操作：$c" ;;
  esac
}

run_update(){ install_command; }

main(){
  need_root
  case "${1:-}" in
    install|update|run-update) install_command ;;
    cron|enable) install_cron ;;
    disable) remove_cron ;;
    status) status ;;
    "") menu ;;
    *) menu ;;
  esac
}

main "$@"
