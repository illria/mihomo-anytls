#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/tools/configure-outbound-proxy.sh"
INSTALLER="$ROOT/mihomo-anytls-install.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

bash -n "$TOOL"
bash -n "$INSTALLER"

STRIPPED_TOOL="$TMP_ROOT/tool-without-main.sh"
sed '/^main "\$@"$/d' "$TOOL" > "$STRIPPED_TOOL"
# shellcheck disable=SC1090
source "$STRIPPED_TOOL"

set_common() {
  CORE="mihomo"
  PROTOCOL="anytls"
  DOMAIN="example.com"
  PORT="443"
  USER_NAME="user1"
  PASSWORD="secret"
  UUID_VALUE=""
  CERT_FILE="/etc/mihomo/certs/fullchain.pem"
  KEY_FILE="/etc/mihomo/certs/key.pem"
  OUTBOUND_NAME="upstream-out"
  OUTBOUND_HOST=""
  OUTBOUND_PORT=""
  OUTBOUND_USER=""
  OUTBOUND_PASS=""
}

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq "$needle" "$file" || {
    echo "expected '$needle' in $file" >&2
    exit 1
  }
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -Fq "$needle" "$file"; then
    echo "did not expect '$needle' in $file" >&2
    exit 1
  fi
}

write_mihomo_case() {
  local name="$1"
  CONFIG_FILE="$TMP_ROOT/$name.yaml"
  write_mihomo_config
}

choose_outbound_http_no_auth() {
  set_common
  choose_outbound <<'INPUT'
2
proxy.example
8080
n
INPUT
  [ "$OUTBOUND_TYPE" = "http" ]
  [ "$OUTBOUND_UDP" = false ]
  [ -z "$OUTBOUND_USER" ]
  [ -z "$OUTBOUND_PASS" ]
}

choose_outbound_http_auth() {
  set_common
  choose_outbound <<'INPUT'
2
proxy.example
8080
y
http-user
http-pass
INPUT
  CONFIG_FILE="$TMP_ROOT/http-auth.yaml"
  write_mihomo_config
  assert_contains 'type: http' "$CONFIG_FILE"
  assert_contains 'username: "http-user"' "$CONFIG_FILE"
  assert_contains 'password: "http-pass"' "$CONFIG_FILE"
}

choose_outbound_socks_auth() {
  set_common
  choose_outbound <<'INPUT'
3
proxy.example
1080
y
y
socks-user
socks-pass
INPUT
  CONFIG_FILE="$TMP_ROOT/socks-auth.yaml"
  write_mihomo_config
  assert_contains 'type: socks5' "$CONFIG_FILE"
  assert_contains 'username: "socks-user"' "$CONFIG_FILE"
  assert_contains 'password: "socks-pass"' "$CONFIG_FILE"
}


choose_outbound_http_no_auth
choose_outbound_http_auth
choose_outbound_socks_auth
set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="1080"
OUTBOUND_UDP=true
write_mihomo_case socks5-udp-config
assert_contains 'type: socks5' "$CONFIG_FILE"
assert_contains 'server: "127.0.0.1"' "$CONFIG_FILE"
assert_contains 'port: 1080' "$CONFIG_FILE"
assert_contains 'udp: true' "$CONFIG_FILE"
assert_contains '  - MATCH,upstream-out' "$CONFIG_FILE"
assert_not_contains 'NETWORK,UDP,DIRECT' "$CONFIG_FILE"

set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="10.0.0.2"
OUTBOUND_PORT="1080"
OUTBOUND_UDP=true
write_mihomo_case socks5-udp
assert_contains 'udp: true' "$CONFIG_FILE"

set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="10.0.0.2"
OUTBOUND_PORT="1080"
OUTBOUND_UDP=false
write_mihomo_case socks5-tcp
assert_contains 'udp: false' "$CONFIG_FILE"
assert_not_contains 'udp: true' "$CONFIG_FILE"

set_common
OUTBOUND_TYPE="http"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="1080"
OUTBOUND_UDP=false
write_mihomo_case http
assert_contains 'type: http' "$CONFIG_FILE"
assert_not_contains 'type: socks5' "$CONFIG_FILE"
assert_not_contains 'udp: true' "$CONFIG_FILE"
assert_not_contains 'NETWORK,UDP,DIRECT' "$CONFIG_FILE"
assert_contains '  - MATCH,upstream-out' "$CONFIG_FILE"

set_common
OUTBOUND_TYPE="direct"
OUTBOUND_UDP=false
write_mihomo_case direct
assert_contains '  - MATCH,DIRECT' "$CONFIG_FILE"
assert_not_contains 'proxies:' "$CONFIG_FILE"

set_common
CORE="sing-box"
CONFIG_FILE="$TMP_ROOT/sing-box.json"
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="1080"
OUTBOUND_UDP=true
write_singbox_config
python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
outbound = config["outbounds"][0]
assert outbound["type"] == "socks"
assert outbound["version"] == "5"
assert outbound["server"] == "127.0.0.1"
assert outbound["server_port"] == 1080
assert "udp" not in outbound
assert "network" not in outbound
assert config["route"]["final"] == "upstream-out"
PY

OUTBOUND_UDP=false
write_singbox_config
python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
outbound = config["outbounds"][0]
assert outbound["type"] == "socks"
assert outbound["version"] == "5"
assert outbound["network"] == "tcp"
assert "udp" not in outbound
PY

set_common
CORE="sing-box"
CONFIG_FILE="$TMP_ROOT/sing-http.json"
OUTBOUND_TYPE="http"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="1080"
OUTBOUND_UDP=false
write_singbox_config
python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    outbound = json.load(handle)["outbounds"][0]
assert outbound["type"] == "http"
assert "udp" not in outbound
PY

ENV_FILE="$TMP_ROOT/install.env"
printf 'CORE="mihomo"\nOUTBOUND_TYPE="socks5"\n' > "$ENV_FILE"
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="1080"
OUTBOUND_USER=""
OUTBOUND_PASS="must-not-be-written"
OUTBOUND_NAME="upstream-out"
OUTBOUND_UDP=true
write_outbound_env
assert_contains 'OUTBOUND_UDP="true"' "$ENV_FILE"
assert_not_contains 'OUTBOUND_PASS=' "$ENV_FILE"

assert_contains 'network_mode: host' "$INSTALLER"
assert_not_contains 'host.docker.internal' "$INSTALLER"

test_apply_config_rollback() {
  local kind="$1" existing="$2" original=""
  CORE="$kind"
  PROTOCOL="anytls"
  INSTALL_MODE="systemd"
  ENV_FILE="$TMP_ROOT/rollback-$kind.env"
  CONFIG_FILE="$TMP_ROOT/rollback-$kind.yaml"
  RESTART_CALLED=false
  ENV_WRITE_CALLED=false
  write_mihomo_config() { printf 'new-mihomo\n' > "$CONFIG_FILE"; }
  write_singbox_config() { printf 'new-sing-box\n' > "$CONFIG_FILE"; }
  validate_written_config() { return 1; }
  write_outbound_env() { ENV_WRITE_CALLED=true; }
  restart_service() { RESTART_CALLED=true; }

  if [ "$existing" = true ]; then
    printf 'original-%s\n' "$kind" > "$CONFIG_FILE"
    original="$TMP_ROOT/original-$kind"
    cp "$CONFIG_FILE" "$original"
  else
    rm -f "$CONFIG_FILE"
  fi

  if apply_config; then
    echo "apply_config unexpectedly succeeded for $kind" >&2
    exit 1
  fi
  [ "$RESTART_CALLED" = false ]
  [ "$ENV_WRITE_CALLED" = false ]
  if [ "$existing" = true ]; then
    cmp -s "$CONFIG_FILE" "$original"
  else
    [ ! -e "$CONFIG_FILE" ]
  fi
}

test_apply_config_rollback mihomo true
test_apply_config_rollback sing-box false

echo "outbound SOCKS5 UDP regression tests passed"
