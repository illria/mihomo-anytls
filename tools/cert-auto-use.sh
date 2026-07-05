#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
TARGET_CERT="${2:-}"
TARGET_KEY="${3:-}"
WARN_DAYS="${4:-15}"

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

[ -n "$DOMAIN" ] || { read -r -p "请输入域名: " DOMAIN; }
[ -n "$DOMAIN" ] || { err "域名不能为空"; exit 1; }
[ -n "$TARGET_CERT" ] || TARGET_CERT="/etc/mihomo/certs/fullchain.pem"
[ -n "$TARGET_KEY" ] || TARGET_KEY="/etc/mihomo/certs/key.pem"
command -v openssl >/dev/null 2>&1 || { err "缺少 openssl"; exit 1; }

cert_text(){ openssl x509 -in "$1" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true; }
match_domain(){ cert_text "$1" | grep -Fqi "$DOMAIN"; }
left_days(){
  end="$(cert_text "$1" | sed -n 's/^notAfter=//p')"
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch - now) / 86400 ))
}
install_pair(){
  cert="$1"
  key="$2"
  mkdir -p "$(dirname "$TARGET_CERT")" "$(dirname "$TARGET_KEY")"
  cp -f "$cert" "$TARGET_CERT"
  cp -f "$key" "$TARGET_KEY"
  chmod 644 "$TARGET_CERT"
  chmod 600 "$TARGET_KEY"
  info "已写入证书: $TARGET_CERT"
  info "已写入私钥: $TARGET_KEY"
}
try_acme_renew(){
  cert="$1"
  key="$2"
  acme="/root/.acme.sh/acme.sh"
  [ -x "$acme" ] || return 1
  echo "$cert" | grep -q '/.acme.sh/' || return 1
  info "检测到 acme.sh 证书，尝试续期: $DOMAIN"
  "$acme" --renew -d "$DOMAIN" --ecc --force || "$acme" --renew -d "$DOMAIN" --force || return 1
  install_pair "$cert" "$key"
}

try_pair(){
  cert="$1"
  key="$2"
  [ -f "$cert" ] || return 1
  [ -f "$key" ] || return 1
  match_domain "$cert" || return 1
  days="$(left_days "$cert")"
  echo "------------------------------------------------------------"
  info "发现匹配证书: $cert"
  info "匹配私钥路径: $key"
  info "剩余天数: $days"
  if [ "$days" -gt "$WARN_DAYS" ]; then
    if confirm "是否使用这个证书并自动写入目标目录？" y; then
      install_pair "$cert" "$key"
      exit 0
    fi
    return 1
  fi
  warn "证书已过期或即将过期。"
  if confirm "是否尝试按原 acme.sh 记录续期并使用？" y; then
    try_acme_renew "$cert" "$key" && exit 0
    warn "自动续期失败。"
  fi
  return 1
}

try_pair "/etc/mihomo/certs/fullchain.pem" "/etc/mihomo/certs/key.pem" || true
try_pair "/etc/sing-box/certs/fullchain.pem" "/etc/sing-box/certs/key.pem" || true
try_pair "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer" "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key" || true
try_pair "/root/.acme.sh/${DOMAIN}/fullchain.cer" "/root/.acme.sh/${DOMAIN}/${DOMAIN}.key" || true
try_pair "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" || true

warn "没有可自动使用的证书。"
exit 2
