#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
WARN_DAYS="${2:-15}"

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERR ] %s\n' "$*" >&2; }

if [ -z "$DOMAIN" ]; then
  read -r -p "请输入域名: " DOMAIN
fi

[ -n "$DOMAIN" ] || { err "域名不能为空"; exit 1; }
command -v openssl >/dev/null 2>&1 || { err "缺少 openssl"; exit 1; }

check_cert(){
  cert="$1"
  key_hint="$2"
  [ -f "$cert" ] || return 1
  text="$(openssl x509 -in "$cert" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true)"
  printf '%s\n' "$text" | grep -Fqi "$DOMAIN" || return 1
  end="$(printf '%s\n' "$text" | sed -n 's/^notAfter=//p')"
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  left=$(( (epoch - now) / 86400 ))
  echo "------------------------------------------------------------"
  info "发现匹配证书: $cert"
  [ -n "$key_hint" ] && info "建议私钥路径: $key_hint"
  info "到期时间: $end"
  info "剩余天数: $left"
  if [ "$left" -gt "$WARN_DAYS" ]; then
    info "状态: 可直接在安装器里选择 2) 自定义证书路径 复用"
  else
    warn "状态: 已过期或即将过期，请先使用原证书工具续期"
  fi
  return 0
}

found=0
check_cert "/etc/mihomo/certs/fullchain.pem" "/etc/mihomo/certs/key.pem" && found=1 || true
check_cert "/etc/sing-box/certs/fullchain.pem" "/etc/sing-box/certs/key.pem" && found=1 || true
check_cert "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer" "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key" && found=1 || true
check_cert "/root/.acme.sh/${DOMAIN}/fullchain.cer" "/root/.acme.sh/${DOMAIN}/${DOMAIN}.key" && found=1 || true
check_cert "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" && found=1 || true

if [ "$found" -eq 0 ]; then
  warn "未找到匹配 $DOMAIN 的常见本地证书。"
  exit 2
fi

echo "------------------------------------------------------------"
info "检测完成。安装器暂时请选择：2) 自定义证书路径。"
