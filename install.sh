#!/usr/bin/env bash
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main/mihomo-anytls-install.sh"
TMP_FILE=""

cleanup() {
  [ -n "$TMP_FILE" ] && [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE"
}
trap cleanup EXIT

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 运行，例如：sudo bash <(curl -fsSL https://raw.githubusercontent.com/illria/mihomo-anytls/main/install.sh)" >&2
  exit 1
fi

if command -v mktemp >/dev/null 2>&1; then
  TMP_FILE="$(mktemp /tmp/mihomo-anytls-install.XXXXXX.sh)"
else
  TMP_FILE="/tmp/mihomo-anytls-install.$$.$RANDOM.sh"
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$TMP_FILE"
elif command -v wget >/dev/null 2>&1; then
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
