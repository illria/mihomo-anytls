#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/install.sh"

bash -n "$ENTRY"

if grep -Fq 'patch_main_installer' "$ENTRY"; then
  echo "runtime installer patcher must not exist" >&2
  exit 1
fi

interactive="$(sed -n '/^run_remote_script_interactive(){/,/^}/p' "$ENTRY")"
noninteractive="$(sed -n '/^run_remote_script_noninteractive(){/,/^}/p' "$ENTRY")"
[ -n "$interactive" ] || { echo "interactive remote runner not found" >&2; exit 1; }
[ -n "$noninteractive" ] || { echo "noninteractive remote runner not found" >&2; exit 1; }
grep -Fq 'download_file "$url" "$f"' <<<"$interactive"
grep -Fq 'execute_remote_script_interactive "$f" "$@"' <<<"$interactive"
grep -Fq 'download_file "$url" "$f"' <<<"$noninteractive"
grep -Fq 'execute_remote_script_noninteractive "$f" "$@"' <<<"$noninteractive"
grep -Fq 'bash "$file" "$@" </dev/null' "$ENTRY"

if grep -Eq 'python3|re.sub|patch_main_installer' <<<"$interactive$noninteractive"; then
  echo "remote runner still mutates the downloaded installer" >&2
  exit 1
fi

echo "entrypoint wrapper regression test passed"
