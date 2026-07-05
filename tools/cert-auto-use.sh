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

confirm(){
  msg="$1"
  def="${2:-y}"
  ans=""
  if [ "$def" = "y" ]; then
    read -r -p "$msg [Y/n]: " ans
    ans="${ans:-y}"
  else
    read -r -p "$msg [y/N]: " ans
    ans="${ans:-n}"
  fi
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

safe_name(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'; }
now_utc(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }

[ -n "$DOMAIN" ] || { read -r -p "请输入域名: " DOMAIN; }
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

try_acme_renew(){
  cert="$1"
  key="$2"
  source="$3"
  acme="/root/.acme.sh/acme.sh"
  [ -x "$acme" ] || return 1
  echo "$cert" | grep -q '/.acme.sh/' || return 1
  info "检测到 acme.sh 证书，尝试续期: $DOMAIN"
  "$acme" --renew -d "$DOMAIN" --ecc --force || "$acme" --renew -d "$DOMAIN" --force || return 1
  install_pair "$cert" "$key" "$source"
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
    if confirm "是否导入证书池并同步到运行目录？" y; then
      install_pair "$cert" "$key" "$source"
      exit 0
    fi
    return 1
  fi
  warn "证书已过期或即将过期。"
  if confirm "是否尝试按原 acme.sh 记录续期，成功后导入证书池并同步？" y; then
    try_acme_renew "$cert" "$key" "$source" && exit 0
    warn "自动续期失败。"
  fi
  return 1
}

try_pair "/etc/mihomo/certs/fullchain.pem" "/etc/mihomo/certs/key.pem" "mihomo-runtime" || true
try_pair "/etc/sing-box/certs/fullchain.pem" "/etc/sing-box/certs/key.pem" "sing-box-runtime" || true
try_pair "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer" "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key" "acme.sh-ecc" || true
try_pair "/root/.acme.sh/${DOMAIN}/fullchain.cer" "/root/.acme.sh/${DOMAIN}/${DOMAIN}.key" "acme.sh" || true
try_pair "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "certbot" || true

warn "没有可自动使用的证书。"
exit 2
