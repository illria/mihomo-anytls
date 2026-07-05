#!/usr/bin/env bash
set -Eeuo pipefail

PKG_MANAGER="unknown"
INIT_SYSTEM="unknown"
DOMAIN="${1:-}"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_STATIC_ROOT="/usr/share/nginx/html"
SITE_DIR="$NGINX_STATIC_ROOT/mihomo-anytls"
SITE_CONF_NAME="mihomo-anytls-site.conf"
SITE_TITLE="Eianun Network Status"

info(){ printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行。"; }

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
  elif [ -x /etc/init.d/nginx ]; then INIT_SYSTEM=initd
  else INIT_SYSTEM=unknown
  fi
}

read_env_value(){
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  grep -E "^${key}=" "$file" | tail -n1 | sed -E 's/^[^=]+=//; s/^"//; s/"$//' | sed 's/\\"/"/g; s/\\\\/\\/g'
}

load_domain(){
  [ -n "$DOMAIN" ] && return 0
  DOMAIN="$(read_env_value /etc/mihomo/install.env DOMAIN || true)"
  [ -n "$DOMAIN" ] || DOMAIN="$(read_env_value /etc/sing-box/install.env DOMAIN || true)"
  if [ -z "$DOMAIN" ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    read -r -p "请输入静态站域名 [status.local]: " DOMAIN < /dev/tty
  fi
  DOMAIN="${DOMAIN:-status.local}"
}

install_nginx(){
  if has nginx; then return 0; fi
  info "安装 Nginx"
  case "$PKG_MANAGER" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y nginx ;;
    dnf) dnf install -y nginx ;;
    yum) yum install -y nginx ;;
    apk) apk add --no-cache nginx ;;
    pacman) pacman -Sy --noconfirm --needed nginx ;;
    zypper) zypper --non-interactive install nginx ;;
    opkg) opkg update || true; opkg install nginx || true ;;
    *) die "未识别包管理器，请先手动安装 nginx。" ;;
  esac
  has nginx || die "Nginx 安装失败。"
}

prepare_paths(){
  if [ -d /etc/nginx/http.d ]; then
    NGINX_CONF_DIR="/etc/nginx/http.d"
  else
    NGINX_CONF_DIR="/etc/nginx/conf.d"
    mkdir -p "$NGINX_CONF_DIR"
  fi
  mkdir -p "$SITE_DIR"
}

write_site(){
  cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>$SITE_TITLE</title>
  <style>
    :root{color-scheme:light dark}body{margin:0;font-family:Arial,Helvetica,sans-serif;background:#f6f8fb;color:#111}.wrap{max-width:860px;margin:7vh auto;padding:24px}.card{background:#fff;border:1px solid #e5e7eb;border-radius:20px;padding:34px;box-shadow:0 20px 60px rgba(15,23,42,.08)}h1{margin:0 0 10px;font-size:32px}.ok{display:inline-block;margin:14px 0;padding:8px 12px;border-radius:999px;background:#dcfce7;color:#166534;font-weight:700}.muted{color:#64748b;line-height:1.7}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-top:22px}.item{border:1px solid #e5e7eb;border-radius:14px;padding:14px;background:#fafafa}.k{font-size:12px;color:#64748b}.v{margin-top:5px;font-weight:700}@media(prefers-color-scheme:dark){body{background:#0b1120;color:#e5e7eb}.card{background:#111827;border-color:#243244}.item{background:#0f172a;border-color:#243244}.muted,.k{color:#94a3b8}.ok{background:#064e3b;color:#bbf7d0}}
  </style>
</head>
<body>
  <main class="wrap">
    <section class="card">
      <h1>$SITE_TITLE</h1>
      <div class="ok">All systems operational</div>
      <p class="muted">This is a lightweight service status page for $DOMAIN. It is intentionally generic and does not imitate any third-party brand or website.</p>
      <div class="grid">
        <div class="item"><div class="k">Service</div><div class="v">Network Status</div></div>
        <div class="item"><div class="k">Region</div><div class="v">Global</div></div>
        <div class="item"><div class="k">HTTP</div><div class="v">Online</div></div>
      </div>
    </section>
  </main>
</body>
</html>
EOF
}

write_nginx_conf(){
  local conf="$NGINX_CONF_DIR/$SITE_CONF_NAME"
  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $SITE_DIR;
    index index.html;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer-when-downgrade always;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
  info "Nginx 静态站配置：$conf"
}

start_nginx(){
  nginx -t
  detect_init
  case "$INIT_SYSTEM" in
    systemd) systemctl enable --now nginx; systemctl restart nginx ;;
    openrc) rc-update add nginx default >/dev/null 2>&1 || true; rc-service nginx restart ;;
    initd) /etc/init.d/nginx restart ;;
    *) nginx -s reload 2>/dev/null || nginx ;;
  esac
}

main(){
  need_root
  detect_pkg
  load_domain
  install_nginx
  prepare_paths
  write_site
  write_nginx_conf
  start_nginx
  echo "------------------------------------------------------------"
  info "静态站已启用"
  echo "域名: $DOMAIN"
  echo "端口: 80/tcp"
  echo "目录: $SITE_DIR"
  echo "配置: $NGINX_CONF_DIR/$SITE_CONF_NAME"
  echo "访问: http://$DOMAIN/"
  echo "注意: 本模块只监听 80，不占用 443，避免影响 AnyTLS。"
}

main "$@"
