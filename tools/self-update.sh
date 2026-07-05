#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
INSTALL_URL="$BASE_URL/install.sh"
BIN_PATH="/usr/local/bin/mihomo-anytls"
CRON_FILE="/etc/cron.d/mihomo-anytls-self-update"

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行。"; }

download(){
  local url="$1" out="$2" busted
  busted="${url}?t=$(date +%s)"
  if has curl; then
    curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$busted" -o "$out"
  elif has wget; then
    wget --no-cache -qO "$out" "$busted"
  else
    die "缺少 curl/wget。"
  fi
}

install_command(){
  tmp="$(mktemp /tmp/mihomo-anytls-update.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  download "$INSTALL_URL" "$tmp"
  install -m 755 "$tmp" "$BIN_PATH"
  info "已安装/更新本机命令: $BIN_PATH"
  echo "使用方式：mihomo-anytls"
}

install_cron(){
  install_command
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * * root curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "${INSTALL_URL}?t=\$(date +\%s)" -o ${BIN_PATH}.tmp && install -m 755 ${BIN_PATH}.tmp ${BIN_PATH} && rm -f ${BIN_PATH}.tmp
EOF
  chmod 644 "$CRON_FILE"
  info "已写入自动更新计划: $CRON_FILE"
  info "默认每天 04:17 自动更新入口脚本。"
}

remove_cron(){
  rm -f "$CRON_FILE"
  info "已删除自动更新计划: $CRON_FILE"
}

status(){
  echo "命令路径: $BIN_PATH"
  [ -x "$BIN_PATH" ] && "$BIN_PATH" --status >/dev/null 2>&1 && echo "命令状态: 可执行" || echo "命令状态: 未安装或不可执行"
  echo "计划任务: $CRON_FILE"
  [ -f "$CRON_FILE" ] && cat "$CRON_FILE" || echo "未启用自动更新计划"
}

menu(){
  echo "============================================================"
  echo " mihomo-anytls 自动更新"
  echo "============================================================"
  echo "  1) 安装/更新本机命令"
  echo "  2) 启用每日自动更新"
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

main(){
  need_root
  case "${1:-}" in
    install|update|"") [ "${1:-}" = "" ] && menu || install_command ;;
    cron|enable) install_cron ;;
    disable) remove_cron ;;
    status) status ;;
    *) menu ;;
  esac
}

main "$@"
