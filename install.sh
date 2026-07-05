#!/usr/bin/env bash
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main/mihomo-anytls-install.sh"
TMP_FILE=""
PKG_MANAGER="unknown"

cleanup() {
  [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE"
}
trap cleanup EXIT

has() { command -v "$1" >/dev/null 2>&1; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 运行，例如：sudo bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)" >&2
  exit 1
fi

detect_pkg() {
  if has apt-get; then PKG_MANAGER=apt;
  elif has dnf; then PKG_MANAGER=dnf;
  elif has yum; then PKG_MANAGER=yum;
  elif has apk; then PKG_MANAGER=apk;
  elif has pacman; then PKG_MANAGER=pacman;
  elif has zypper; then PKG_MANAGER=zypper;
  elif has opkg; then PKG_MANAGER=opkg;
  else PKG_MANAGER=unknown;
  fi
}

start_cron() {
  if has systemctl && [ -d /run/systemd/system ]; then
    systemctl enable --now cronie >/dev/null 2>&1 || \
    systemctl enable --now cron >/dev/null 2>&1 || \
    systemctl enable --now crond >/dev/null 2>&1 || true
  elif has rc-service; then
    rc-update add crond default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
  else
    [ -x /etc/init.d/cron ] && /etc/init.d/cron start >/dev/null 2>&1 || true
    [ -x /etc/init.d/crond ] && /etc/init.d/crond start >/dev/null 2>&1 || true
  fi
}

ensure_crontab() {
  has crontab && { start_cron; return 0; }
  detect_pkg
  echo "[INFO] 未检测到 crontab，预安装 cron/cronie 以兼容 acme.sh 自动续期检查。"
  case "$PKG_MANAGER" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y cron ;;
    dnf) dnf install -y cronie ;;
    yum) yum install -y cronie ;;
    apk) apk add --no-cache dcron ;;
    pacman) pacman -Sy --noconfirm --needed cronie ;;
    zypper) zypper --non-interactive install cron ;;
    opkg) opkg update || true; opkg install cron || true ;;
    *) echo "[WARN] 未识别包管理器，跳过 crontab 预安装。" >&2 ;;
  esac
  start_cron
}

ensure_crontab || true

if has mktemp; then
  TMP_FILE="$(mktemp /tmp/mihomo-anytls-install.XXXXXX.sh)"
else
  TMP_FILE="/tmp/mihomo-anytls-install.$$.$RANDOM.sh"
fi

if has curl; then
  curl -fsSL "$URL" -o "$TMP_FILE"
elif has wget; then
  wget -qO "$TMP_FILE" "$URL"
else
  echo "缺少 curl/wget，请先安装其中一个。" >&2
  exit 1
fi

chmod +x "$TMP_FILE"

# 不能用 curl 主脚本 | bash，否则交互 read 会从管道读取并直接 EOF。
# 这里强制把交互输入接回 /dev/tty，保证菜单可以继续输入。
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
  bash "$TMP_FILE" "$@" < /dev/tty
else
  bash "$TMP_FILE" "$@"
fi
