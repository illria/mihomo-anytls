#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_NAME="mihomo-anytls"
BASE_URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main"
ANYTLS_MIN_SINGBOX="1.12.0"
DEFAULT_SINGBOX_111="1.11.15"

CORE="mihomo"
INSTALL_MODE="docker"
SINGBOX_VERSION="latest"
SINGBOX_MODE="latest"
PROTOCOL="anytls"
DOMAIN=""
PORT="443"
USER_NAME="user1"
PASSWORD=""
UUID_VALUE=""
CERT_MODE=""
SKIP_CERT_VERIFY="false"
ACME_EMAIL=""

BASE_DIR=""
CERT_DIR=""
CONFIG_FILE=""
CERT_FILE=""
KEY_FILE=""
CLIENT_MIHOMO_FILE=""
CLIENT_SINGBOX_FILE=""
ENV_FILE=""
WORK_DIR="/opt/mihomo-anytls"
SERVICE_FILE=""
BIN_PATH=""
CONTAINER_NAME=""
IMAGE_NAME=""
NEED_PROTO="tcp"
PKG_MANAGER=""
INIT_SYSTEM="unknown"

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行：sudo bash $0"; }

ask(){
  local __var="$1" __label="$2" __default="${3:-}" __value=""
  if [ -n "$__default" ]; then
    read -r -p "$__label [$__default]: " __value
    __value="${__value:-$__default}"
  else
    while [ -z "$__value" ]; do read -r -p "$__label: " __value; done
  fi
  printf -v "$__var" '%s' "$__value"
}

ask_secret(){
  local __var="$1" __label="$2" __default="$3" __value=""
  read -r -p "$__label [回车自动生成]: " __value
  __value="${__value:-$__default}"
  printf -v "$__var" '%s' "$__value"
}

confirm(){
  local label="$1" def="${2:-y}" ans=""
  if [ "$def" = "y" ]; then read -r -p "$label [Y/n]: " ans; ans="${ans:-y}"; else read -r -p "$label [y/N]: " ans; ans="${ans:-n}"; fi
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

rand_secret(){ if has openssl; then openssl rand -hex 16; else date +%s%N | sha256sum | cut -c1-32; fi; }
make_uuid(){ if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; elif has uuidgen; then uuidgen | tr 'A-Z' 'a-z'; else printf '%s-%s-%s-%s-%s\n' "$(rand_secret|cut -c1-8)" "$(rand_secret|cut -c1-4)" "$(rand_secret|cut -c1-4)" "$(rand_secret|cut -c1-4)" "$(rand_secret|cut -c1-12)"; fi; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

ver_norm(){ echo "${1#v}" | sed 's/[^0-9.].*$//'; }
ver_ge(){
  local a b A1 A2 A3 B1 B2 B3
  a="$(ver_norm "$1")"; b="$(ver_norm "$2")"
  IFS=. read -r A1 A2 A3 <<< "$a"; IFS=. read -r B1 B2 B3 <<< "$b"
  A1=${A1:-0}; A2=${A2:-0}; A3=${A3:-0}; B1=${B1:-0}; B2=${B2:-0}; B3=${B3:-0}
  ((10#$A1 > 10#$B1)) && return 0; ((10#$A1 < 10#$B1)) && return 1
  ((10#$A2 > 10#$B2)) && return 0; ((10#$A2 < 10#$B2)) && return 1
  ((10#$A3 >= 10#$B3))
}
supports_anytls(){ [ "$1" = "latest" ] || ver_ge "$1" "$ANYTLS_MIN_SINGBOX"; }

detect_pkg(){
  if has apt-get; then PKG_MANAGER=apt
  elif has dnf; then PKG_MANAGER=dnf
  elif has yum; then PKG_MANAGER=yum
  elif has apk; then PKG_MANAGER=apk
  elif has pacman; then PKG_MANAGER=pacman
  elif has zypper; then PKG_MANAGER=zypper
  elif has opkg; then PKG_MANAGER=opkg
  else PKG_MANAGER=unknown
  fi
}

detect_init(){
  if has systemctl && [ -d /run/systemd/system ]; then INIT_SYSTEM=systemd
  elif has rc-service; then INIT_SYSTEM=openrc
  elif [ -x /etc/init.d/docker ]; then INIT_SYSTEM=initd
  else INIT_SYSTEM=unknown
  fi
}

install_base_deps(){
  detect_pkg
  info "包管理器：$PKG_MANAGER"
  case "$PKG_MANAGER" in
    apt) apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar gzip unzip openssl ca-certificates socat iproute2 coreutils sed grep gawk procps ;;
    dnf) dnf install -y curl wget tar gzip unzip openssl ca-certificates socat iproute coreutils sed grep gawk procps-ng ;;
    yum) yum install -y curl wget tar gzip unzip openssl ca-certificates socat iproute coreutils sed grep gawk procps-ng ;;
    apk) apk add --no-cache curl wget tar gzip unzip openssl ca-certificates socat iproute2 coreutils sed grep gawk procps ;;
    pacman) pacman -Sy --noconfirm --needed curl wget tar gzip unzip openssl ca-certificates socat iproute2 coreutils sed grep gawk procps-ng ;;
    zypper) zypper --non-interactive install curl wget tar gzip unzip openssl ca-certificates socat iproute2 coreutils sed grep gawk procps ;;
    opkg) opkg update || true; opkg install curl wget tar gzip unzip openssl-util ca-bundle ca-certificates socat ip-full coreutils grep sed gawk procps-ng || true ;;
    *) warn "未识别包管理器，请手动安装 curl/wget/tar/gzip/openssl/socat。" ;;
  esac
}

pkg_install(){
  local p
  for p in "$@"; do
    case "$PKG_MANAGER" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" || true ;;
      dnf) dnf install -y "$p" || true ;;
      yum) yum install -y "$p" || true ;;
      apk) apk add --no-cache "$p" || true ;;
      pacman) pacman -Sy --noconfirm --needed "$p" || true ;;
      zypper) zypper --non-interactive install "$p" || true ;;
      opkg) opkg install "$p" || true ;;
    esac
  done
}

country_code(){ curl -fsSL --max-time 3 https://ipinfo.io/country 2>/dev/null || true; }

start_docker(){
  detect_init
  case "$INIT_SYSTEM" in
    systemd)
      systemctl enable --now docker >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update add docker default >/dev/null 2>&1 || true
      rc-service docker start >/dev/null 2>&1 || true
      ;;
    initd)
      /etc/init.d/docker start >/dev/null 2>&1 || true
      ;;
  esac
  if ! docker info >/dev/null 2>&1 && has dockerd; then
    warn "Docker 服务未自动启动，尝试后台拉起 dockerd。"
    nohup dockerd >/var/log/mihomo-anytls-dockerd.log 2>&1 &
    sleep 3
  fi
}

install_docker_by_linuxmirrors(){
  local country source registry
  country="$(country_code)"
  if [ "$country" = "CN" ]; then
    source="mirrors.huaweicloud.com/docker-ce"
    registry="docker.1ms.run"
  else
    source="download.docker.com"
    registry="registry.hub.docker.com"
  fi
  info "使用 linuxmirrors.cn/docker.sh 自动安装 Docker: source=$source registry=$registry"
  bash <(curl -fsSL https://linuxmirrors.cn/docker.sh) \
    --source "$source" \
    --source-registry "$registry" \
    --protocol https \
    --use-intranet-source false \
    --install-latest true \
    --close-firewall false \
    --ignore-backup-tips || true
}

install_docker_by_getdocker(){
  info "使用 get.docker.com 自动安装 Docker。"
  curl -fsSL https://get.docker.com | sh || true
}

install_docker_mirror_config(){
  local country
  country="$(country_code)"
  [ "$country" = "CN" ] || return 0
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io",
    "https://hub.1panel.dev",
    "https://dockerproxy.net"
  ]
}
EOF
}

install_docker(){
  detect_pkg
  if has docker; then
    info "检测到 Docker 已安装。"
    start_docker
  else
    info "未检测到 Docker，开始自动安装 Docker。"
    case "$PKG_MANAGER" in
      apt|dnf|yum)
        install_docker_by_linuxmirrors
        has docker || install_docker_by_getdocker
        has docker || { pkg_install docker.io docker-compose-plugin docker docker-compose-plugin; }
        ;;
      apk)
        pkg_install docker docker-cli-compose docker-compose
        ;;
      pacman)
        pkg_install docker docker-compose
        ;;
      zypper)
        pkg_install docker docker-compose
        ;;
      opkg)
        opkg update || true
        pkg_install dockerd docker docker-compose
        ;;
      *)
        install_docker_by_getdocker
        ;;
    esac
    install_docker_mirror_config || true
    start_docker
  fi
  has docker || die "Docker 自动安装失败。"
  docker info >/dev/null 2>&1 || die "Docker daemon 未运行。请检查 /var/log/mihomo-anytls-dockerd.log 或系统 docker 服务。"
  if ! docker compose version >/dev/null 2>&1 && ! has docker-compose; then
    warn "未检测到 docker compose，尝试安装 Compose 插件。"
    case "$PKG_MANAGER" in
      apt) DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || apt-get install -y docker-compose || true ;;
      dnf|yum) $PKG_MANAGER install -y docker-compose-plugin || $PKG_MANAGER install -y docker-compose || true ;;
      apk) apk add --no-cache docker-cli-compose docker-compose || true ;;
      pacman) pacman -Sy --noconfirm --needed docker-compose || true ;;
      zypper) zypper --non-interactive install docker-compose || true ;;
    esac
  fi
  docker compose version >/dev/null 2>&1 || has docker-compose || warn "Compose 不可用，将使用 docker build + docker run fallback。"
}

arch_common(){ case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l|armv7) echo armv7;; armv6l|armv6) echo armv6;; i386|i686) echo 386;; *) die "暂不支持架构：$(uname -m)";; esac; }
arch_mihomo(){ case "$(uname -m)" in x86_64|amd64) echo amd64-compatible;; aarch64|arm64) echo arm64;; armv7l|armv7) echo armv7;; i386|i686) echo 386;; *) die "暂不支持架构：$(uname -m)";; esac; }
github_latest(){ curl -fsSL "https://api.github.com/repos/$1/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; }

download_mihomo(){
  local target="$1" arch api url tmp
  arch="$(arch_mihomo)"; tmp="$(mktemp -d)"
  info "下载 mihomo latest: $arch"
  api="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)"
  url="$(printf '%s\n' "$api" | grep -oE 'https://[^\"]+/mihomo-linux-'"$arch"'-[^\"]+\.gz' | head -n1 || true)"
  [ -n "$url" ] || die "未找到 mihomo 当前架构资产：$arch"
  curl -fL --retry 3 -o "$tmp/mihomo.gz" "$url"
  gzip -dc "$tmp/mihomo.gz" > "$target"
  chmod +x "$target"; rm -rf "$tmp"; "$target" -v >/dev/null 2>&1 || true
}

download_singbox(){
  local target="$1" ver="$2" arch tmp url tag bin
  arch="$(arch_common)"; tmp="$(mktemp -d)"
  if [ "$ver" = latest ]; then tag="$(github_latest SagerNet/sing-box)"; [ -n "$tag" ] || die "无法获取 sing-box latest"; ver="${tag#v}"; else ver="${ver#v}"; fi
  info "下载 sing-box v$ver: linux-$arch"
  url="https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$arch.tar.gz"
  curl -fL --retry 3 -o "$tmp/sing-box.tar.gz" "$url"
  tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"
  bin="$(find "$tmp" -type f -name sing-box | head -n1)"
  [ -n "$bin" ] || die "sing-box 压缩包内没有二进制文件"
  cp -f "$bin" "$target"; chmod +x "$target"; rm -rf "$tmp"; "$target" version >/dev/null 2>&1 || true
}
existing_singbox_ver(){ has sing-box && sing-box version 2>/dev/null | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -n1 || true; }

prepare_paths(){
  if [ "$CORE" = mihomo ]; then
    BASE_DIR=/etc/mihomo; CONFIG_FILE=$BASE_DIR/config.yaml; BIN_PATH=/usr/local/bin/mihomo; SERVICE_FILE=/etc/systemd/system/mihomo.service; CONTAINER_NAME=mihomo-anytls; IMAGE_NAME=local/mihomo-anytls:latest
  else
    BASE_DIR=/etc/sing-box; CONFIG_FILE=$BASE_DIR/config.json; BIN_PATH=/usr/local/bin/sing-box; SERVICE_FILE=/etc/systemd/system/sing-box.service; CONTAINER_NAME=sing-box-$PROTOCOL; IMAGE_NAME=local/sing-box-$PROTOCOL:latest
  fi
  CERT_DIR=$BASE_DIR/certs; CERT_FILE=$CERT_DIR/fullchain.pem; KEY_FILE=$CERT_DIR/key.pem; ENV_FILE=$BASE_DIR/install.env
  CLIENT_MIHOMO_FILE=$BASE_DIR/client-$PROTOCOL-mihomo.yaml; CLIENT_SINGBOX_FILE=$BASE_DIR/client-$PROTOCOL-sing-box.json
}

install_acme(){ [ -n "$ACME_EMAIL" ] || ask ACME_EMAIL "请输入 acme.sh 注册邮箱" "admin@$DOMAIN"; if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then curl https://get.acme.sh | sh -s email="$ACME_EMAIL"; fi; [ -x "$HOME/.acme.sh/acme.sh" ] || die "acme.sh 安装失败"; "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true; }
reload_cmd(){ if [ "$INSTALL_MODE" = docker ]; then echo "docker restart $CONTAINER_NAME >/dev/null 2>&1 || true"; elif [ "$CORE" = mihomo ]; then echo "systemctl restart mihomo >/dev/null 2>&1 || true"; else echo "systemctl restart sing-box >/dev/null 2>&1 || true"; fi; }
install_acme_cert(){ mkdir -p "$CERT_DIR"; "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$(reload_cmd)" || "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" --reloadcmd "$(reload_cmd)"; chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"; }
self_cert(){ mkdir -p "$CERT_DIR"; info "生成自签证书：$DOMAIN"; openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" >/dev/null 2>&1 || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$DOMAIN" >/dev/null 2>&1; chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"; SKIP_CERT_VERIFY=true; }
custom_cert(){ local c k; ask c "请输入证书 fullchain/cert 路径"; ask k "请输入私钥 key 路径"; [ -f "$c" ] || die "证书不存在：$c"; [ -f "$k" ] || die "私钥不存在：$k"; mkdir -p "$CERT_DIR"; cp -f "$c" "$CERT_FILE"; cp -f "$k" "$KEY_FILE"; chmod 600 "$KEY_FILE"; chmod 644 "$CERT_FILE"; SKIP_CERT_VERIFY=false; }
issue_80(){ install_acme; if has ss && ss -ltn | awk '{print $4}' | grep -Eq '(^|:)80$'; then warn "80/tcp 已被占用"; confirm "仍继续尝试吗" n || die "已取消"; fi; "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --keylength ec-256 --server letsencrypt; install_acme_cert; SKIP_CERT_VERIFY=false; }
issue_cf(){ local token account zone; install_acme; ask token "请输入 Cloudflare API Token"; ask account "请输入 Cloudflare Account ID"; read -r -p "请输入 Cloudflare Zone ID [可留空]: " zone; export CF_Token="$token" CF_Account_ID="$account"; [ -n "$zone" ] && export CF_Zone_ID="$zone"; "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 --server letsencrypt; install_acme_cert; SKIP_CERT_VERIFY=false; }

choose_cert_mode(){ echo; echo "请选择证书方式："; echo "  1) 自签证书"; echo "  2) 自定义证书路径"; echo "  3) 80 端口申请 Let's Encrypt"; echo "  4) Cloudflare DNS 验证证书"; echo "  5) 先扫描本机证书，自动识别域名并使用/续期/同步"; read -r -p "输入序号 [5]: " CERT_MODE; CERT_MODE=${CERT_MODE:-5}; }
choose_cert(){
  local out selected_domain
  [ -n "${CERT_MODE:-}" ] || choose_cert_mode
  case "$CERT_MODE" in
    1) [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"; self_cert ;;
    2) [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"; custom_cert ;;
    3) [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"; issue_80 ;;
    4) [ -n "$DOMAIN" ] || ask DOMAIN "请输入域名，例如 anytls.example.com"; issue_cf ;;
    5)
      out="$(mktemp /tmp/mihomo-anytls-cert-select.XXXXXX.env)"
      if curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$BASE_URL/tools/cert-auto-use.sh?t=$(date +%s)" | bash -s -- "" "$CERT_FILE" "$KEY_FILE" 15 "$out"; then
        if [ -f "$out" ]; then . "$out"; selected_domain="${SELECTED_DOMAIN:-}"; [ -n "$selected_domain" ] && DOMAIN="$selected_domain"; fi
        rm -f "$out"; [ -n "$DOMAIN" ] || die "已选择证书，但没有识别到域名。"; SKIP_CERT_VERIFY=false
      else
        rm -f "$out"; die "本机未找到可用证书。请重新运行后选择 3) 80端口申请 或 4) Cloudflare DNS 验证。"
      fi ;;
    *) die "无效证书方式" ;;
  esac
}

choose_core(){ echo; echo "请选择内核："; echo "  1) mihomo"; echo "  2) sing-box"; read -r -p "输入序号或名称 [1]: " x; x=${x:-1}; case "$x" in 1|mihomo|mihome) CORE=mihomo;; 2|sing-box|singbox) CORE=sing-box;; *) die "无效内核：$x";; esac; }
choose_install(){ echo; echo "请选择安装方式："; echo "  1) Docker 模式（推荐，自动安装 Docker）"; echo "  2) 裸机 systemd 模式"; read -r -p "输入序号 [1]: " x; x=${x:-1}; case "$x" in 1|docker) INSTALL_MODE=docker;; 2|systemd) INSTALL_MODE=systemd;; *) die "无效安装方式";; esac; detect_init; if [ "$INSTALL_MODE" = systemd ] && [ "$INIT_SYSTEM" != systemd ]; then warn "当前不是 systemd：$INIT_SYSTEM"; confirm "改用 Docker 模式吗" y && INSTALL_MODE=docker; fi; }
choose_singbox_version(){ [ "$CORE" = sing-box ] || return 0; local old; old="$(existing_singbox_ver)"; echo; echo "请选择 sing-box 版本："; echo "  1) latest（支持 AnyTLS）"; echo "  2) 1.11.x 兼容版，默认 v$DEFAULT_SINGBOX_111（隐藏 AnyTLS）"; echo "  3) 自定义版本"; echo "  4) 使用系统现有版本 ${old:+($old)}"; read -r -p "输入序号 [1]: " x; x=${x:-1}; case "$x" in 1) SINGBOX_MODE=latest; SINGBOX_VERSION=latest;; 2) SINGBOX_MODE=1.11.x; SINGBOX_VERSION=$DEFAULT_SINGBOX_111;; 3) SINGBOX_MODE=custom; ask SINGBOX_VERSION "请输入版本，例如 1.12.0 或 1.11.15"; SINGBOX_VERSION=${SINGBOX_VERSION#v};; 4) [ -n "$old" ] || die "系统未检测到 sing-box"; SINGBOX_MODE=existing; SINGBOX_VERSION=$old;; *) die "无效版本选择";; esac; }
choose_protocol(){ if [ "$CORE" = mihomo ]; then PROTOCOL=anytls; NEED_PROTO=tcp; return; fi; local ok=false; supports_anytls "$SINGBOX_VERSION" && ok=true; echo; echo "请选择协议："; if [ "$ok" = true ]; then echo "  1) AnyTLS"; echo "  2) Hysteria2"; echo "  3) TUIC v5"; echo "  4) Trojan TLS"; read -r -p "输入序号 [1]: " x; x=${x:-1}; case "$x" in 1|anytls) PROTOCOL=anytls; NEED_PROTO=tcp;; 2|hysteria2|hy2) PROTOCOL=hysteria2; NEED_PROTO=udp;; 3|tuic) PROTOCOL=tuic; NEED_PROTO=udp;; 4|trojan) PROTOCOL=trojan; NEED_PROTO=tcp;; *) die "无效协议";; esac; else warn "sing-box $SINGBOX_VERSION 低于 $ANYTLS_MIN_SINGBOX，隐藏 AnyTLS。"; echo "  1) Hysteria2"; echo "  2) TUIC v5"; echo "  3) Trojan TLS"; read -r -p "输入序号 [1]: " x; x=${x:-1}; case "$x" in 1|hysteria2|hy2) PROTOCOL=hysteria2; NEED_PROTO=udp;; 2|tuic) PROTOCOL=tuic; NEED_PROTO=udp;; 3|trojan) PROTOCOL=trojan; NEED_PROTO=tcp;; anytls) die "当前 sing-box 版本不支持 AnyTLS";; *) die "无效协议";; esac; fi; }
collect_inputs(){ if [ "${CERT_MODE:-}" = "5" ]; then info "已选择本地证书扫描，先跳过域名输入，稍后从证书自动识别。"; else ask DOMAIN "请输入域名，例如 anytls.example.com"; fi; while true; do ask PORT "请输入监听端口" 443; valid_port "$PORT" && break; warn "端口必须是 1-65535"; done; ask USER_NAME "请输入用户标识" user1; ask_secret PASSWORD "请输入密码" "$(rand_secret)"; if [ "$PROTOCOL" = tuic ]; then ask UUID_VALUE "请输入 TUIC UUID" "$(make_uuid)"; fi; }

write_mihomo_config(){
  mkdir -p "$BASE_DIR" "$CERT_DIR" "$WORK_DIR"
  local sec; sec="$(rand_secret)"
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
rules:
  - MATCH,DIRECT
EOF
  cat > "$CLIENT_MIHOMO_FILE" <<EOF
proxies:
  - name: "anytls-$DOMAIN"
    type: anytls
    server: "$DOMAIN"
    port: $PORT
    password: "$PASSWORD"
    client-fingerprint: chrome
    udp: true
    sni: "$DOMAIN"
    skip-cert-verify: $SKIP_CERT_VERIFY
EOF
  cat > "$CLIENT_SINGBOX_FILE" <<EOF
{"type":"anytls","tag":"anytls-$DOMAIN","server":"$DOMAIN","server_port":$PORT,"password":"$PASSWORD","tls":{"enabled":true,"server_name":"$DOMAIN","insecure":$SKIP_CERT_VERIFY}}
EOF
}

write_singbox_config(){
  mkdir -p "$BASE_DIR" "$CERT_DIR" "$WORK_DIR"
  case "$PROTOCOL" in
    anytls) inbound='{"type":"anytls","tag":"anytls-in","listen":"::","listen_port":'"$PORT"',"users":[{"password":"'"$PASSWORD"'"}],"padding_scheme":"","tls":{"enabled":true,"server_name":"'"$DOMAIN"'","certificate_path":"'"$CERT_FILE"'","key_path":"'"$KEY_FILE"'"}}'; mihomo_type=anytls; sing_type=anytls;;
    hysteria2) inbound='{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":'"$PORT"',"users":[{"name":"'"$USER_NAME"'","password":"'"$PASSWORD"'"}],"tls":{"enabled":true,"server_name":"'"$DOMAIN"'","certificate_path":"'"$CERT_FILE"'","key_path":"'"$KEY_FILE"'"}}'; mihomo_type=hysteria2; sing_type=hysteria2;;
    tuic) UUID_VALUE=${UUID_VALUE:-$(make_uuid)}; inbound='{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":'"$PORT"',"users":[{"uuid":"'"$UUID_VALUE"'","password":"'"$PASSWORD"'"}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":"'"$DOMAIN"'","certificate_path":"'"$CERT_FILE"'","key_path":"'"$KEY_FILE"'"}}'; mihomo_type=tuic; sing_type=tuic;;
    trojan) inbound='{"type":"trojan","tag":"trojan-in","listen":"::","listen_port":'"$PORT"',"users":[{"name":"'"$USER_NAME"'","password":"'"$PASSWORD"'"}],"tls":{"enabled":true,"server_name":"'"$DOMAIN"'","certificate_path":"'"$CERT_FILE"'","key_path":"'"$KEY_FILE"'"}}'; mihomo_type=trojan; sing_type=trojan;;
  esac
  cat > "$CONFIG_FILE" <<EOF
{"log":{"level":"info"},"inbounds":[$inbound],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
EOF
  cat > "$CLIENT_SINGBOX_FILE" <<EOF
{"type":"$sing_type","tag":"$PROTOCOL-$DOMAIN","server":"$DOMAIN","server_port":$PORT,"password":"$PASSWORD","tls":{"enabled":true,"server_name":"$DOMAIN","insecure":$SKIP_CERT_VERIFY}${UUID_VALUE:+,"uuid":"$UUID_VALUE"}}
EOF
  cat > "$CLIENT_MIHOMO_FILE" <<EOF
proxies:
  - name: "$PROTOCOL-$DOMAIN"
    type: $mihomo_type
    server: "$DOMAIN"
    port: $PORT
    password: "$PASSWORD"
    sni: "$DOMAIN"
    skip-cert-verify: $SKIP_CERT_VERIFY
EOF
  if [ "$PROTOCOL" = tuic ]; then cat >> "$CLIENT_MIHOMO_FILE" <<EOF
    uuid: "$UUID_VALUE"
    congestion-controller: bbr
EOF
  fi
}

write_env(){ cat > "$ENV_FILE" <<EOF
APP_NAME="$APP_NAME"
CORE="$CORE"
INSTALL_MODE="$INSTALL_MODE"
SINGBOX_VERSION="$SINGBOX_VERSION"
PROTOCOL="$PROTOCOL"
DOMAIN="$DOMAIN"
PORT="$PORT"
USER_NAME="$USER_NAME"
PASSWORD="$PASSWORD"
UUID_VALUE="$UUID_VALUE"
CONFIG_FILE="$CONFIG_FILE"
CERT_FILE="$CERT_FILE"
KEY_FILE="$KEY_FILE"
EOF
chmod 600 "$ENV_FILE" "$CONFIG_FILE" "$CLIENT_MIHOMO_FILE" "$CLIENT_SINGBOX_FILE"; }
write_config(){ [ "$CORE" = mihomo ] && write_mihomo_config || write_singbox_config; write_env; }

install_systemd(){ [ "$INIT_SYSTEM" = systemd ] || die "裸机模式需要 systemd"; if [ "$CORE" = mihomo ]; then download_mihomo "$BIN_PATH"; cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=mihomo AnyTLS Server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=$BIN_PATH -d $BASE_DIR
Restart=on-failure
RestartSec=3s
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable --now mihomo; systemctl restart mihomo; else [ "$SINGBOX_MODE" = existing ] && BIN_PATH="$(command -v sing-box)" || download_singbox "$BIN_PATH" "$SINGBOX_VERSION"; cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box $PROTOCOL Server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=$BIN_PATH run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3s
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable --now sing-box; systemctl restart sing-box; fi; }

compose_up(){ if docker compose version >/dev/null 2>&1; then (cd "$WORK_DIR" && DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 docker compose up -d --build); elif has docker-compose; then (cd "$WORK_DIR" && DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 docker-compose up -d --build); else return 1; fi; }
docker_build_image(){ (cd "$WORK_DIR" && DOCKER_BUILDKIT=0 docker build -t "$IMAGE_NAME" .) || DOCKER_BUILDKIT=0 docker build --no-cache -t "$IMAGE_NAME" "$WORK_DIR"; }

install_docker_mode(){
  install_docker
  mkdir -p "$WORK_DIR"
  if [ "$CORE" = mihomo ]; then
    download_mihomo "$WORK_DIR/mihomo"
    cat > "$WORK_DIR/Dockerfile" <<EOF
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY mihomo /usr/local/bin/mihomo
ENTRYPOINT ["/usr/local/bin/mihomo"]
CMD ["-d","$BASE_DIR"]
EOF
  else
    [ "$SINGBOX_MODE" = existing ] && warn "Docker 模式会下载同版本 sing-box：$SINGBOX_VERSION"
    download_singbox "$WORK_DIR/sing-box" "$SINGBOX_VERSION"
    cat > "$WORK_DIR/Dockerfile" <<EOF
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY sing-box /usr/local/bin/sing-box
ENTRYPOINT ["/usr/local/bin/sing-box"]
CMD ["run","-c","$CONFIG_FILE"]
EOF
  fi
  cat > "$WORK_DIR/docker-compose.yml" <<EOF
services:
  $CORE:
    build: .
    image: $IMAGE_NAME
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    network_mode: host
    volumes:
      - $BASE_DIR:$BASE_DIR
EOF
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if ! compose_up; then
    docker_build_image || die "Docker 镜像构建失败：当前 VPS 的 Docker/procfs 可能不支持 build，请改用裸机 systemd 模式"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [ "$CORE" = mihomo ]; then docker run -d --name "$CONTAINER_NAME" --restart unless-stopped --network host -v "$BASE_DIR:$BASE_DIR" "$IMAGE_NAME" -d "$BASE_DIR"; else docker run -d --name "$CONTAINER_NAME" --restart unless-stopped --network host -v "$BASE_DIR:$BASE_DIR" "$IMAGE_NAME" run -c "$CONFIG_FILE"; fi
  fi
}

firewall_hint(){ if has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then confirm "ufw 放行 $PORT/$NEED_PROTO 吗" y && ufw allow "$PORT/$NEED_PROTO"; elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then confirm "firewalld 放行 $PORT/$NEED_PROTO 吗" y && firewall-cmd --permanent --add-port="$PORT/$NEED_PROTO" && firewall-cmd --reload; else warn "请确认云安全组/软路由防火墙已放行 $PORT/$NEED_PROTO"; fi; }
share_insecure_flag(){ [ "$SKIP_CERT_VERIFY" = true ] && echo 1 || echo 0; }
build_share_link(){ local insecure tag; insecure="$(share_insecure_flag)"; tag="$DOMAIN-$PORT"; case "$PROTOCOL" in anytls) printf 'anytls://%s@%s:%s?peer=%s&insecure=%s&sni=%s#%s\n' "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$DOMAIN" "$tag" ;; hysteria2) printf 'hysteria2://%s@%s:%s?sni=%s&insecure=%s#%s\n' "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$tag" ;; tuic) printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&sni=%s&allow_insecure=%s#%s\n' "$UUID_VALUE" "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$tag" ;; trojan) printf 'trojan://%s@%s:%s?sni=%s&allowInsecure=%s#%s\n' "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$insecure" "$tag" ;; *) printf '暂不支持该协议分享链接: %s\n' "$PROTOCOL" ;; esac; }
install_cert_renew_cron(){ local cron log; cron="/etc/cron.d/mihomo-anytls-cert-renew"; log="/var/log/mihomo-anytls-cert-renew.log"; mkdir -p /etc/cron.d /var/log; cat > "$cron" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
23 3 * * * root curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' '$BASE_URL/tools/cert-auto-use.sh?t='\$(date +\%s) | bash -s -- '$DOMAIN' '$CERT_FILE' '$KEY_FILE' 15 >> '$log' 2>&1
EOF
chmod 644 "$cron"; info "已安装证书自动续期计划: $cron"; info "每天 03:23 检测证书；剩余 <=15 天按来源续期并同步。"; }
summary(){ echo; info "安装完成"; echo "------------------------------------------------------------"; echo "内核: $CORE"; [ "$CORE" = sing-box ] && echo "sing-box 版本: $SINGBOX_VERSION"; echo "协议: $PROTOCOL"; echo "模式: $INSTALL_MODE"; echo "域名: $DOMAIN"; echo "端口: $PORT/$NEED_PROTO"; echo "用户: $USER_NAME"; [ -n "$UUID_VALUE" ] && echo "UUID: $UUID_VALUE"; echo "密码: $PASSWORD"; echo "分享链接: $(build_share_link)"; echo "服务端配置: $CONFIG_FILE"; echo "mihomo 客户端示例: $CLIENT_MIHOMO_FILE"; echo "sing-box 客户端示例: $CLIENT_SINGBOX_FILE"; echo "证书: $CERT_FILE"; echo "私钥: $KEY_FILE"; echo "证书自动续期: /etc/cron.d/mihomo-anytls-cert-renew"; echo "------------------------------------------------------------"; [ "$INSTALL_MODE" = docker ] && echo "日志: docker logs -f $CONTAINER_NAME" || echo "日志: journalctl -u ${CORE/mihomo/mihomo} -f"; warn "Cloudflare DNS 记录建议关闭橙色云朵，使用 DNS only。"; }

main(){
  need_root; install_base_deps; detect_init
  echo "============================================================"; echo " mihomo / sing-box 多协议交互安装脚本"; echo " sing-box 1.11.x: Hysteria2 / TUIC / Trojan"; echo " sing-box 1.12+: AnyTLS / Hysteria2 / TUIC / Trojan"; echo "============================================================"
  choose_core; choose_install; choose_singbox_version; choose_protocol; prepare_paths; choose_cert_mode; collect_inputs; choose_cert; write_config
  [ "$INSTALL_MODE" = docker ] && install_docker_mode || install_systemd
  firewall_hint; install_cert_renew_cron; summary
}

main "$@"
