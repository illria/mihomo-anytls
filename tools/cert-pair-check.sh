#!/usr/bin/env bash
set -Eeuo pipefail

CERT="${1:-}"
KEY="${2:-}"

err(){ printf '[ERR ] %s\n' "$*" >&2; }
info(){ printf '[INFO] %s\n' "$*"; }

[ -n "$CERT" ] || { err "用法: cert-pair-check.sh <fullchain.pem/cert.cer> <private.key>"; exit 2; }
[ -n "$KEY" ] || { err "用法: cert-pair-check.sh <fullchain.pem/cert.cer> <private.key>"; exit 2; }
[ -s "$CERT" ] || { err "证书文件不存在或为空: $CERT"; exit 1; }
[ -s "$KEY" ] || { err "私钥文件不存在或为空: $KEY"; exit 1; }

if ! openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
  err "证书不是有效 X.509 PEM: $CERT"
  exit 1
fi

if ! openssl pkey -in "$KEY" -noout >/dev/null 2>&1; then
  err "key 文件不是 PRIVATE KEY: $KEY"
  err "常见错误：把 ca.cer / fullchain.cer 当成 key 填了。"
  exit 1
fi

CERT_FP="$(openssl x509 -in "$CERT" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')"
KEY_FP="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $2}')"

if [ -z "$CERT_FP" ] || [ -z "$KEY_FP" ] || [ "$CERT_FP" != "$KEY_FP" ]; then
  err "证书和私钥不匹配。"
  err "证书: $CERT"
  err "私钥: $KEY"
  exit 1
fi

info "证书和私钥匹配。"
openssl x509 -in "$CERT" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true
