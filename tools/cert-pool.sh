#!/usr/bin/env bash
set -Eeuo pipefail

POOL_DIR="/etc/mihomo-anytls/cert-pool"
WARN_DAYS="${WARN_DAYS:-15}"

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行。"; }
has(){ command -v "$1" >/dev/null 2>&1; }

safe_name(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'; }
now_utc(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }

cert_text(){ openssl x509 -in "$1" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true; }
cert_end(){ cert_text "$1" | sed -n 's/^notAfter=//p'; }
cert_left_days(){
  local end epoch now
  end="$(cert_end "$1")"
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch - now) / 86400 ))
}
match_domain(){ cert_text "$1" | grep -Fqi "$2"; }

pool_path(){ printf '%s/%s' "$POOL_DIR" "$(safe_name "$1")"; }

import_pair(){
  local domain="$1" cert="$2" key="$3" source="${4:-manual}" dir days end
  [ -n "$domain" ] || die "domain 不能为空。"
  [ -f "$cert" ] || die "证书不存在：$cert"
  [ -f "$key" ] || die "私钥不存在：$key"
  match_domain "$cert" "$domain" || die "证书不匹配域名：$domain"
  dir="$(pool_path "$domain")"
  mkdir -p "$dir"
  cp -f "$cert" "$dir/fullchain.pem"
  cp -f "$key" "$dir/key.pem"
  chmod 644 "$dir/fullchain.pem"
  chmod 600 "$dir/key.pem"
  days="$(cert_left_days "$cert")"
  end="$(cert_end "$cert")"
  cat > "$dir/meta.env" <<EOF
DOMAIN="$domain"
SOURCE="$source"
SOURCE_CERT="$cert"
SOURCE_KEY="$key"
POOL_CERT="$dir/fullchain.pem"
POOL_KEY="$dir/key.pem"
IMPORTED_AT="$(now_utc)"
EXPIRES_AT="$end"
DAYS_LEFT="$days"
EOF
  chmod 600 "$dir/meta.env"
  info "已导入证书池：$dir"
  info "剩余天数：$days"
}

sync_to_runtime(){
  local domain="$1" core="${2:-mihomo}" dir target_cert target_key
  [ -n "$domain" ] || die "domain 不能为空。"
  dir="$(pool_path "$domain")"
  [ -f "$dir/fullchain.pem" ] || die "证书池没有该域名：$domain"
  [ -f "$dir/key.pem" ] || die "证书池缺少私钥：$domain"
  case "$core" in
    mihomo) target_cert="/etc/mihomo/certs/fullchain.pem"; target_key="/etc/mihomo/certs/key.pem" ;;
    sing-box|singbox) target_cert="/etc/sing-box/certs/fullchain.pem"; target_key="/etc/sing-box/certs/key.pem" ;;
    *) die "未知内核：$core，只支持 mihomo 或 sing-box" ;;
  esac
  mkdir -p "$(dirname "$target_cert")" "$(dirname "$target_key")"
  cp -f "$dir/fullchain.pem" "$target_cert"
  cp -f "$dir/key.pem" "$target_key"
  chmod 644 "$target_cert"
  chmod 600 "$target_key"
  info "已同步到运行目录：$core"
  echo "证书: $target_cert"
  echo "私钥: $target_key"
}

list_pool(){
  mkdir -p "$POOL_DIR"
  echo "============================================================"
  echo " 多节点证书池"
  echo "============================================================"
  if ! find "$POOL_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
    warn "证书池为空：$POOL_DIR"
    return 0
  fi
  for d in "$POOL_DIR"/*; do
    [ -d "$d" ] || continue
    domain="$(basename "$d")"
    if [ -f "$d/meta.env" ]; then
      DOMAIN="" DAYS_LEFT="" EXPIRES_AT=""
      # shellcheck disable=SC1090
      . "$d/meta.env" 2>/dev/null || true
      domain="${DOMAIN:-$domain}"
    fi
    if [ -f "$d/fullchain.pem" ]; then
      days="$(cert_left_days "$d/fullchain.pem" || echo unknown)"
      end="$(cert_end "$d/fullchain.pem" || true)"
    else
      days="missing"; end="missing"
    fi
    printf '%-40s days=%-8s expires=%s\n' "$domain" "$days" "$end"
  done
}

show_detail(){
  local domain="$1" dir
  [ -n "$domain" ] || read -r -p "请输入域名: " domain
  dir="$(pool_path "$domain")"
  [ -d "$dir" ] || die "证书池没有该域名：$domain"
  echo "目录: $dir"
  [ -f "$dir/meta.env" ] && cat "$dir/meta.env"
  [ -f "$dir/fullchain.pem" ] && openssl x509 -in "$dir/fullchain.pem" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true
}

scan_known_pairs(){
  local domain="$1"
  try_import "$domain" "/etc/mihomo/certs/fullchain.pem" "/etc/mihomo/certs/key.pem" "mihomo-runtime" && return 0 || true
  try_import "$domain" "/etc/sing-box/certs/fullchain.pem" "/etc/sing-box/certs/key.pem" "sing-box-runtime" && return 0 || true
  try_import "$domain" "/root/.acme.sh/${domain}_ecc/fullchain.cer" "/root/.acme.sh/${domain}_ecc/${domain}.key" "acme.sh-ecc" && return 0 || true
  try_import "$domain" "/root/.acme.sh/${domain}/fullchain.cer" "/root/.acme.sh/${domain}/${domain}.key" "acme.sh" && return 0 || true
  try_import "$domain" "/etc/letsencrypt/live/${domain}/fullchain.pem" "/etc/letsencrypt/live/${domain}/privkey.pem" "certbot" && return 0 || true
  return 1
}

try_import(){
  local domain="$1" cert="$2" key="$3" source="$4"
  [ -f "$cert" ] || return 1
  [ -f "$key" ] || return 1
  match_domain "$cert" "$domain" || return 1
  import_pair "$domain" "$cert" "$key" "$source"
}

interactive_menu(){
  local c domain cert key core
  echo "============================================================"
  echo " 多节点证书池管理"
  echo "============================================================"
  echo "  1) 扫描并导入指定域名证书"
  echo "  2) 手动导入证书到证书池"
  echo "  3) 查看证书池"
  echo "  4) 同步证书池到运行目录"
  echo "  5) 查看指定域名证书详情"
  echo "  0) 退出"
  read -r -p "输入序号 [3]: " c
  c="${c:-3}"
  case "$c" in
    1)
      read -r -p "请输入域名: " domain
      scan_known_pairs "$domain" || die "未找到可导入证书：$domain"
      ;;
    2)
      read -r -p "请输入域名: " domain
      read -r -p "请输入证书路径: " cert
      read -r -p "请输入私钥路径: " key
      import_pair "$domain" "$cert" "$key" "manual"
      ;;
    3) list_pool ;;
    4)
      read -r -p "请输入域名: " domain
      read -r -p "同步到哪个内核 [mihomo/sing-box] [mihomo]: " core
      sync_to_runtime "$domain" "${core:-mihomo}"
      ;;
    5)
      read -r -p "请输入域名: " domain
      show_detail "$domain"
      ;;
    0) exit 0 ;;
    *) die "无效操作：$c" ;;
  esac
}

main(){
  need_root
  has openssl || die "缺少 openssl。"
  mkdir -p "$POOL_DIR"
  case "${1:-}" in
    import) import_pair "${2:-}" "${3:-}" "${4:-}" "${5:-manual}" ;;
    scan) scan_known_pairs "${2:-}" ;;
    list|"") [ "${1:-}" = "list" ] && list_pool || interactive_menu ;;
    sync) sync_to_runtime "${2:-}" "${3:-mihomo}" ;;
    show) show_detail "${2:-}" ;;
    *) interactive_menu ;;
  esac
}

main "$@"
