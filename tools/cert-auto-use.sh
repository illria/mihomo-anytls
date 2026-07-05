#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
TARGET_CERT="${2:-}"
TARGET_KEY="${3:-}"
WARN_DAYS="${4:-15}"
POOL_DIR="/etc/mihomo-anytls/cert-pool"

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERR ] %s\n' "$*" >&2; }

safe_name(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'; }
now_utc(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }

[ -n "$DOMAIN" ] || { err "域名不能为空"; exit 1; }
[ -n "$TARGET_CERT" ] || TARGET_CERT="/etc/mihomo/certs/fullchain.pem"
[ -n "$TARGET_KEY" ] || TARGET_KEY="/etc/mihomo/certs/key.pem"
command -v openssl >/dev/null 2>&1 || { err "缺少 openssl"; exit 1; }

cert_text(){ openssl x509 -in "$1" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true; }
match_domain(){ cert_text "$1" | grep -Fqi "$DOMAIN"; }
cert_end(){ cert_text "$1" | sed -n 's/^notAfter=//p'; }
left_days(){
  end="$(cert_end "$1")"
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch - now) / 86400 ))
}

import_to_pool(){
  cert="$1"
  key="$2"
  source="$3"
  days="$(left_days "$cert")"
  end="$(cert_end "$cert")"
  dir="$POOL_DIR/$(safe_name "$DOMAIN")"
  mkdir -p "$dir"
  cp -f "$cert" "$dir/fullchain.pem"
  cp -f "$key" "$dir/key.pem"
  chmod 644 "$dir/fullchain.pem"
  chmod 600 "$dir/key.pem"
  cat > "$dir/meta.env" <<EOF
DOMAIN="$DOMAIN"
SOURCE="$source"
SOURCE_CERT="$cert"
SOURCE_KEY="$key"
POOL_CERT="$dir/fullchain.pem"
POOL_KEY="$dir/key.pem"
RUNTIME_CERT="$TARGET_CERT"
RUNTIME_KEY="$TARGET_KEY"
IMPORTED_AT="$(now_utc)"
EXPIRES_AT="$end"
DAYS_LEFT="$days"
EOF
  chmod 600 "$dir/meta.env"
  info "已导入多节点证书池: $dir"
}

sync_pool_to_runtime(){
  dir="$POOL_DIR/$(safe_name "$DOMAIN")"
  [ -f "$dir/fullchain.pem" ] || { err "证书池缺少 fullchain: $DOMAIN"; return 1; }
  [ -f "$dir/key.pem" ] || { err "证书池缺少 key: $DOMAIN"; return 1; }
  mkdir -p "$(dirname "$TARGET_CERT")" "$(dirname "$TARGET_KEY")"
  cp -f "$dir/fullchain.pem" "$TARGET_CERT"
  cp -f "$dir/key.pem" "$TARGET_KEY"
  chmod 644 "$TARGET_CERT"
  chmod 600 "$TARGET_KEY"
  info "已同步到运行证书: $TARGET_CERT"
  info "已同步到运行私钥: $TARGET_KEY"
}

install_pair(){
  cert="$1"
  key="$2"
  source="$3"
  import_to_pool "$cert" "$key" "$source"
  sync_pool_to_runtime
}

renew_acme(){
  cert="$1"
  key="$2"
  source="$3"
  acme="/root/.acme.sh/acme.sh"
  [ -x "$acme" ] || return 1
  info "检测到 acme.sh 证书，按 acme.sh 方式续期: $DOMAIN"
  "$acme" --renew -d "$DOMAIN" --ecc --force || "$acme" --renew -d "$DOMAIN" --force || return 1
  install_pair "$cert" "$key" "$source"
}

renew_certbot(){
  cert="$1"
  key="$2"
  source="$3"
  command -v certbot >/dev/null 2>&1 || return 1
  info "检测到 certbot 证书，按 certbot 方式续期: $DOMAIN"
  certbot renew --cert-name "$DOMAIN" --force-renewal || certbot renew --force-renewal || return 1
  install_pair "$cert" "$key" "$source"
}

renew_by_source(){
  cert="$1"
  key="$2"
  source="$3"
  case "$source" in
    acme.sh|acme.sh-ecc) renew_acme "$cert" "$key" "$source" ;;
    certbot) renew_certbot "$cert" "$key" "$source" ;;
    *) warn "该来源暂不支持自动续期: $source"; return 1 ;;
  esac
}

try_pair(){
  cert="$1"
  key="$2"
  source="$3"
  [ -f "$cert" ] || return 1
  [ -f "$key" ] || return 1
  match_domain "$cert" || return 1
  days="$(left_days "$cert")"
  echo "------------------------------------------------------------"
  info "发现匹配证书: $cert"
  info "匹配私钥路径: $key"
  info "来源: $source"
  info "剩余天数: $days"
  if [ "$days" -gt "$WARN_DAYS" ]; then
    info "证书未过期，自动导入证书池并同步到运行目录。"
    install_pair "$cert" "$key" "$source"
    exit 0
  fi
  warn "证书已过期或即将过期，自动按来源尝试续期。"
  if renew_by_source "$cert" "$key" "$source"; then
    exit 0
  fi
  warn "续期失败或该来源不支持自动续期。"
  return 1
}

try_pair "/etc/mihomo/certs/fullchain.pem" "/etc/mihomo/certs/key.pem" "mihomo-runtime" || true
try_pair "/etc/sing-box/certs/fullchain.pem" "/etc/sing-box/certs/key.pem" "sing-box-runtime" || true
try_pair "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer" "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key" "acme.sh-ecc" || true
try_pair "/root/.acme.sh/${DOMAIN}/fullchain.cer" "/root/.acme.sh/${DOMAIN}/${DOMAIN}.key" "acme.sh" || true
try_pair "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "certbot" || true

warn "没有可自动使用或自动续期的本地证书。"
exit 2
