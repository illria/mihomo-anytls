#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
TARGET_CERT="${2:-/etc/mihomo/certs/fullchain.pem}"
TARGET_KEY="${3:-/etc/mihomo/certs/key.pem}"
WARN_DAYS="${4:-15}"
OUT_ENV="${5:-}"
POOL_DIR="/etc/mihomo-anytls/cert-pool"

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERR ] %s\n' "$*" >&2; }
safe_name(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'; }
now_utc(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }

ask(){
  local var="$1" msg="$2" def="${3:-}" ans=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s [%s]: ' "$msg" "$def" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=""
  fi
  ans="${ans:-$def}"
  printf -v "$var" '%s' "$ans"
}

command -v openssl >/dev/null 2>&1 || { err "缺少 openssl"; exit 1; }

cert_text(){ openssl x509 -in "$1" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true; }
cert_end(){ cert_text "$1" | sed -n 's/^notAfter=//p'; }
days_left(){
  [ -f "$1" ] || { echo missing; return; }
  local end epoch now
  end="$(cert_end "$1")"
  [ -n "$end" ] || { echo unknown; return; }
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch-now)/86400 ))
}
domains_of(){
  [ -f "$1" ] || return 0
  local t cn sans
  t="$(cert_text "$1")"
  sans="$(printf '%s\n' "$t" | grep -oE 'DNS:[A-Za-z0-9*._-]+' | sed 's/^DNS://' | tr '\n' ' ')"
  cn="$(printf '%s\n' "$t" | sed -n 's/.*CN[ =]*\([^,/]*\).*/\1/p' | head -n1)"
  printf '%s %s\n' "$sans" "$cn" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}
primary_domain(){ domains_of "$1" | awk '{print $1}'; }
match_domain(){ [ -n "$2" ] && domains_of "$1" | tr ' ' '\n' | grep -Fxq "$2"; }

copy_fullchain(){
  local src="$1" dst="$2" ca
  ca="$(dirname "$src")/ca.cer"
  if [ -f "$ca" ] && [ "$(basename "$src")" != "fullchain.cer" ] && [ "$(basename "$src")" != "fullchain.pem" ]; then
    cat "$src" "$ca" > "$dst"
  else
    cp -f "$src" "$dst"
  fi
}

acme_cert_in_dir(){
  local dir="$1" d="$2" c=""
  [ -f "$dir/fullchain.cer" ] && { echo "$dir/fullchain.cer"; return; }
  [ -f "$dir/${d}.cer" ] && { echo "$dir/${d}.cer"; return; }
  c="$(find "$dir" -maxdepth 1 -type f -name '*.cer' ! -name 'ca.cer' ! -name 'fullchain.cer' | head -n1 || true)"
  [ -n "$c" ] && echo "$c"
}

emit_cert(){
  local cert="$1" key="$2" source="$3" dom days domains
  [ -f "$cert" ] && [ -f "$key" ] || return 1
  dom="$(primary_domain "$cert")"
  [ -n "$dom" ] || return 1
  days="$(days_left "$cert")"
  domains="$(domains_of "$cert")"
  printf '%s|%s|%s|%s|%s|%s\n' "$cert" "$key" "$source" "$dom" "$days" "$domains"
}

emit_acme_record(){
  local dir="$1" d="$2" key="$3" source="$4"
  [ -f "$key" ] && [ -f "$dir/${d}.conf" ] || return 1
  printf 'ACME_RECORD:%s|%s|%s|%s|missing|%s\n' "$dir" "$key" "$source" "$d" "$d"
}

source_candidates(){
  local dir d key cert
  for dir in /root/.acme.sh/*_ecc; do
    [ -d "$dir" ] || continue
    d="$(basename "$dir")"; d="${d%_ecc}"
    key="$dir/${d}.key"
    cert="$(acme_cert_in_dir "$dir" "$d" || true)"
    [ -n "$cert" ] && emit_cert "$cert" "$key" acme.sh-ecc || emit_acme_record "$dir" "$d" "$key" acme-record-ecc || true
  done
  for dir in /root/.acme.sh/*; do
    [ -d "$dir" ] || continue
    case "$dir" in *_ecc) continue;; esac
    d="$(basename "$dir")"
    key="$dir/${d}.key"
    cert="$(acme_cert_in_dir "$dir" "$d" || true)"
    [ -n "$cert" ] && emit_cert "$cert" "$key" acme.sh || emit_acme_record "$dir" "$d" "$key" acme-record || true
  done
  for cert in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -f "$cert" ] || continue
    d="$(basename "$(dirname "$cert")")"
    emit_cert "$cert" "/etc/letsencrypt/live/${d}/privkey.pem" certbot || true
  done
}

runtime_candidates(){
  emit_cert /etc/mihomo/certs/fullchain.pem /etc/mihomo/certs/key.pem mihomo-runtime || true
  emit_cert /etc/sing-box/certs/fullchain.pem /etc/sing-box/certs/key.pem sing-box-runtime || true
}

candidates(){
  source_candidates
  runtime_candidates
}

install_pair(){
  local cert="$1" key="$2" source="$3" dir days end
  [ -f "$cert" ] || { err "证书文件不存在: $cert"; return 1; }
  dir="$POOL_DIR/$(safe_name "$DOMAIN")"
  mkdir -p "$dir" "$(dirname "$TARGET_CERT")" "$(dirname "$TARGET_KEY")"
  copy_fullchain "$cert" "$dir/fullchain.pem"
  cp -f "$key" "$dir/key.pem"
  chmod 644 "$dir/fullchain.pem"
  chmod 600 "$dir/key.pem"
  cp -f "$dir/fullchain.pem" "$TARGET_CERT"
  cp -f "$dir/key.pem" "$TARGET_KEY"
  chmod 644 "$TARGET_CERT"
  chmod 600 "$TARGET_KEY"
  days="$(days_left "$cert")"
  end="$(cert_end "$cert")"
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
  if [ -n "$OUT_ENV" ]; then
    cat > "$OUT_ENV" <<EOF
SELECTED_DOMAIN="$DOMAIN"
SELECTED_CERT="$cert"
SELECTED_KEY="$key"
SELECTED_SOURCE="$source"
EOF
    chmod 600 "$OUT_ENV" 2>/dev/null || true
  fi
  info "已导入证书池并同步到运行目录副本。"
  info "源证书: $cert"
  info "运行证书副本: $TARGET_CERT"
}

renew_acme_record(){
  local dir="$1" d="$2" key="$3" source="$4" acme cert
  acme="/root/.acme.sh/acme.sh"
  [ -x "$acme" ] || { err "未找到 acme.sh: $acme"; return 1; }
  DOMAIN="${DOMAIN:-$d}"
  info "按 acme.sh 原始记录强制续期: $DOMAIN"
  if [ "$source" = acme.sh-ecc ]; then
    "$acme" --renew -d "$DOMAIN" --ecc --force || "$acme" --issue -d "$DOMAIN" --standalone --keylength ec-256 --server letsencrypt --force || return 1
  else
    "$acme" --renew -d "$DOMAIN" --force || "$acme" --issue -d "$DOMAIN" --standalone --server letsencrypt --force || return 1
  fi
  cert="$(acme_cert_in_dir "$dir" "$d" || true)"
  [ -f "$cert" ] || { err "续期后仍未找到证书文件: $dir"; return 1; }
  install_pair "$cert" "$key" "$source"
}

renew_cert(){
  local cert="$1" key="$2" source="$3" dir d newcert
  case "$source" in
    acme-record-ecc) dir="${cert#ACME_RECORD:}"; d="$(basename "$dir")"; d="${d%_ecc}"; renew_acme_record "$dir" "$d" "$key" acme.sh-ecc ;;
    acme-record) dir="${cert#ACME_RECORD:}"; d="$(basename "$dir")"; renew_acme_record "$dir" "$d" "$key" acme.sh ;;
    acme.sh-ecc|acme.sh)
      dir="$(dirname "$cert")"; d="$(basename "$dir")"; d="${d%_ecc}"
      renew_acme_record "$dir" "$d" "$key" "$source"
      ;;
    certbot)
      command -v certbot >/dev/null 2>&1 || return 1
      certbot renew --cert-name "$DOMAIN" --force-renewal || certbot renew --force-renewal || return 1
      install_pair "$cert" "$key" "$source"
      ;;
    mihomo-runtime|sing-box-runtime)
      warn "运行目录只是副本，不作为续期源。请优先选择 acme.sh / certbot 原始源。"
      return 1
      ;;
    *) return 1 ;;
  esac
}

numeric_gt(){ case "$1" in ''|*[!0-9-]*) return 1;; *) [ "$1" -gt "$2" ];; esac; }

use_line(){
  local line="$1" cert key source dom days domains rest
  cert="${line%%|*}"; rest="${line#*|}"
  key="${rest%%|*}"; rest="${rest#*|}"
  source="${rest%%|*}"; rest="${rest#*|}"
  dom="${rest%%|*}"; rest="${rest#*|}"
  days="${rest%%|*}"; domains="${rest#*|}"
  DOMAIN="${DOMAIN:-$dom}"
  [ -f "$cert" ] && ! match_domain "$cert" "$DOMAIN" && DOMAIN="$dom"
  [ ! -f "$cert" ] && DOMAIN="$dom"
  echo "------------------------------------------------------------"
  info "使用域名: $DOMAIN"
  info "来源: $source"
  info "证书/记录: $cert"
  info "私钥: $key"
  info "剩余天数: $days"
  case "$source" in *runtime) warn "这是运行目录副本，只能兜底复用，不能作为自动续期源。";; esac
  if [ -f "$cert" ] && numeric_gt "$days" "$WARN_DAYS"; then
    install_pair "$cert" "$key" "$source"
    exit 0
  fi
  renew_cert "$cert" "$key" "$source" && exit 0
  return 1
}

choose_line(){
  local list="$1" count choice line default_choice i
  count="$(printf '%s\n' "$list" | sed '/^$/d' | wc -l | awk '{print $1}')"
  [ "$count" -gt 0 ] || return 1
  warn "原始证书源优先；/etc/mihomo 和 /etc/sing-box 运行目录只作为最后兜底。"
  echo "发现证书/记录："
  i=1
  printf '%s\n' "$list" | sed '/^$/d' | while IFS='|' read -r cert key source dom days domains; do
    label="$source"
    case "$source" in
      acme*|certbot) label="$source 原始源" ;;
      *runtime) label="$source 运行副本/兜底" ;;
    esac
    printf '  %s) %s  剩余天数=%s  来源=%s\n     %s\n' "$i" "$dom" "$days" "$label" "$cert"
    i=$((i+1))
  done
  default_choice="$(printf '%s\n' "$list" | sed '/^$/d' | awk -F'|' '$3 !~ /runtime/ {print NR; exit}')"
  default_choice="${default_choice:-1}"
  [ "$count" -eq 1 ] && choice=1 || ask choice "请选择要使用的证书/记录序号" "$default_choice"
  line="$(printf '%s\n' "$list" | sed '/^$/d' | sed -n "${choice}p")"
  [ -n "$line" ] || { err "无效选择: $choice"; return 1; }
  use_line "$line"
}

main(){
  local all exact
  all="$(candidates | awk -F'|' '!seen[$1"|"$2]++')"
  if [ -n "$DOMAIN" ]; then
    exact="$(printf '%s\n' "$all" | while IFS='|' read -r cert key source dom days domains; do
      [ -n "$cert" ] || continue
      if [ "$dom" = "$DOMAIN" ] || printf '%s\n' "$domains" | tr ' ' '\n' | grep -Fxq "$DOMAIN"; then
        printf '%s|%s|%s|%s|%s|%s\n' "$cert" "$key" "$source" "$dom" "$days" "$domains"
      fi
    done | head -n1)"
    [ -n "$exact" ] && use_line "$exact"
  fi
  choose_line "$all" || true
  warn "没有可自动使用或自动续期的本地证书/记录。"
  exit 2
}

main "$@"
