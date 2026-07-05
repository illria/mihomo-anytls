#!/usr/bin/env bash
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/illria/mihomo-anytls/main/mihomo-anytls-install.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 运行，例如：sudo bash <(curl -Ls $URL)" >&2
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" | bash
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$URL" | bash
else
  echo "缺少 curl/wget，请先安装其中一个。" >&2
  exit 1
fi
