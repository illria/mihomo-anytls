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


TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail(){
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
assert_contains(){
  local needle="$1" file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "expected '$needle' in $file"
}
assert_not_contains(){
  local needle="$1" file="$2"
  ! grep -F -- "$needle" "$file" >/dev/null || fail "did not expect '$needle' in $file"
}

show_nodes_line="$(grep -F 'show_nodes(){' "$ENTRY")"
assert_contains 'run_remote_script_noninteractive "$SHOW_URL"' <(printf '%s\n' "$show_nodes_line")
assert_not_contains 'show_nodes(){ run_remote_script "$SHOW_URL"; }' <(printf '%s\n' "$show_nodes_line")
assert_not_contains '/dev/tty' <(printf '%s\n' "$noninteractive")

ENTRY_STRIPPED="$TEST_ROOT/install-no-main.sh"
sed '/^main "\$@"$/d' "$ENTRY" > "$ENTRY_STRIPPED"

# All three read-only aliases dispatch to show_nodes' noninteractive runner.
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  need_root(){ :; }
  SHOW_DISPATCH="$TEST_ROOT/show-dispatch"
  CURRENT_ALIAS=""
  run_remote_script_interactive(){
    fail "show/list called interactive runner"
  }
  run_remote_script_noninteractive(){
    [ "$1" = "$SHOW_URL" ] || fail "wrong show URL"
    printf '%s\n' "$CURRENT_ALIAS" >> "$SHOW_DISPATCH"
  }
  for CURRENT_ALIAS in --show show list; do
    main "$CURRENT_ALIAS"
  done
)
[ "$(wc -l < "$TEST_ROOT/show-dispatch" | tr -d ' ')" -eq 3 ] ||
  fail "show aliases did not dispatch three times"
for alias in --show show list; do
  grep -Fx -- "$alias" "$TEST_ROOT/show-dispatch" >/dev/null ||
    fail "alias $alias was not dispatched"
done

# The production noninteractive runner executes show-node-info without a TTY.
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  need_root(){ :; }
  SHOW_SCRIPT="$TEST_ROOT/show-node-info.sh"
  SHOW_RESULT="$TEST_ROOT/show-result"
  export SHOW_RESULT
  make_tmp(){ printf '%s' "$SHOW_SCRIPT"; }
  download_file(){
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      '[ ! -t 0 ] || exit 42' \
      'printf "%s\n" show-node-info > "$SHOW_RESULT"' > "$2"
  }
  execute_remote_script_interactive(){
    fail "show_nodes attempted interactive execution"
  }
  main --show
)
[ "$(cat "$TEST_ROOT/show-result")" = "show-node-info" ] ||
  fail "show_nodes did not execute with noninteractive stdin"

# A show download failure is propagated and does not fall through to the menu.
(
  # shellcheck disable=SC1090
  source "$ENTRY_STRIPPED"
  need_root(){ :; }
  make_tmp(){ printf '%s' "$TEST_ROOT/show-failure.sh"; }
  download_file(){ return 1; }
  execute_remote_script_interactive(){
    fail "show_nodes attempted interactive execution after download failure"
  }
  menu(){
    : > "$TEST_ROOT/menu-called"
    return 1
  }
  if main --show; then
    fail "show download failure returned success"
  fi
)
[ ! -e "$TEST_ROOT/menu-called" ] ||
  fail "show download failure entered the menu"

echo "entrypoint wrapper regression test passed"
