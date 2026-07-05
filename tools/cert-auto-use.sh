#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
TARGET_CERT="${2:-}"
TARGET_KEY="${3:-}"
WARN_DAYS="${4:-15}"
OUT_ENV="${5:-}"
POOL_DIR="/etc/mihomo-anytls/cert-pool"

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERR ] %s\n' "$*" >&2; }

safe_name(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'; }
now_utc(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
prompt_read(){
  local var="$1" text="$2" def="${3:-}" val=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    if [ -n "$def" ]; then printf '%s [%s]: ' "$text" "$def" > /dev/tty; else printf '%s: ' "$text" > /dev/tty; fi
    IFS= read -r val < /dev/tty || val=""
  else
    val="$def"
  fi
  val="${val:-$def}"
  printf -v "$var" '%s' "$val"
}

[ -n "$TARGET_CERT" ] || TARGET_CERT="/etc/mihomo/certs/fullchain.pem"
[ -n "$TARGET_KEY" ] || TARGET_KEY="/etc/mihomo/certs/key.pem"
command -v openssl >/dev/null 2>&1 || { err "缺少 openssl"; exit 1; }

cert_text(){ openssl x509 -in "$1" -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null || true; }
cert_end(){ cert_text "$1" | sed -n 's/^notAfter=//p'; }
left_days(){
  local end epoch now
  end="$(cert_end "$1")"
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  echo $(( (epoch - now) / 86400 ))
}
extract_domains(){
  local cert="$1" text cn sans
  text="$(cert_text "$cert")"
  sans="$(printf '%s\n' "$text" | grep -oE 'DNS:[A-Za-z0-9*._-]+' | sed 's/^DNS://' | tr '\n' ' ')"
  cn="$(printf '%s\n' "$text" | sed -n 's/.*CN[ =]*\([^,/]*\).*/\1/p' | head -n1)"
  printf '%s %s\n' "$sans" "$cn" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
}
primary_domain(){ extract_domains "$1" | awk '{print $1}'; }
match_domain(){
  local cert="$1" d="$2"
  [ -n "$d" ] || return 1
  extract_domains "$cert" | tr ' ' '\n' | grep -Fxq "$d"
}

copy_cert_as_fullchain(){
  local src="$1" dst="$2" dir ca
  dir="$(dirname "$src")"
  ca="$dir/ca.cer"
  if [ "$(basename "$src")" != "fullchain.cer" ] && [ "$(basename "$src")" != "fullchain.pem" ] && [ -f "$ca" ]; then
    cat "$src" "$ca" > "$dst"
  else
    cp -f "$src" "$dst"
  fi
}

import_to_pool(){
  local cert="$1" key="$2" source="$3" days end dir
  days="$(left_days "$cert")"
  end="$(cert_end "$cert")"
  dir="$POOL_DIR/$(safe_name "$DOMAIN")"
  mkdir -p "$dir"
  copy_cert_as_fullchain "$cert" "$dir/fullchain.pem"
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

write_out_env(){
  [ -n "$OUT_ENV" ] || return 0
  cat > "$OUT_ENV" <<EOF
SELECTED_DOMAIN="$DOMAIN"
SELECTED_CERT="$1"
SELECTED_KEY="$2"
SELECTED_SOURCE="$3"
EOF
  chmod 600 "$OUT_ENV" 2>/dev/null || true
}

sync_pool_to_runtime(){
  local dir
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
  local cert="$1" key="$2" source="$3"
  import_to_pool "$cert" "$key" "$source"
  sync_pool_to_runtime
  write_out_env "$cert" "$key" "$source"
}

renew_acme(){
  local cert="$1" key="$2" source="$3" acme
  acme="/root/.acme.sh/acme.sh"
  [ -x "$acme" ] || return 1
  info "检测到 acme.sh 证书，按 acme.sh 方式续期: $DOMAIN"
  "$acme" --renew -d "$DOMAIN" --ecc --force || "$acme" --renew -d "$DOMAIN" --force || return 1
  install_pair "$cert" "$key" "$source"
}

renew_certbot(){
  local cert="$1" key="$2" source="$3"
  command -v certbot >/dev/null 2>&1 || return 1
  info "检测到 certbot 证书，按 certbot 方式续期: $DOMAIN"
  certbot renew --cert-name "$DOMAIN" --force-renewal || certbot renew --force-renewal || return 1
  install_pair "$cert" "$key" "$source"
}

renew_by_source(){
  local cert="$1" key="$2" source="$3"
  case "$source" in
    acme.sh|acme.sh-ecc) renew_acme "$cert" "$key" "$source" ;;
    certbot) renew_certbot "$cert" "$key" "$source" ;;
    *) warn "该来源暂不支持自动续期: $source"; return 1 ;;
  esac
}

emit_candidate(){
  local cert="$1" key="$2" source="$3" dom days domains
  [ -f "$cert" ] || return 1
  [ -f "$key" ] || return 1
  dom="$(primary_domain "$cert")"
  [ -n "$dom" ] || return 1
  days="$(left_days "$cert")"
  domains="$(extract_domains "$cert")"
  printf '%s|%s|%s|%s|%s|%s\n' "$cert" "$key" "$source" "$dom" "$days" "$domains"
}

find_acme_cert_for_dir(){
  local dir="$1" d="$2" cert=""
  if [ -f "$dir/fullchain.cer" ]; then
    cert="$dir/fullchain.cer"
  elif [ -f "$dir/${d}.cer" ]; then
    cert="$dir/${d}.cer"
  else
    cert="$(find "$dir" -maxdepth 1 -type f -name '*.cer' ! -name 'ca.cer' ! -name 'fullchain.cer' | head -n1 || true)"
  fi
  [ -n "$cert" ] && printf '%s\n' "$cert"
}

candidate_lines(){
  local cert key source d dir rest item dom
  for item in \
    "/etc/mihomo/certs/fullchain.pem|/etc/mihomo/certs/key.pem|mihomo-runtime" \
    "/etc/sing-box/certs/fullchain.pem|/etc/sing-box/certs/key.pem|sing-box-runtime"; do
    cert="${item%%|*}"; rest="${item#*|}"; key="${rest%%|*}"; source="${rest##*|}"
    emit_candidate "$cert" "$key" "$source" || true
  done

  for dir in /root/.acme.sh/*_ecc; do
    [ -d "$dir" ] || continue
    d="$(basename "$dir")"; d="${d%_ecc}"
    key="$dir/${d}.key"
    cert="$(find_acme_cert_for_dir "$dir" "$d" || true)"
    emit_candidate "$cert" "$key" "acme.sh-ecc" || true
  done

  for dir in /root/.acme.sh/*; do
    [ -d "$dir" ] || continue
    case "$dir" in *_ecc) continue;; esac
    d="$(basename "$dir")"
    key="$dir/${d}.key"
    cert="$(find_acme_cert_for_dir "$dir" "$d" || true)"
    emit_candidate "$cert" "$key" "acme.sh" || true
  done

  for cert in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -f "$cert" ] || continue
    d="$(basename "$(dirname "$cert")")"
    key="/etc/letsencrypt/live/${d}/privkey.pem"
    emit_candidate "$cert" "$key" "certbot" || true
  done
}

use_candidate(){
  local line="$1" cert key source dom days domains rest
  cert="${line%%|*}"; rest="${line#*|}"; key="${rest%%|*}"; rest="${rest#*|}"; source="${rest%%|*}"; rest="${rest#*|}"; dom="${rest%%|*}"; rest="${rest#*|}"; days="${rest%%|*}"; domains="${rest#*|}"
  DOMAIN="${DOMAIN:-$dom}"
  if ! match_domain "$cert" "$DOMAIN"; then DOMAIN="$dom"; fi
  echo "------------------------------------------------------------"
  info "使用证书域名: $DOMAIN"
  info "证书路径: $cert"
  info "私钥路径: $key"
  info "来源: $source"
  info "证书域名列表: $domains"
  info "剩余天数: $days"
  if [ "$days" -gt "$WARN_DAYS" ]; then
    info "证书未过期，直接导入证书池并同步到运行目录。"
    install_pair "$cert" "$key" "$source"
    exit 0
  fi
  warn "证书已过期或即将过期，按来源尝试续期。"
  if renew_by_source "$cert" "$key" "$source"; then exit 0; fi
  warn "续期失败或该来源不支持自动续期。"
  return 1
}

choose_from_candidates(){
  local list="$1" count choice line i
  count="$(printf '%s\n' "$list" | sed '/^$/d' | wc -l | awk '{print $1}')"
  [ "$count" -gt 0 ] || return 1
  echo "------------------------------------------------------------"
  if [ -n "$DOMAIN" ]; then warn "没有找到与输入域名匹配的本地证书: $DOMAIN"; else warn "未输入域名，先扫描本机已有证书。"; fi
  echo "发现本机证书："
  i=1
  printf '%s\n' "$list" | sed '/^$/d' | while IFS='|' read -r cert key source dom days domains; do
    printf '  %s) %s  剩余天数=%s  来源=%s\n     证书: %s\n     私钥: %s\n' "$i" "$dom" "$days" "$source" "$cert" "$key"
    i=$((i+1))
  done
  if [ "$count" -eq 1 ]; then choice=1; else prompt_read choice "请选择要使用的证书序号" "1"; fi
  line="$(printf '%s\n' "$list" | sed '/^$/d' | sed -n "${choice}p")"
  [ -n "$line" ] || { err "无效选择: $choice"; return 1; }
  use_candidate "$line"
}

main(){
  local all exact
  all="$(candidate_lines | awk -F'|' '!seen[$1"|"$2]++')"
  if [ -n "$DOMAIN" ]; then
    exact="$(printf '%s\n' "$all" | while IFS='|' read -r cert key source dom days domains; do [ -n "$cert" ] || continue; if printf '%s\n' "$domains" | tr ' ' '\n' | grep -Fxq "$DOMAIN"; then printf '%s|%s|%s|%s|%s|%s\n' "$cert" "$key" "$source" "$dom" "$days" "$domains"; fi; done | head -n1)"
    [ -n "$exact" ] && use_candidate "$exact"
  fi
  choose_from_candidates "$all" || true
  warn "没有可自动使用或自动续期的本地证书。"
  warn "已扫描 /etc/mihomo/certs、/etc/sing-box/certs、/root/.acme.sh、/etc/letsencrypt/live。"
  exit 2
}

main "$@"
