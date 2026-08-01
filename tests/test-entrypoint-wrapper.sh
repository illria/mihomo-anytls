#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/install.sh"

bash -n "$ENTRY"

if grep -Fq 'patch_main_installer' "$ENTRY"; then
  echo "runtime installer patcher must not exist" >&2
  exit 1
fi

run_remote="$(sed -n '/^run_remote_script(){/,/^}/p' "$ENTRY")"
[ -n "$run_remote" ] || { echo "run_remote_script function not found" >&2; exit 1; }
grep -Fq 'download_file "$url" "$f"' <<<"$run_remote"
grep -Fq 'bash "$f" "$@"' <<<"$run_remote"

if grep -Eq 'python3|re\.sub|patch_main_installer' <<<"$run_remote"; then
  echo "run_remote_script still mutates the downloaded installer" >&2
  exit 1
fi

echo "entrypoint wrapper regression test passed"
