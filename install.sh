#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="2026-08-02-eianun-en-mi-v5"
AUTHOR="Eianun"
BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
MAIN_URL="$BASE_URL/mihomo-anytls-install.sh"
SHOW_URL="$BASE_URL/tools/show-node-info.sh"
NGINX_URL="$BASE_URL/tools/install-nginx-static-site.sh"
CERT_AUTO_URL="$BASE_URL/tools/cert-auto-use.sh"
SSL_MANAGER_URL="$BASE_URL/tools/ssl-manager.sh"
CERT_POOL_URL="$BASE_URL/tools/cert-pool.sh"
OUTBOUND_URL="$BASE_URL/tools/configure-outbound-proxy.sh"
SELF_UPDATE_URL="$BASE_URL/tools/self-update.sh"
UNINSTALL_URL="$BASE_URL/tools/uninstall.sh"
BIN_MAIN="/usr/local/bin/mihomo-anytls"
BIN_SHORT="/usr/local/bin/en-mi"
TMP_FILES=""
PKG_MANAGER="unknown"

cleanup(){
  local f
  for f in $TMP_FILES; do
    [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
  done
}
trap cleanup EXIT

has(){ command -v "$1" >/dev/null 2>&1; }

need_root(){
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请使用 root 运行，例如：sudo bash <(curl -fsSL $BASE_URL/install.sh)" >&2
    exit 1
  fi
}

detect_pkg(){
  if has apt-get; then PKG_MANAGER=apt
  elif has dnf; then PKG_MANAGER=dnf
  elif has yum; then PKG_MANAGER=yum
  elif has apk; then PKG_MANAGER=apk
  elif has pacman; then PKG_MANAGER=pacman
  elif has zypper; then PKG_MANAGER=zypper
  elif has opkg; then PKG_MANAGER=opkg
  else PKG_MANAGER=unknown
  fi
}

start_cron(){
  if has systemctl && [ -d /run/systemd/system ]; then
    systemctl enable --now cronie >/dev/null 2>&1 || \
      systemctl enable --now cron >/dev/null 2>&1 || \
      systemctl enable --now crond >/dev/null 2>&1 || true
  elif has rc-service; then
    rc-update add crond default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
  else
    [ -x /etc/init.d/cron ] && /etc/init.d/cron start >/dev/null 2>&1 || true
    [ -x /etc/init.d/crond ] && /etc/init.d/crond start >/dev/null 2>&1 || true
  fi
}

ensure_crontab(){
  has crontab && { start_cron; return 0; }
  detect_pkg
  echo "[INFO] 未检测到 crontab，预安装 cron/cronie。"
  case "$PKG_MANAGER" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y cron ;;
    dnf) dnf install -y cronie ;;
    yum) yum install -y cronie ;;
    apk) apk add --no-cache dcron ;;
    pacman) pacman -Sy --noconfirm --needed cronie ;;
    zypper) zypper --non-interactive install cron ;;
    opkg) opkg update || true; opkg install cron || true ;;
    *) echo "[WARN] 未识别包管理器，跳过 crontab 预安装。" >&2 ;;
  esac
  start_cron
}

make_tmp(){
  local f
  if has mktemp; then
    f="$(mktemp /tmp/mihomo-anytls.XXXXXX.sh)"
  else
    f="/tmp/mihomo-anytls.$$.$RANDOM.sh"
  fi
  TMP_FILES="$TMP_FILES $f"
  printf '%s' "$f"
}

download_file(){
  local url="$1" out="$2" sep="?" busted
  case "$url" in *\?*) sep="&" ;; esac
  busted="${url}${sep}t=$(date +%s)"
  if has curl; then
    curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$busted" -o "$out"
  elif has wget; then
    wget --no-cache -qO "$out" "$busted"
  else
    echo "缺少 curl/wget，请先安装其中一个。" >&2
    exit 1
  fi
  chmod +x "$out"
}

install_shortcuts(){
  local tmp
  [ -w /usr/local/bin ] || return 0
  tmp="$(make_tmp)"
  if download_file "$BASE_URL/install.sh" "$tmp" >/dev/null 2>&1; then
    install -m 755 "$tmp" "$BIN_MAIN" 2>/dev/null || true
    install -m 755 "$tmp" "$BIN_SHORT" 2>/dev/null || true
  fi
}

run_remote_script(){
  local url="$1" f
  shift || true
  f="$(make_tmp)"
  download_file "$url" "$f"
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    bash "$f" "$@" < /dev/tty
  else
    bash "$f" "$@"
  fi
}

install_or_update_node(){ ensure_crontab || true; run_remote_script "$MAIN_URL"; }
show_nodes(){ run_remote_script "$SHOW_URL"; }
install_nginx_site(){ run_remote_script "$NGINX_URL"; }
ssl_manager(){ run_remote_script "$SSL_MANAGER_URL" "$@"; }
manage_cert_pool(){ run_remote_script "$CERT_POOL_URL"; }
configure_outbound(){ run_remote_script "$OUTBOUND_URL"; }
manage_self_update(){ run_remote_script "$SELF_UPDATE_URL"; }
run_self_update_once(){ run_remote_script "$SELF_UPDATE_URL" run-update; }
uninstall_tool(){ run_remote_script "$UNINSTALL_URL"; }

repair_local_cert(){
  local domain core target_cert target_key
  read -r -p "请输入域名，可留空自动扫描本机证书: " domain
  read -r -p "同步到哪个内核 [mihomo/sing-box] [mihomo]: " core
  core="${core:-mihomo}"
  case "$core" in
    mihomo)
      target_cert="/etc/mihomo/certs/fullchain.pem"
      target_key="/etc/mihomo/certs/key.pem"
      ;;
    sing-box|singbox)
      target_cert="/etc/sing-box/certs/fullchain.pem"
      target_key="/etc/sing-box/certs/key.pem"
      ;;
    *)
      echo "未知内核：$core" >&2
      return 1
      ;;
  esac
  run_remote_script "$CERT_AUTO_URL" "$domain" "$target_cert" "$target_key"
}

env_value(){
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$file" | head -n1
}

show_env_port(){
  local env="$1" port core mode
  [ -f "$env" ] || return 1
  port="$(env_value "$env" PORT || true)"
  core="$(env_value "$env" CORE || true)"
  mode="$(env_value "$env" INSTALL_MODE || true)"
  [ -n "$port" ] || return 1
  printf '  %s (%s): %s\n' "${core:-unknown}" "${mode:-unknown}" "$port"
  if has ss; then
    ss -lntup 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" || echo "    未发现端口监听"
  fi
}

service_status(){
  echo "============================================================"
  echo " 服务状态"
  echo "============================================================"
  if has docker; then
    echo "Docker 容器："
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | \
      grep -E 'NAMES|mihomo-anytls|sing-box-|sing-box' || \
      echo "  未发现 mihomo-anytls / sing-box 相关容器"
  else
    echo "Docker: 未安装或不可用"
  fi
  echo
  echo "证书自动续期："
  [ -f /etc/cron.d/mihomo-anytls-cert-renew ] && \
    cat /etc/cron.d/mihomo-anytls-cert-renew || echo "  未安装"
  echo
  echo "配置端口与监听："
  local shown=0
  show_env_port /etc/mihomo/install.env && shown=1 || true
  show_env_port /etc/sing-box/install.env && shown=1 || true
  [ "$shown" -eq 1 ] || echo "  未发现 install.env"
}

restart_one_from_env(){
  local env="$1" core mode protocol container service
  [ -f "$env" ] || return 1
  core="$(env_value "$env" CORE || true)"
  mode="$(env_value "$env" INSTALL_MODE || true)"
  protocol="$(env_value "$env" PROTOCOL || true)"
  case "$core" in
    mihomo)
      container="mihomo-anytls"
      service="mihomo"
      ;;
    sing-box)
      container="sing-box-${protocol:-anytls}"
      service="sing-box"
      ;;
    *) return 1 ;;
  esac
  if [ "$mode" = docker ]; then
    if has docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container"; then
      docker restart "$container" >/dev/null 2>&1
      echo "已重启 Docker: $container"
      return 0
    fi
  elif [ "$mode" = systemd ]; then
    if has systemctl && systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${service}\.service"; then
      systemctl restart "$service" >/dev/null 2>&1
      echo "已重启 systemd: $service"
      return 0
    fi
  fi
  return 1
}

restart_services(){
  local did=0 c
  restart_one_from_env /etc/mihomo/install.env && did=1 || true
  restart_one_from_env /etc/sing-box/install.env && did=1 || true
  if [ "$did" -eq 0 ] && has docker; then
    for c in mihomo-anytls $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^sing-box' || true); do
      docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$c" || continue
      docker restart "$c" >/dev/null 2>&1 && echo "已重启 Docker: $c" || true
    done
  fi
  [ "$did" -eq 1 ] || echo "未发现可重启的已安装服务。"
}

menu(){
  local action
  echo "============================================================"
  echo " mihomo-anytls 统一管理菜单"
  echo " 作者: $AUTHOR"
  echo " 快捷命令: en-mi"
  echo " 版本: $INSTALLER_VERSION"
  echo "============================================================"
  echo "请选择操作："
  echo "  1) 安装 / 更新节点"
  echo "  2) 查看本机已安装节点信息"
  echo "  3) 安装 / 更新 Nginx 静态站"
  echo "  4) 查看服务状态"
  echo "  5) 重启服务"
  echo "  6) SSL Manager（证书申请 / 安装 / 续期 / 同步）"
  echo "  7) 多节点证书池管理"
  echo "  8) 配置 HTTP / SOCKS5 出口代理"
  echo "  9) 自动更新脚本管理"
  echo " 10) 卸载 mihomo-anytls"
  echo "  0) 退出"
  read -r -p "输入序号 [1]: " action
  action="${action:-1}"
  case "$action" in
    1) install_or_update_node ;;
    2) show_nodes ;;
    3) install_nginx_site ;;
    4) service_status ;;
    5) restart_services ;;
    6) ssl_manager ;;
    7) manage_cert_pool ;;
    8) configure_outbound ;;
    9) manage_self_update ;;
    10) uninstall_tool ;;
    0) exit 0 ;;
    *) echo "无效操作：$action" >&2; exit 1 ;;
  esac
}

main(){
  need_root
  install_shortcuts || true
  case "${1:-}" in
    --install|install|node) install_or_update_node ;;
    --show|show|list) show_nodes ;;
    --nginx|nginx|site) install_nginx_site ;;
    --ssl|ssl|ssl-manager|--cert|cert|certificate|cert-center) ssl_manager ;;
    --repair-cert|repair-cert) repair_local_cert ;;
    --cert-pool|cert-pool|pool) manage_cert_pool ;;
    --outbound|outbound|proxy) configure_outbound ;;
    --self-update|self-update|update-self) manage_self_update ;;
    --self-update-run|self-update-run) run_self_update_once ;;
    --uninstall|uninstall|remove) uninstall_tool ;;
    --status|status) service_status ;;
    --restart|restart) restart_services ;;
    "") menu ;;
    *) echo "未知参数：$1" >&2; menu ;;
  esac
}

main "$@"
