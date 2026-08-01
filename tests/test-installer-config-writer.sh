#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/mihomo-anytls-install.sh"

bash -n "$INSTALLER"

writer="$(sed -n '/^write_config(){/,/^}/p' "$INSTALLER")"
[ -n "$writer" ] || { echo "write_config function not found" >&2; exit 1; }

grep -Fq 'case "$CORE" in' <<<"$writer"
grep -Fq 'mihomo) write_mihomo_config ;;' <<<"$writer"
grep -Fq 'sing-box) write_singbox_config ;;' <<<"$writer"
grep -Fq '*) die "未知内核: $CORE" ;;' <<<"$writer"
grep -Fq 'validate_generated_config' <<<"$writer"

if grep -Fq 'write_config(){ [ "$CORE" = mihomo ] && write_mihomo_config || write_singbox_config' "$INSTALLER"; then
  echo "unsafe write_config dispatch is still present" >&2
  exit 1
fi

echo "installer config dispatch regression test passed"
