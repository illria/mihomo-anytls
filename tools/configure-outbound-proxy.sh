#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=""
CORE=""
PROTOCOL=""
DOMAIN=""
PORT=""
USER_NAME=""
PASSWORD=""
UUID_VALUE=""
CONFIG_FILE=""
CERT_FILE=""
KEY_FILE=""
INSTALL_MODE=""
OUTBOUND_TYPE="direct"
OUTBOUND_HOST=""
OUTBOUND_PORT=""
OUTBOUND_USER=""
OUTBOUND_PASS=""
OUTBOUND_NAME="upstream-out"

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行。"; }

read_env_value(){
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  grep -E "^${key}=" "$file" | tail -n1 | sed -E 's/^[^=]+=//; s/^"//; s/"$//' | sed 's/\\"/"/g; s/\\\\/\\/g'
}

json_escape(){
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

yaml_escape(){
  printf '%s' "$1" | sed 's/"/\\"/g'
}

load_env(){
  if [ -f /etc/mihomo/install.env ]; then
    ENV_FILE=/etc/mihomo/install.env
  elif [ -f /etc/sing-box/install.env ]; then
    ENV_FILE=/etc/sing-box/install.env
  else
    die "未找到安装记录：/etc/mihomo/install.env 或 /etc/sing-box/install.env"
  fi

  CORE="$(read_env_value "$ENV_FILE" CORE || true)"
  PROTOCOL="$(read_env_value "$ENV_FILE" PROTOCOL || true)"
  DOMAIN="$(read_env_value "$ENV_FILE" DOMAIN || true)"
  PORT="$(read_env_value "$ENV_FILE" PORT || true)"
  USER_NAME="$(read_env_value "$ENV_FILE" USER_NAME || true)"
  PASSWORD="$(read_env_value "$ENV_FILE" PASSWORD || true)"
  UUID_VALUE="$(read_env_value "$ENV_FILE" UUID_VALUE || true)"
  CONFIG_FILE="$(read_env_value "$ENV_FILE" CONFIG_FILE || true)"
  CERT_FILE="$(read_env_value "$ENV_FILE" CERT_FILE || true)"
  KEY_FILE="$(read_env_value "$ENV_FILE" KEY_FILE || true)"
  INSTALL_MODE="$(read_env_value "$ENV_FILE" INSTALL_MODE || true)"

  [ -n "$CORE" ] || die "安装记录缺少 CORE。"
  [ -n "$PROTOCOL" ] || die "安装记录缺少 PROTOCOL。"
  [ -n "$CONFIG_FILE" ] || die "安装记录缺少 CONFIG_FILE。"
}

choose_outbound(){
  local x auth
  echo "当前节点: $CORE / $PROTOCOL / $DOMAIN:$PORT"
  echo
  echo "请选择出口方式："
  echo "  1) DIRECT 直连"
  echo "  2) HTTP 出口代理"
  echo "  3) SOCKS5 出口代理"
  read -r -p "输入序号 [1]: " x
  x="${x:-1}"

  case "$x" in
    1|direct|DIRECT)
      OUTBOUND_TYPE="direct"
      ;;
    2|http|HTTP)
      OUTBOUND_TYPE="http"
      read -r -p "HTTP 代理地址: " OUTBOUND_HOST
      read -r -p "HTTP 代理端口: " OUTBOUND_PORT
      ;;
    3|socks|socks5|SOCKS5)
      OUTBOUND_TYPE="socks5"
      read -r -p "SOCKS5 代理地址: " OUTBOUND_HOST
      read -r -p "SOCKS5 代理端口: " OUTBOUND_PORT
      ;;
    *) die "无效出口方式：$x" ;;
  esac

  if [ "$OUTBOUND_TYPE" != "direct" ]; then
    [ -n "$OUTBOUND_HOST" ] || die "代理地址不能为空。"
    [[ "$OUTBOUND_PORT" =~ ^[0-9]+$ ]] || die "代理端口必须是数字。"
    read -r -p "是否需要用户名密码认证？[y/N]: " auth
    auth="${auth:-n}"
    case "$auth" in
      y|Y|yes|YES)
        read -r -p "代理用户名: " OUTBOUND_USER
        read -r -p "代理密码: " OUTBOUND_PASS
        ;;
    esac
  fi
}

backup_config(){
  [ -f "$CONFIG_FILE" ] || return 0
  local bak="$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cp -f "$CONFIG_FILE" "$bak"
  info "已备份原配置：$bak"
}

write_mihomo_config(){
  local sec proxy_type yh yp host port user pass
  sec="$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32)"
  host="$(yaml_escape "$OUTBOUND_HOST")"
  port="$OUTBOUND_PORT"
  user="$(yaml_escape "$OUTBOUND_USER")"
  pass="$(yaml_escape "$OUTBOUND_PASS")"

  cat > "$CONFIG_FILE" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
secret: "$sec"
listeners:
  - name: anytls-in
    type: anytls
    listen: 0.0.0.0
    port: $PORT
    users:
      "$USER_NAME": "$PASSWORD"
    certificate: "$CERT_FILE"
    private-key: "$KEY_FILE"
    padding-scheme: ""
EOF

  if [ "$OUTBOUND_TYPE" = "direct" ]; then
    cat >> "$CONFIG_FILE" <<EOF
rules:
  - MATCH,DIRECT
EOF
  else
    if [ "$OUTBOUND_TYPE" = "http" ]; then proxy_type="http"; else proxy_type="socks5"; fi
    cat >> "$CONFIG_FILE" <<EOF
proxies:
  - name: "$OUTBOUND_NAME"
    type: $proxy_type
    server: "$host"
    port: $port
EOF
    if [ -n "$OUTBOUND_USER" ]; then
      cat >> "$CONFIG_FILE" <<EOF
    username: "$user"
    password: "$pass"
EOF
    fi
    cat >> "$CONFIG_FILE" <<EOF
rules:
  - MATCH,$OUTBOUND_NAME
EOF
  fi
}

singbox_outbound_json(){
  local h u p
  h="$(json_escape "$OUTBOUND_HOST")"
  u="$(json_escape "$OUTBOUND_USER")"
  p="$(json_escape "$OUTBOUND_PASS")"

  case "$OUTBOUND_TYPE" in
    direct)
      printf '{"type":"direct","tag":"direct"}'
      ;;
    http)
      printf '{"type":"http","tag":"%s","server":"%s","server_port":%s' "$OUTBOUND_NAME" "$h" "$OUTBOUND_PORT"
      [ -n "$OUTBOUND_USER" ] && printf ',"username":"%s","password":"%s"' "$u" "$p"
      printf '}'
      ;;
    socks5)
      printf '{"type":"socks","tag":"%s","server":"%s","server_port":%s' "$OUTBOUND_NAME" "$h" "$OUTBOUND_PORT"
      [ -n "$OUTBOUND_USER" ] && printf ',"username":"%s","password":"%s"' "$u" "$p"
      printf '}'
      ;;
  esac
}

write_singbox_config(){
  local inbound outbound final domain_e cert_e key_e pass_e user_e uuid_e
  domain_e="$(json_escape "$DOMAIN")"
  cert_e="$(json_escape "$CERT_FILE")"
  key_e="$(json_escape "$KEY_FILE")"
  pass_e="$(json_escape "$PASSWORD")"
  user_e="$(json_escape "$USER_NAME")"
  uuid_e="$(json_escape "$UUID_VALUE")"

  case "$PROTOCOL" in
    anytls)
      inbound='{"type":"anytls","tag":"anytls-in","listen":"::","listen_port":'"$PORT"',"users":[{"password":"'"$pass_e"'"}],"padding_scheme":"","tls":{"enabled":true,"server_name":"'"$domain_e"'","certificate_path":"'"$cert_e"'","key_path":"'"$key_e"'"}}'
      ;;
    hysteria2)
      inbound='{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":'"$PORT"',"users":[{"name":"'"$user_e"'","password":"'"$pass_e"'"}],"tls":{"enabled":true,"server_name":"'"$domain_e"'","certificate_path":"'"$cert_e"'","key_path":"'"$key_e"'"}}'
      ;;
    tuic)
      [ -n "$UUID_VALUE" ] || die "TUIC 缺少 UUID_VALUE。"
      inbound='{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":'"$PORT"',"users":[{"uuid":"'"$uuid_e"'","password":"'"$pass_e"'"}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":"'"$domain_e"'","certificate_path":"'"$cert_e"'","key_path":"'"$key_e"'"}}'
      ;;
    trojan)
      inbound='{"type":"trojan","tag":"trojan-in","listen":"::","listen_port":'"$PORT"',"users":[{"name":"'"$user_e"'","password":"'"$pass_e"'"}],"tls":{"enabled":true,"server_name":"'"$domain_e"'","certificate_path":"'"$cert_e"'","key_path":"'"$key_e"'"}}'
      ;;
    *) die "暂不支持协议：$PROTOCOL" ;;
  esac

  outbound="$(singbox_outbound_json)"
  if [ "$OUTBOUND_TYPE" = "direct" ]; then final="direct"; else final="$OUTBOUND_NAME"; fi
  cat > "$CONFIG_FILE" <<EOF
{"log":{"level":"info"},"inbounds":[$inbound],"outbounds":[$outbound],"route":{"final":"$final"}}
EOF
}

write_outbound_env(){
  local tmp
  tmp="$(mktemp)"
  grep -Ev '^(OUTBOUND_TYPE|OUTBOUND_HOST|OUTBOUND_PORT|OUTBOUND_USER|OUTBOUND_NAME)=' "$ENV_FILE" > "$tmp" || true
  cat >> "$tmp" <<EOF
OUTBOUND_TYPE="$OUTBOUND_TYPE"
OUTBOUND_HOST="$OUTBOUND_HOST"
OUTBOUND_PORT="$OUTBOUND_PORT"
OUTBOUND_USER="$OUTBOUND_USER"
OUTBOUND_NAME="$OUTBOUND_NAME"
EOF
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

restart_service(){
  if [ "$INSTALL_MODE" = "docker" ]; then
    if [ "$CORE" = "mihomo" ]; then
      docker restart mihomo-anytls >/dev/null 2>&1 && info "已重启 Docker: mihomo-anytls" || warn "Docker 重启失败，请手动检查。"
    else
      docker restart "sing-box-$PROTOCOL" >/dev/null 2>&1 && info "已重启 Docker: sing-box-$PROTOCOL" || warn "Docker 重启失败，请手动检查。"
    fi
  elif has systemctl; then
    systemctl restart "$CORE" >/dev/null 2>&1 && info "已重启 systemd: $CORE" || warn "systemd 重启失败，请手动检查。"
  fi
}

show_summary(){
  echo "------------------------------------------------------------"
  info "出口代理配置完成"
  echo "内核: $CORE"
  echo "协议: $PROTOCOL"
  echo "配置文件: $CONFIG_FILE"
  echo "出口方式: $OUTBOUND_TYPE"
  if [ "$OUTBOUND_TYPE" != "direct" ]; then
    echo "出口代理: $OUTBOUND_HOST:$OUTBOUND_PORT"
    [ -n "$OUTBOUND_USER" ] && echo "出口认证: $OUTBOUND_USER / ******"
  fi
  echo "------------------------------------------------------------"
}

main(){
  need_root
  load_env
  choose_outbound
  backup_config
  case "$CORE" in
    mihomo) write_mihomo_config ;;
    sing-box) write_singbox_config ;;
    *) die "未知内核：$CORE" ;;
  esac
  chmod 600 "$CONFIG_FILE"
  write_outbound_env
  restart_service
  show_summary
}

main "$@"
