#!/usr/bin/env bash
set -Eeuo pipefail

CERT_ROOT="/root/cert"
ACME="/root/.acme.sh/acme.sh"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

info(){ printf "${green}[INFO]${plain} %s\n" "$*"; }
warn(){ printf "${yellow}[WARN]${plain} %s\n" "$*" >&2; }
err(){ printf "${red}[ERR ]${plain} %s\n" "$*" >&2; }
has(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { err "请用 root 运行。"; exit 1; }; }
is_domain(){ [[ "${1:-}" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]]; }

pause_back(){
  echo
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    read -r -p "按回车返回 SSL Manager 菜单..." _ < /dev/tty || true
  fi
}

install_acme(){
  if [ -x "$ACME" ]; then
    info "acme.sh 已安装: $ACME"
    return 0
  fi
  info "安装 acme.sh..."
  cd /root || return 1
  curl -s https://get.acme.sh | sh
  [ -x "$ACME" ] || { err "acme.sh 安装失败。"; return 1; }
}

acme_listen_flag(){
  if ip -4 addr show scope global 2>/dev/null | grep -q 'inet '; then
    echo ""
  else
    echo "--listen-v6"
  fi
}

cert_ok(){ [ -s "$1" ] && openssl x509 -in "$1" -noout >/dev/null 2>&1; }
key_ok(){ [ -s "$1" ] && openssl pkey -in "$1" -noout >/dev/null 2>&1; }

pair_ok(){
  local cert="$1" key="$2" cf kf
  cert_ok "$cert" || { err "证书文件不是有效 PEM: $cert"; return 1; }
  key_ok "$key" || { err "key 文件不是 PRIVATE KEY: $key"; err "常见错误：把 ca.cer/fullchain.cer 当成 key。"; return 1; }
  cf="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')"
  kf="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')"
  [ -n "$cf" ] && [ -n "$kf" ] && [ "$cf" = "$kf" ] || { err "证书和私钥不匹配。"; return 1; }
}

cert_days(){
  local cert="$1" end epoch now
  cert_ok "$cert" || { echo "invalid"; return; }
  end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch-now)/86400 ))
}

cert_domains(){
  local cert="$1" text cn sans
  cert_ok "$cert" || return 0
  text="$(openssl x509 -in "$cert" -noout -subject -ext subjectAltName 2>/dev/null || true)"
  sans="$(printf '%s\n' "$text" | grep -oE 'DNS:[A-Za-z0-9*._-]+' | sed 's/^DNS://' | tr '\n' ' ')"
  cn="$(printf '%s\n' "$text" | sed -n 's/.*CN[ =]*\([^,/]*\).*/\1/p' | head -n1)"
  printf '%s %s\n' "$sans" "$cn" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}

cert_dir(){ echo "$CERT_ROOT/$1"; }
cert_file(){ echo "$(cert_dir "$1")/fullchain.pem"; }
key_file(){ echo "$(cert_dir "$1")/privkey.pem"; }

detect_acme_mode(){
  local domain="$1"
  if [ -d "/root/.acme.sh/${domain}_ecc" ]; then
    echo "ecc"
  elif [ -d "/root/.acme.sh/${domain}" ]; then
    echo "rsa"
  else
    echo "unknown"
  fi
}

reload_cmd_for_domain(){
  local domain="$1"
  cat <<EOF
bash -c 'docker restart mihomo-anytls >/dev/null 2>&1 || true; docker restart sing-box-anytls >/dev/null 2>&1 || true; docker restart sing-box-hysteria2 >/dev/null 2>&1 || true; docker restart sing-box-tuic >/dev/null 2>&1 || true; docker restart sing-box-trojan >/dev/null 2>&1 || true; systemctl restart mihomo >/dev/null 2>&1 || true; systemctl restart sing-box >/dev/null 2>&1 || true'
EOF
}

install_cert_to_root_cert(){
  local domain="$1" mode reload cert key
  [ -n "$domain" ] && is_domain "$domain" || { err "域名无效: $domain"; return 1; }
  install_acme || return 1
  mkdir -p "$(cert_dir "$domain")"
  cert="$(cert_file "$domain")"
  key="$(key_file "$domain")"
  reload="$(reload_cmd_for_domain "$domain")"
  mode="$(detect_acme_mode "$domain")"
  info "按 3x-ui 模型安装证书到: $(cert_dir "$domain")"
  info "fullchain: $cert"
  info "privkey:   $key"
  info "执行 acme.sh install-cert，不再调用交互式 en-mi，避免卡住。"
  if [ "$mode" = "ecc" ]; then
    "$ACME" --install-cert --force --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --reloadcmd "$reload"
  else
    "$ACME" --install-cert --force -d "$domain" --key-file "$key" --fullchain-file "$cert" --reloadcmd "$reload"
  fi
  pair_ok "$cert" "$key" || { err "install-cert 后证书/私钥仍不可用。"; return 1; }
  chmod 644 "$cert"
  chmod 600 "$key"
  info "证书安装并校验成功。"
}

issue_http(){
  local domain email port
  read -r -p "请输入域名: " domain
  is_domain "$domain" || { err "域名无效。"; return 1; }
  read -r -p "请输入 acme.sh 注册邮箱 [admin@${domain}]: " email
  email="${email:-admin@${domain}}"
  read -r -p "HTTP-01 端口 [80]: " port
  port="${port:-80}"
  install_acme || return 1
  "$ACME" --register-account -m "$email" --server letsencrypt --force || true
  "$ACME" --set-default-ca --server letsencrypt --force
  info "开始 HTTP-01 签发: $domain"
  "$ACME" --issue -d "$domain" --standalone --httpport "$port" $(acme_listen_flag) --keylength ec-256 --server letsencrypt --force
  install_cert_to_root_cert "$domain"
}

issue_cf(){
  local domain keytype token email gkey
  read -r -p "请输入根域名，例如 example.com: " domain
  is_domain "$domain" || { err "域名无效。"; return 1; }
  read -r -p "使用 Cloudflare API Token 还是 Global Key? [t/g] [t]: " keytype
  keytype="${keytype:-t}"
  if [[ "$keytype" =~ ^[gG]$ ]]; then
    read -r -p "Cloudflare Global API Key: " gkey
    read -r -p "Cloudflare 账号邮箱: " email
    export CF_Key="$gkey"
    export CF_Email="$email"
  else
    read -r -p "Cloudflare API Token: " token
    export CF_Token="$token"
  fi
  install_acme || return 1
  "$ACME" --set-default-ca --server letsencrypt --force
  info "开始 Cloudflare DNS 签发: $domain 和 *.${domain}"
  "$ACME" --issue --dns dns_cf -d "$domain" -d "*.${domain}" --log --keylength ec-256 --server letsencrypt --force
  install_cert_to_root_cert "$domain"
}

list_certs(){
  local d domain cert key days domains ok
  echo "============================================================"
  echo " SSL Manager - /root/cert 证书列表"
  echo "============================================================"
  mkdir -p "$CERT_ROOT"
  if ! find "$CERT_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
    warn "没有发现 /root/cert/<domain> 证书。"
  fi
  for d in "$CERT_ROOT"/*; do
    [ -d "$d" ] || continue
    domain="$(basename "$d")"
    cert="$d/fullchain.pem"
    key="$d/privkey.pem"
    days="$(cert_days "$cert")"
    domains="$(cert_domains "$cert")"
    if pair_ok "$cert" "$key" >/dev/null 2>&1; then ok="OK"; else ok="BROKEN"; fi
    printf '域名: %-32s 状态: %-8s 剩余天数: %s\n' "$domain" "$ok" "$days"
    echo "  证书: $cert"
    echo "  私钥: $key"
    echo "  覆盖域名: ${domains:-unknown}"
  done
  echo "------------------------------------------------------------"
  echo "acme.sh 记录："
  if [ -x "$ACME" ]; then "$ACME" --list || true; else warn "acme.sh 未安装。"; fi
}

force_renew(){
  local domain mode
  read -r -p "请输入要强制续期的域名: " domain
  is_domain "$domain" || { err "域名无效。"; return 1; }
  install_acme || return 1
  mode="$(detect_acme_mode "$domain")"
  info "强制续期: $domain ($mode)"
  if [ "$mode" = "ecc" ]; then
    "$ACME" --renew -d "$domain" --ecc --force || "$ACME" --issue -d "$domain" --standalone --keylength ec-256 --server letsencrypt --force
  else
    "$ACME" --renew -d "$domain" --force || "$ACME" --issue -d "$domain" --standalone --server letsencrypt --force
  fi
  install_cert_to_root_cert "$domain"
}

revoke_remove(){
  local domain
  read -r -p "请输入要撤销并删除的域名: " domain
  is_domain "$domain" || { err "域名无效。"; return 1; }
  install_acme || true
  "$ACME" --revoke -d "$domain" --ecc 2>/dev/null || "$ACME" --revoke -d "$domain" 2>/dev/null || true
  "$ACME" --remove -d "$domain" --ecc 2>/dev/null || "$ACME" --remove -d "$domain" 2>/dev/null || true
  rm -rf "/root/.acme.sh/${domain}" "/root/.acme.sh/${domain}_ecc" "$(cert_dir "$domain")"
  info "已删除: $domain"
}

sync_runtime(){
  local domain core cert key target_cert target_key
  read -r -p "请输入 /root/cert 下的域名: " domain
  cert="$(cert_file "$domain")"
  key="$(key_file "$domain")"
  pair_ok "$cert" "$key" || return 1
  read -r -p "同步到哪个内核 [mihomo/sing-box] [mihomo]: " core
  core="${core:-mihomo}"
  case "$core" in
    mihomo) target_cert=/etc/mihomo/certs/fullchain.pem; target_key=/etc/mihomo/certs/key.pem ;;
    sing-box|singbox) target_cert=/etc/sing-box/certs/fullchain.pem; target_key=/etc/sing-box/certs/key.pem ;;
    *) err "未知内核: $core"; return 1 ;;
  esac
  mkdir -p "$(dirname "$target_cert")" "$(dirname "$target_key")" "/etc/mihomo-anytls/cert-pool/$domain"
  cp -f "$cert" "$target_cert"
  cp -f "$key" "$target_key"
  chmod 644 "$target_cert"
  chmod 600 "$target_key"
  cp -f "$cert" "/etc/mihomo-anytls/cert-pool/$domain/fullchain.pem"
  cp -f "$key" "/etc/mihomo-anytls/cert-pool/$domain/key.pem"
  cat > "/etc/mihomo-anytls/cert-pool/$domain/meta.env" <<EOF
DOMAIN="$domain"
SOURCE="ssl-manager-root-cert"
SOURCE_CERT="$cert"
SOURCE_KEY="$key"
RUNTIME_CERT="$target_cert"
RUNTIME_KEY="$target_key"
UPDATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EOF
  info "已同步到 $core 运行目录。"
  info "证书: $target_cert"
  info "私钥: $target_key"
}

repair_existing_acme(){
  local domain
  read -r -p "请输入已有 acme.sh 记录的域名: " domain
  is_domain "$domain" || { err "域名无效。"; return 1; }
  install_cert_to_root_cert "$domain"
}

menu_once(){
  local c
  echo "============================================================"
  echo " SSL Manager（参考 3x-ui 模型）"
  echo "============================================================"
  echo "  1) Get SSL（HTTP-01 / 80端口）"
  echo "  2) Get SSL（Cloudflare DNS）"
  echo "  3) 修复/安装已有 acme.sh 证书到 /root/cert"
  echo "  4) 查看已有证书和 acme.sh 记录"
  echo "  5) Force Renew 强制续期"
  echo "  6) 同步 /root/cert 证书到 mihomo/sing-box"
  echo "  7) Revoke & Remove 撤销并删除"
  echo "  0) 退出"
  read -r -p "输入序号 [4]: " c
  c="${c:-4}"
  case "$c" in
    1) issue_http ;;
    2) issue_cf ;;
    3) repair_existing_acme ;;
    4) list_certs ;;
    5) force_renew ;;
    6) sync_runtime ;;
    7) revoke_remove ;;
    0) exit 0 ;;
    *) err "无效操作"; return 1 ;;
  esac
}

menu_loop(){
  while true; do
    menu_once || true
    pause_back
  done
}

main(){
  need_root
  case "${1:-}" in
    issue-http) issue_http ;;
    issue-cf) issue_cf ;;
    install-existing) repair_existing_acme ;;
    list|status) list_certs ;;
    renew) force_renew ;;
    sync) sync_runtime ;;
    revoke) revoke_remove ;;
    *) menu_loop ;;
  esac
}

main "$@"
