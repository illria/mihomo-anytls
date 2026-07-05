#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="2026-07-06-cert-center-menu-v1"
BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
MAIN_URL="$BASE_URL/mihomo-anytls-install.sh"
SHOW_URL="$BASE_URL/tools/show-node-info.sh"
NGINX_URL="$BASE_URL/tools/install-nginx-static-site.sh"
CERT_AUTO_URL="$BASE_URL/tools/cert-auto-use.sh"
CERT_CENTER_URL="$BASE_URL/tools/cert-center.sh"
CERT_POOL_URL="$BASE_URL/tools/cert-pool.sh"
OUTBOUND_URL="$BASE_URL/tools/configure-outbound-proxy.sh"
SELF_UPDATE_URL="$BASE_URL/tools/self-update.sh"
UNINSTALL_URL="$BASE_URL/tools/uninstall.sh"
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
    systemctl enable --now cronie >/dev/null 2>&1 || systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
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

ensure_python3(){
  has python3 && return 0
  detect_pkg
  echo "[INFO] 未检测到 python3，预安装 python3 以修补安装器。"
  case "$PKG_MANAGER" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 ;;
    dnf) dnf install -y python3 ;;
    yum) yum install -y python3 ;;
    apk) apk add --no-cache python3 ;;
    pacman) pacman -Sy --noconfirm --needed python ;;
    zypper) zypper --non-interactive install python3 ;;
    opkg) opkg update || true; opkg install python3 || true ;;
    *) echo "[WARN] 未识别包管理器，跳过 python3 预安装。" >&2 ;;
  esac
}

make_tmp(){
  local f
  if has mktemp; then f="$(mktemp /tmp/mihomo-anytls.XXXXXX.sh)"; else f="/tmp/mihomo-anytls.$$.$RANDOM.sh"; fi
  TMP_FILES="$TMP_FILES $f"
  printf '%s' "$f"
}

download_file(){
  local url="$1" out="$2" sep="?" busted=""
  case "$url" in *\?*) sep="&";; esac
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

patch_main_installer(){
  local f="$1"
  [ -f "$f" ] || return 0
  ensure_python3 || true

  python3 - "$f" <<'PY'
import re
import sys
p = sys.argv[1]
s = open(p, 'r', encoding='utf-8').read()

collect_inputs = r'''collect_inputs(){
  if [ "${CERT_MODE:-}" = "5" ]; then
    info "已选择本地证书扫描，先跳过域名输入，稍后从证书自动识别。"
  else
    ask DOMAIN "请输入域名，例如 anytls.example.com"
  fi
  while true; do ask PORT "请输入监听端口" 443; valid_port "$PORT" && break; warn "端口必须是 1-65535"; done
  ask USER_NAME "请输入用户标识" user1
  ask_secret PASSWORD "请输入密码" "$(rand_secret)"
  if [ "$PROTOCOL" = tuic ]; then ask UUID_VALUE "请输入 TUIC UUID" "$(make_uuid)"; fi
}
'''
s = re.sub(r'collect_inputs\(\)\{.*?\n\}', collect_inputs, s, flags=re.S)

cert_funcs = r'''choose_cert_mode(){
  echo
  echo "请选择证书方式："
  echo "  1) 自签证书"
  echo "  2) 自定义证书路径"
  echo "  3) 80 端口申请 Let's Encrypt"
  echo "  4) Cloudflare DNS 验证证书"
  echo "  5) 先扫描本机证书，自动识别域名并使用/续期/同步"
  read -r -p "输入序号 [5]: " CERT_MODE
  CERT_MODE=${CERT_MODE:-5}
}

choose_cert(){
  local out selected_domain
  [ -n "${CERT_MODE:-}" ] || choose_cert_mode
  case "$CERT_MODE" in
    1)
      [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"
      self_cert
      ;;
    2)
      [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"
      custom_cert
      ;;
    3)
      [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"
      issue_80
      ;;
    4)
      [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"
      issue_cf
      ;;
    5)
      out="$(mktemp /tmp/mihomo-anytls-cert-select.XXXXXX.env)"
      if curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "https://raw.githubusercontent.com/illria/mihomo-anytls/main/tools/cert-auto-use.sh?t=$(date +%s)" | bash -s -- "" "$CERT_FILE" "$KEY_FILE" 15 "$out"; then
        if [ -f "$out" ]; then
          . "$out"
          selected_domain="${SELECTED_DOMAIN:-}"
          [ -n "$selected_domain" ] && DOMAIN="$selected_domain"
        fi
        rm -f "$out"
        [ -n "$DOMAIN" ] || die "已选择证书，但没有识别到域名。"
        SKIP_CERT_VERIFY=false
      else
        rm -f "$out"
        die "本机未找到可用证书。请重新运行后选择 3) 80端口申请 或 4) Cloudflare DNS 验证。"
      fi
      ;;
    *) die "无效证书方式" ;;
  esac
}
'''
s = re.sub(r'choose_cert\(\)\{.*?\n\}', cert_funcs, s, flags=re.S)

helper = r'''share_insecure_flag(){ [ "$SKIP_CERT_VERIFY" = true ] && echo 1 || echo 0; }

build_share_link(){
  local insecure tag
  insecure="$(share_insecure_flag)"
  tag="$DOMAIN-$PORT"
  case "$PROTOCOL" in
    anytls) printf 'anytls://%s@%s:%s?peer=%s&insecure=%s&sni=%s#%s\n' "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$DOMAIN" "$tag" ;;
    hysteria2) printf 'hysteria2://%s@%s:%s?sni=%s&insecure=%s#%s\n' "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$tag" ;;
    tuic) printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&sni=%s&allow_insecure=%s#%s\n' "$UUID_VALUE" "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$tag" ;;
    trojan) printf 'trojan://%s@%s:%s?sni=%s&allowInsecure=%s#%s\n' "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$tag" ;;
    *) printf '暂不支持该协议分享链接: %s\n' "$PROTOCOL" ;;
  esac
}

install_cert_renew_cron(){
  local cron log
  cron="/etc/cron.d/mihomo-anytls-cert-renew"
  log="/var/log/mihomo-anytls-cert-renew.log"
  mkdir -p /etc/cron.d /var/log
  cat > "$cron" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
23 3 * * * root curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 'https://raw.githubusercontent.com/illria/mihomo-anytls/main/tools/cert-auto-use.sh?t='\$(date +\%s) | bash -s -- '$DOMAIN' '$CERT_FILE' '$KEY_FILE' 15 >> '$log' 2>&1
EOF
  chmod 644 "$cron"
  info "已安装证书自动续期计划: $cron"
  info "每天 03:23 检测证书；剩余 <=15 天按来源续期并同步。"
}

summary(){
  echo; info "安装完成"; echo "------------------------------------------------------------"
  echo "内核: $CORE"; [ "$CORE" = sing-box ] && echo "sing-box 版本: $SINGBOX_VERSION"
  echo "协议: $PROTOCOL"; echo "模式: $INSTALL_MODE"; echo "域名: $DOMAIN"; echo "端口: $PORT/$NEED_PROTO"; echo "用户: $USER_NAME"; [ -n "$UUID_VALUE" ] && echo "UUID: $UUID_VALUE"; echo "密码: $PASSWORD"
  echo "分享链接: $(build_share_link)"
  echo "服务端配置: $CONFIG_FILE"; echo "mihomo 客户端示例: $CLIENT_MIHOMO_FILE"; echo "sing-box 客户端示例: $CLIENT_SINGBOX_FILE"; echo "证书: $CERT_FILE"; echo "私钥: $KEY_FILE"
  echo "证书自动续期: /etc/cron.d/mihomo-anytls-cert-renew"
  echo "------------------------------------------------------------"
  [ "$INSTALL_MODE" = docker ] && echo "日志: docker logs -f $CONTAINER_NAME" || echo "日志: journalctl -u ${CORE/mihomo/mihomo} -f"
  warn "Cloudflare DNS 记录建议关闭橙色云朵，使用 DNS only。"
}
'''
s = re.sub(r'\nsummary\(\)\{.*?\n\}\n\nmain\(\)\{', '\n' + helper + '\n\nmain(){', s, flags=re.S)
s = s.replace('choose_core; choose_install; choose_singbox_version; choose_protocol; prepare_paths; collect_inputs; choose_cert; write_config', 'choose_core; choose_install; choose_singbox_version; choose_protocol; prepare_paths; choose_cert_mode; collect_inputs; choose_cert; write_config')
s = s.replace('firewall_hint; summary', 'firewall_hint; install_cert_renew_cron; summary')
open(p, 'w', encoding='utf-8').write(s)
PY
}

run_remote_script(){
  local url="$1" f
  shift || true
  f="$(make_tmp)"
  download_file "$url" "$f"
  if [ "$url" = "$MAIN_URL" ]; then patch_main_installer "$f"; fi
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then bash "$f" "$@" < /dev/tty; else bash "$f" "$@"; fi
}

install_or_update_node(){ ensure_crontab || true; run_remote_script "$MAIN_URL"; }
show_nodes(){ run_remote_script "$SHOW_URL"; }
install_nginx_site(){ run_remote_script "$NGINX_URL"; }
certificate_center(){ run_remote_script "$CERT_CENTER_URL"; }

repair_local_cert(){
  local domain core target_cert target_key
  read -r -p "请输入域名，可留空自动扫描本机证书: " domain
  read -r -p "同步到哪个内核 [mihomo/sing-box] [mihomo]: " core
  core="${core:-mihomo}"
  case "$core" in
    mihomo) target_cert="/etc/mihomo/certs/fullchain.pem"; target_key="/etc/mihomo/certs/key.pem" ;;
    sing-box|singbox) target_cert="/etc/sing-box/certs/fullchain.pem"; target_key="/etc/sing-box/certs/key.pem" ;;
    *) echo "未知内核：$core" >&2; return 1 ;;
  esac
  run_remote_script "$CERT_AUTO_URL" "$domain" "$target_cert" "$target_key"
}

manage_cert_pool(){ run_remote_script "$CERT_POOL_URL"; }
configure_outbound(){ run_remote_script "$OUTBOUND_URL"; }
manage_self_update(){ run_remote_script "$SELF_UPDATE_URL"; }
uninstall_tool(){ run_remote_script "$UNINSTALL_URL"; }

service_status(){
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
  echo "证书自动续期："
  [ -f /etc/cron.d/mihomo-anytls-cert-renew ] && cat /etc/cron.d/mihomo-anytls-cert-renew || echo "  未安装"
  echo
  echo "端口监听："
  if has ss; then ss -lntup 2>/dev/null | grep -E '(:80|:443|:7890|:9090)\b' || echo "  未发现 80/443/7890/9090 监听"; fi
}

restart_services(){
  if has docker; then
    docker restart mihomo-anytls >/dev/null 2>&1 && echo "已重启 Docker: mihomo-anytls" || true
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^sing-box' || true); do docker restart "$c" >/dev/null 2>&1 && echo "已重启 Docker: $c" || true; done
  fi
  if has systemctl; then
    systemctl restart mihomo >/dev/null 2>&1 && echo "已重启 systemd: mihomo" || true
    systemctl restart sing-box >/dev/null 2>&1 && echo "已重启 systemd: sing-box" || true
    systemctl restart nginx >/dev/null 2>&1 && echo "已重启 systemd: nginx" || true
  fi
}

menu(){
  local action
  echo "============================================================"
  echo " mihomo-anytls 统一管理菜单"
  echo " 版本: $INSTALLER_VERSION"
  echo "============================================================"
  echo "请选择操作："
  echo "  1) 安装 / 更新节点"
  echo "  2) 查看本机已安装节点信息"
  echo "  3) 安装 / 更新 Nginx 静态站"
  echo "  4) 查看服务状态"
  echo "  5) 重启服务"
  echo "  6) 证书中心（状态清单 / 强制续期 / 同步）"
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
    6) certificate_center ;;
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
  case "${1:-}" in
    --install|install|node) install_or_update_node ;;
    --show|show|list) show_nodes ;;
    --nginx|nginx|site) install_nginx_site ;;
    --cert|cert|certificate|cert-center) certificate_center ;;
    --repair-cert|repair-cert) repair_local_cert ;;
    --cert-pool|cert-pool|pool) manage_cert_pool ;;
    --outbound|outbound|proxy) configure_outbound ;;
    --self-update|self-update|update-self) manage_self_update ;;
    --uninstall|uninstall|remove) uninstall_tool ;;
    --status|status) service_status ;;
    --restart|restart) restart_services ;;
    "") menu ;;
    *) echo "未知参数：$1" >&2; menu ;;
  esac
}

main "$@"
