#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
CERT_AUTO_URL="$BASE_URL/tools/cert-auto-use.sh"
WARN_DAYS="${WARN_DAYS:-15}"

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
has(){ command -v "$1" >/dev/null 2>&1; }

cert_text(){ openssl x509 -in "$1" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true; }
cert_end(){ cert_text "$1" | sed -n 's/^notAfter=//p'; }
days_left(){
  local end epoch now
  [ -f "$1" ] || { echo "missing"; return; }
  end="$(cert_end "$1")"
  [ -n "$end" ] || { echo "unknown"; return; }
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch-now)/86400 ))
}
domains_of(){
  local cert="$1" text cn sans
  [ -f "$cert" ] || return 0
  text="$(cert_text "$cert")"
  sans="$(printf '%s\n' "$text" | grep -oE 'DNS:[A-Za-z0-9*._-]+' | sed 's/^DNS://' | tr '\n' ' ')"
  cn="$(printf '%s\n' "$text" | sed -n 's/.*CN[ =]*\([^,/]*\).*/\1/p' | head -n1)"
  printf '%s %s\n' "$sans" "$cn" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}
primary_domain(){ domains_of "$1" | awk '{print $1}'; }
status_of(){
  local days="$1"
  case "$days" in
    missing) echo "缺证书文件" ;;
    unknown) echo "无法读取" ;;
    -*|0) echo "已过期" ;;
    *) if [ "$days" -le "$WARN_DAYS" ]; then echo "即将过期"; else echo "有效"; fi ;;
  esac
}
dns_status(){
  local d="$1"
  if has getent; then getent ahosts "$d" >/dev/null 2>&1 && echo "可解析" || echo "不可解析"; return; fi
  if has nslookup; then nslookup "$d" >/dev/null 2>&1 && echo "可解析" || echo "不可解析"; return; fi
  echo "未检测"
}

acme_cert_in_dir(){
  local dir="$1" d="$2" c=""
  [ -f "$dir/fullchain.cer" ] && { echo "$dir/fullchain.cer"; return; }
  [ -f "$dir/${d}.cer" ] && { echo "$dir/${d}.cer"; return; }
  c="$(find "$dir" -maxdepth 1 -type f -name '*.cer' ! -name 'ca.cer' ! -name 'fullchain.cer' | head -n1 || true)"
  [ -n "$c" ] && echo "$c"
}

emit_cert(){
  local kind="$1" source="$2" cert="$3" key="$4" dom days status dns
  [ -f "$cert" ] && [ -f "$key" ] || return 1
  dom="$(primary_domain "$cert")"
  [ -n "$dom" ] || return 1
  days="$(days_left "$cert")"
  status="$(status_of "$days")"
  dns="$(dns_status "$dom")"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$kind" "$source" "$dom" "$days" "$status" "$dns" "$cert" "$key"
}
emit_record(){
  local source="$1" dir="$2" d="$3" key="$4" dns
  [ -f "$key" ] && [ -f "$dir/${d}.conf" ] || return 1
  dns="$(dns_status "$d")"
  printf '源记录|%s|%s|missing|缺证书文件|%s|ACME_RECORD:%s|%s\n' "$source" "$d" "$dns" "$dir" "$key"
}

inventory(){
  local dir d key cert
  for dir in /root/.acme.sh/*_ecc; do
    [ -d "$dir" ] || continue
    d="$(basename "$dir")"; d="${d%_ecc}"
    key="$dir/${d}.key"
    cert="$(acme_cert_in_dir "$dir" "$d" || true)"
    if [ -n "$cert" ] && [ -f "$cert" ]; then emit_cert "源证书" "acme.sh-ecc" "$cert" "$key" || true; else emit_record "acme-record-ecc" "$dir" "$d" "$key" || true; fi
  done
  for dir in /root/.acme.sh/*; do
    [ -d "$dir" ] || continue
    case "$dir" in *_ecc) continue;; esac
    d="$(basename "$dir")"
    key="$dir/${d}.key"
    cert="$(acme_cert_in_dir "$dir" "$d" || true)"
    if [ -n "$cert" ] && [ -f "$cert" ]; then emit_cert "源证书" "acme.sh" "$cert" "$key" || true; else emit_record "acme-record" "$dir" "$d" "$key" || true; fi
  done
  for cert in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -f "$cert" ] || continue
    d="$(basename "$(dirname "$cert")")"
    emit_cert "源证书" "certbot" "$cert" "/etc/letsencrypt/live/${d}/privkey.pem" || true
  done
  emit_cert "运行副本" "mihomo-runtime" /etc/mihomo/certs/fullchain.pem /etc/mihomo/certs/key.pem || true
  emit_cert "运行副本" "sing-box-runtime" /etc/sing-box/certs/fullchain.pem /etc/sing-box/certs/key.pem || true
}

show_inventory(){
  local rows i
  rows="$(inventory | awk -F'|' '!seen[$1"|"$2"|"$3"|"$7]++')"
  echo "============================================================"
  echo " 证书中心 / Certificate Center"
  echo "============================================================"
  if [ -z "$rows" ]; then
    warn "没有发现本地证书或 acme.sh/certbot 记录。"
    return 1
  fi
  printf '%-4s %-8s %-16s %-28s %-8s %-10s %-8s\n' "序号" "类型" "来源" "域名" "剩余" "状态" "DNS"
  echo "------------------------------------------------------------------------------------------------"
  i=1
  printf '%s\n' "$rows" | while IFS='|' read -r kind source dom days status dns cert key; do
    printf '%-4s %-8s %-16s %-28s %-8s %-10s %-8s\n' "$i" "$kind" "$source" "$dom" "$days" "$status" "$dns"
    echo "     证书/记录: $cert"
    echo "     私钥路径:   $key"
    i=$((i+1))
  done
  echo "------------------------------------------------------------------------------------------------"
  echo "说明：源证书可续期；运行副本只是 /etc/mihomo 或 /etc/sing-box 的使用副本，不能作为长期续期源。"
}

select_row(){
  local rows choice line
  rows="$(inventory | awk -F'|' '!seen[$1"|"$2"|"$3"|"$7]++')"
  [ -n "$rows" ] || return 1
  show_inventory
  read -r -p "选择序号: " choice
  line="$(printf '%s\n' "$rows" | sed -n "${choice}p")"
  [ -n "$line" ] || { err "无效序号"; return 1; }
  printf '%s\n' "$line"
}

sync_selected(){
  local line kind source dom days status dns cert key core target_cert target_key
  line="$(select_row)" || return 1
  IFS='|' read -r kind source dom days status dns cert key <<EOF
$line
EOF
  read -r -p "同步到哪个内核 [mihomo/sing-box] [mihomo]: " core
  core="${core:-mihomo}"
  case "$core" in
    mihomo) target_cert=/etc/mihomo/certs/fullchain.pem; target_key=/etc/mihomo/certs/key.pem ;;
    sing-box|singbox) target_cert=/etc/sing-box/certs/fullchain.pem; target_key=/etc/sing-box/certs/key.pem ;;
    *) err "未知内核: $core"; return 1 ;;
  esac
  curl -fsSL "$CERT_AUTO_URL?t=$(date +%s)" | bash -s -- "$dom" "$target_cert" "$target_key"
}

force_renew_selected(){
  local line kind source dom days status dns cert key
  line="$(select_row)" || return 1
  IFS='|' read -r kind source dom days status dns cert key <<EOF
$line
EOF
  case "$source" in
    acme.sh-ecc|acme-record-ecc|acme.sh|acme-record|certbot)
      WARN_DAYS=99999 curl -fsSL "$CERT_AUTO_URL?t=$(date +%s)" | bash -s -- "$dom" /etc/mihomo/certs/fullchain.pem /etc/mihomo/certs/key.pem 99999
      ;;
    *) err "运行副本不能强制续期，请选择 acme.sh / certbot 源证书。"; return 1 ;;
  esac
}

menu(){
  local c
  echo ""
  show_inventory || true
  echo ""
  echo "可选操作："
  echo "  1) 刷新证书清单"
  echo "  2) 选择证书并同步到运行目录"
  echo "  3) 选择源证书并强制续期"
  echo "  0) 退出"
  read -r -p "输入序号 [1]: " c
  c="${c:-1}"
  case "$c" in
    1) show_inventory ;;
    2) sync_selected ;;
    3) force_renew_selected ;;
    0) exit 0 ;;
    *) err "无效操作"; return 1 ;;
  esac
}

main(){
  command -v openssl >/dev/null 2>&1 || { err "缺少 openssl"; exit 1; }
  case "${1:-}" in
    list|status|"") menu ;;
    *) menu ;;
  esac
}

main "$@"
