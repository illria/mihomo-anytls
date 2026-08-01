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

install_command() (
  local tmp="" stage_main="" stage_short="" backup_main="" backup_short=""
  local old_main=false old_short=false
  cleanup_update(){
    local f
    for f in "$tmp" "$stage_main" "$stage_short" "$backup_main" "$backup_short"; do
      if [ -n "$f" ] && { [ -e "$f" ] || [ -L "$f" ]; }; then
        rm -f -- "$f"
      fi
    done
  }
  rollback_update(){
    local ok=true
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
      info "更新失败，已恢复两个旧命令。"
    else
      err "更新失败，且旧命令恢复失败，请立即检查: $BIN_MAIN $BIN_SHORT"
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
  trap 'exit 130' HUP INT TERM

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
  if ! mv -f -- "$stage_main" "$BIN_MAIN"; then
    err "替换主命令失败，保留现有命令。"
    return 1
  fi
  if ! mv -f -- "$stage_short" "$BIN_SHORT"; then
    rollback_update || true
    return 1
  fi
  if ! cmp -s "$BIN_MAIN" "$BIN_SHORT"; then
    err "两个命令内容不一致，开始回滚。"
    rollback_update || true
    return 1
  fi
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
    apk) apk add --no-cache dcron ;;
    pacman) pacman -Sy --noconfirm --needed cronie ;;
    zypper) zypper --non-interactive install cron ;;
    *) err "未识别包管理器，无法安装 cron。"; return 1 ;;
  esac
}

ensure_cron_daemon(){
  cron_daemon_present && return 0
  detect_pkg
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

save_cron_backup(){
  local cron_dir="$1" outvar="$2" backup
  if [ ! -e "$CRON_FILE" ]; then
    printf -v "$outvar" '%s' ""
    return 0
  fi
  backup="$(mktemp "$cron_dir/.mihomo-anytls-self-update.backup.XXXXXX")" || return 1
  if ! cp -p "$CRON_FILE" "$backup"; then
    rm -f -- "$backup"
    return 1
  fi
  printf -v "$outvar" '%s' "$backup"
}
restore_cron_backup(){
  local backup="$1" existed="$2" ok=true
  if [ "$existed" = true ]; then
    [ -n "$backup" ] && mv -f -- "$backup" "$CRON_FILE" || ok=false
  else
    rm -f -- "$CRON_FILE" || ok=false
  fi
  if [ "$ok" = false ]; then
    err "cron 旧配置恢复失败，请立即检查: $CRON_FILE"
    return 1
  fi
  return 0
}
install_cron(){
  local cron_dir="" backup="" old_cron=false
  install_command || return 1
  ensure_cron_daemon || { err "无法安装 cron，未启用每日自动更新。"; return 1; }
  start_enable_cron || { err "无法启动或启用 cron，未启用每日自动更新。"; return 1; }
  cron_daemon_running || { err "cron daemon 未运行，未启用每日自动更新。"; return 1; }

  cron_dir="$(dirname "$CRON_FILE")" || return 1
  if ! mkdir -p "$cron_dir"; then
    err "无法创建 cron 目录，未启用每日自动更新。"
    return 1
  fi
  [ -e "$CRON_FILE" ] && old_cron=true
  if ! save_cron_backup "$cron_dir" backup; then
    err "无法保存旧 cron 配置，未启用每日自动更新。"
    return 1
  fi
  if ! write_cron; then
    [ -n "$backup" ] && rm -f -- "$backup"
    err "写入 cron 失败，未启用每日自动更新。"
    return 1
  fi
  if ! cron_file_valid || ! cron_daemon_running; then
    restore_cron_backup "$backup" "$old_cron" || true
    backup=""
    err "cron 配置验证失败，已恢复旧配置，未启用每日自动更新。"
    return 1
  fi
  [ -n "$backup" ] && rm -f -- "$backup"
  info "已启用每日自动更新: $CRON_FILE"
}

remove_cron(){
  rm -f -- "$CRON_FILE"
  info "已关闭每日自动更新。"
}

next_schedule(){
  [ -f "$CRON_FILE" ] || { printf '未设置\n'; return 0; }
  awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { printf "每天 %02d:%02d\n", $2, $1; found=1; exit } END { if (!found) print "未知" }' "$CRON_FILE"
}

status(){
  local main_ok=false short_ok=false cron_exists=false cron_ok=false daemon_ok=false
  echo "主命令: $BIN_MAIN"
  if [ -x "$BIN_MAIN" ]; then main_ok=true; echo "  已安装"; else echo "  未安装"; fi
  echo "快捷命令: $BIN_SHORT"
  if [ -x "$BIN_SHORT" ]; then short_ok=true; echo "  已安装"; else echo "  未安装"; fi
  echo "当前脚本版本: $SCRIPT_VERSION"
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
  if [ "$cron_exists" = true ] && [ "$cron_ok" = false ]; then
    echo "状态: cron 配置无效"
  elif [ "$main_ok" = false ] && [ "$short_ok" = false ]; then
    echo "状态: 未安装"
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
