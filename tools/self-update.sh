#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
INSTALL_URL="$BASE_URL/install.sh"
BIN_MAIN="/usr/local/bin/mihomo-anytls"
BIN_SHORT="/usr/local/bin/en-mi"
CRON_FILE="/etc/cron.d/mihomo-anytls-self-update"

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERR ] %s\n' "$*" >&2; }
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
    die "缺少 curl/wget。"
  fi
}

install_command(){
  local tmp
  tmp="$(mktemp /tmp/mihomo-anytls-update.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  download_install "$tmp"
  install -m 755 "$tmp" "$BIN_MAIN"
  install -m 755 "$tmp" "$BIN_SHORT"
  info "已安装/更新主命令: $BIN_MAIN"
  info "已安装/更新快捷命令: $BIN_SHORT"
  info "以后可直接运行: en-mi"
}

install_cron(){
  install_command
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * * root bash -c 'tmp=\$(mktemp /tmp/mihomo-anytls.XXXXXX) && curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "${INSTALL_URL}?t=\$(date +\%s)" -o "\$tmp" && install -m 755 "\$tmp" "$BIN_MAIN" && install -m 755 "\$tmp" "$BIN_SHORT" && rm -f "\$tmp"'
EOF
  chmod 644 "$CRON_FILE"
  info "已启用每日自动更新: $CRON_FILE"
}

remove_cron(){
  rm -f "$CRON_FILE"
  info "已关闭每日自动更新。"
}

status(){
  echo "主命令: $BIN_MAIN"
  [ -x "$BIN_MAIN" ] && echo "  OK" || echo "  未安装"
  echo "快捷命令: $BIN_SHORT"
  [ -x "$BIN_SHORT" ] && echo "  OK" || echo "  未安装"
  echo "计划任务: $CRON_FILE"
  [ -f "$CRON_FILE" ] && cat "$CRON_FILE" || echo "  未启用"
}

menu(){
  echo "============================================================"
  echo " mihomo-anytls 自动更新"
  echo " 作者: Eianun"
  echo "============================================================"
  echo "  1) 安装/更新本机命令 mihomo-anytls + en-mi"
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
    install|update) install_command ;;
    cron|enable) install_cron ;;
    disable) remove_cron ;;
    status) status ;;
    "") menu ;;
    *) menu ;;
  esac
}

main "$@"
