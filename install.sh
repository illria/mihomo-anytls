#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
MAIN_URL="$BASE_URL/mihomo-anytls-install.sh"
SHOW_URL="$BASE_URL/tools/show-node-info.sh"
NGINX_URL="$BASE_URL/tools/install-nginx-static-site.sh"
CERT_URL="$BASE_URL/tools/cert-finder.sh"
OUTBOUND_URL="$BASE_URL/tools/configure-outbound-proxy.sh"
TMP_FILES=""
PKG_MANAGER="unknown"

cleanup() {
  local f
  for f in $TMP_FILES; do
    [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
  done
}
trap cleanup EXIT

has() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请使用 root 运行，例如：sudo bash <(curl -fsSL $BASE_URL/install.sh)" >&2
    exit 1
  fi
}

detect_pkg() {
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

start_cron() {
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

ensure_crontab() {
  has crontab && { start_cron; return 0; }
  detect_pkg
  echo "[INFO] 未检测到 crontab，预安装 cron/cronie 以兼容 acme.sh 自动续期检查。"
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

make_tmp() {
  local f
  if has mktemp; then
    f="$(mktemp /tmp/mihomo-anytls.XXXXXX.sh)"
  else
    f="/tmp/mihomo-anytls.$$.$RANDOM.sh"
  fi
  TMP_FILES="$TMP_FILES $f"
  printf '%s' "$f"
}

download_file() {
  local url="$1" out="$2"
  if has curl; then
    curl -fsSL "$url" -o "$out"
  elif has wget; then
    wget -qO "$out" "$url"
  else
    echo "缺少 curl/wget，请先安装其中一个。" >&2
    exit 1
  fi
  chmod +x "$out"
}

run_remote_script() {
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

install_or_update_node() {
  ensure_crontab || true
  run_remote_script "$MAIN_URL"
}

show_nodes() {
  run_remote_script "$SHOW_URL"
}

install_nginx_site() {
  run_remote_script "$NGINX_URL"
}

find_local_cert() {
  run_remote_script "$CERT_URL"
}

configure_outbound() {
  run_remote_script "$OUTBOUND_URL"
}

service_status() {
  echo "============================================================"
  echo " 服务状态"
  echo "============================================================"

  if has docker; then
    echo "Docker 容器："
    docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -E 'NAMES|mihomo-anytls|sing-box-|sing-box' || echo "  未发现 mihomo-anytls / sing-box 相关容器"
  else
    echo "Docker: 未安装或不可用"
  fi

  echo
  echo "systemd 服务："
  if has systemctl; then
    for s in mihomo sing-box nginx; do
      if systemctl list-unit-files "$s.service" >/dev/null 2>&1; then
        printf '  %-10s ' "$s"
        systemctl is-active "$s" 2>/dev/null || true
      fi
    done
  else
    echo "  systemctl 不可用"
  fi

  echo
  echo "端口监听："
  if has ss; then
    ss -lntup 2>/dev/null | grep -E '(:80|:443|:7890|:9090)\b' || echo "  未发现 80/443/7890/9090 监听"
  elif has netstat; then
    netstat -lntup 2>/dev/null | grep -E '(:80|:443|:7890|:9090)\b' || echo "  未发现 80/443/7890/9090 监听"
  else
    echo "  ss/netstat 不可用"
  fi
}

restart_services() {
  local choice
  echo "请选择重启范围："
  echo "  1) 重启节点服务"
  echo "  2) 重启 Nginx 静态站"
  echo "  3) 全部重启"
  echo "  0) 返回"
  read -r -p "输入序号 [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1|3)
      if has docker; then
        docker restart mihomo-anytls >/dev/null 2>&1 && echo "已重启 Docker: mihomo-anytls" || true
        for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^sing-box' || true); do
          docker restart "$c" >/dev/null 2>&1 && echo "已重启 Docker: $c" || true
        done
      fi
      if has systemctl; then
        systemctl restart mihomo >/dev/null 2>&1 && echo "已重启 systemd: mihomo" || true
        systemctl restart sing-box >/dev/null 2>&1 && echo "已重启 systemd: sing-box" || true
      fi
      ;;&
    2|3)
      if has systemctl; then
        systemctl restart nginx >/dev/null 2>&1 && echo "已重启 systemd: nginx" || true
      elif has rc-service; then
        rc-service nginx restart >/dev/null 2>&1 && echo "已重启 OpenRC: nginx" || true
      elif [ -x /etc/init.d/nginx ]; then
        /etc/init.d/nginx restart >/dev/null 2>&1 && echo "已重启 init.d: nginx" || true
      elif has nginx; then
        nginx -s reload >/dev/null 2>&1 && echo "已 reload nginx" || true
      fi
      ;;
    0) return 0 ;;
    *) echo "无效操作：$choice" >&2; return 1 ;;
  esac
}

menu() {
  local action
  echo "============================================================"
  echo " mihomo-anytls 管理菜单"
  echo "============================================================"
  echo "请选择操作："
  echo "  1) 安装 / 更新节点"
  echo "  2) 查看本机已安装节点信息"
  echo "  3) 安装 / 更新 Nginx 静态站"
  echo "  4) 查看服务状态"
  echo "  5) 重启服务"
  echo "  6) 检测本地证书有效期"
  echo "  7) 配置 HTTP / SOCKS5 出口代理"
  echo "  0) 退出"
  read -r -p "输入序号 [1]: " action
  action="${action:-1}"

  case "$action" in
    1) install_or_update_node ;;
    2) show_nodes ;;
    3) install_nginx_site ;;
    4) service_status ;;
    5) restart_services ;;
    6) find_local_cert ;;
    7) configure_outbound ;;
    0) exit 0 ;;
    *) echo "无效操作：$action" >&2; exit 1 ;;
  esac
}

main() {
  need_root
  case "${1:-}" in
    --install|install|node) install_or_update_node ;;
    --show|show|list) show_nodes ;;
    --nginx|nginx|site) install_nginx_site ;;
    --cert|cert|certificate) find_local_cert ;;
    --outbound|outbound|proxy) configure_outbound ;;
    --status|status) service_status ;;
    --restart|restart) restart_services ;;
    "") menu ;;
    *) echo "未知参数：$1" >&2; menu ;;
  esac
}

main "$@"
