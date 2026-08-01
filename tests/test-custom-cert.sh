#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/mihomo-anytls-install.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

bash -n "$INSTALLER"

STRIPPED_INSTALLER="$TMP_ROOT/installer-without-main.sh"
sed '/^main "\$@"$/d' "$INSTALLER" > "$STRIPPED_INSTALLER"
# shellcheck disable=SC1090
source "$STRIPPED_INSTALLER"

make_pair() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=$name" \
    -keyout "$dir/privkey.pem" \
    -out "$dir/fullchain.pem" >/dev/null 2>&1
}

run_case() {
  local name="$1" expected_cert="$2" expected_key="$3" output_dir="$TMP_ROOT/output-$1"
  shift 3
  mkdir -p "$output_dir"
  CERT_DIR="$output_dir"
  CERT_FILE="$output_dir/fullchain.pem"
  KEY_FILE="$output_dir/privkey.pem"

  printf '%s\n' "$@" | custom_cert >/dev/null

  cmp -s "$expected_cert" "$CERT_FILE" || {
    echo "$name: copied certificate does not match" >&2
    exit 1
  }
  cmp -s "$expected_key" "$KEY_FILE" || {
    echo "$name: copied private key does not match" >&2
    exit 1
  }
}

# a. A directory uniquely containing fullchain.pem and privkey.pem.
A="$TMP_ROOT/directory"
make_pair "$A" directory
run_case directory "$A/fullchain.pem" "$A/privkey.pem" "$A"

# b. Explicit certificate and private-key file paths.
B="$TMP_ROOT/files"
make_pair "$B" files
mv "$B/fullchain.pem" "$B/cert.pem"
mv "$B/privkey.pem" "$B/key.pem"
run_case files "$B/cert.pem" "$B/key.pem" "$B/cert.pem" "$B/key.pem"

# c. A missing certificate path must re-prompt instead of exiting.
C="$TMP_ROOT/missing"
make_pair "$C" missing
run_case missing "$C/fullchain.pem" "$C/privkey.pem" "$C/no-cert.pem" "$C"

# d. An invalid private key must re-prompt.
D="$TMP_ROOT/invalid-key"
make_pair "$D" invalid-key
printf '%s\n' 'not a private key' > "$D/invalid.key"
run_case invalid-key "$D/fullchain.pem" "$D/privkey.pem" \
  "$D/fullchain.pem" "$D/invalid.key" \
  "$D/fullchain.pem" "$D/privkey.pem"

# e. A mismatched private key must re-prompt.
E="$TMP_ROOT/mismatch"
OTHER="$TMP_ROOT/other"
make_pair "$E" mismatch
make_pair "$OTHER" other
cp "$OTHER/privkey.pem" "$E/mismatch.key"
run_case mismatch "$E/fullchain.pem" "$E/privkey.pem" \
  "$E/fullchain.pem" "$E/mismatch.key" \
  "$E/fullchain.pem" "$E/privkey.pem"

echo "custom certificate path regression tests passed"
