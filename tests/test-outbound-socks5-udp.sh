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
  OUTBOUND_GATEVPN=false
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
  choose_outbound <<< 
set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
write_mihomo_case gatevpn
assert_contains 'type: socks5' "$CONFIG_FILE"
assert_contains 'server: "127.0.0.1"' "$CONFIG_FILE"
assert_contains 'port: 7928' "$CONFIG_FILE"
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
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
assert outbound["server_port"] == 7928
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
OUTBOUND_USER=""
OUTBOUND_PASS="must-not-be-written"
OUTBOUND_NAME="upstream-out"
OUTBOUND_UDP=true
write_outbound_env
assert_contains 'OUTBOUND_UDP="true"' "$ENV_FILE"
assert_not_contains 'OUTBOUND_PASS=' "$ENV_FILE"

assert_contains 'network_mode: host' "$INSTALLER"
assert_not_contains 'host.docker.internal' "$INSTALLER"

start_mock() {
  local mode="$1" info_file="$TMP_ROOT/mock-$1.info"
  rm -f "$info_file"
  python3 - "$mode" "$info_file" <<'PY' >/dev/null 2>&1 &
import socket
import sys

mode = sys.argv[1]
info_file = sys.argv[2]

def read_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return data
        data += chunk
    return data

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(info_file, "w", encoding="ascii") as handle:
    handle.write(str(server.getsockname()[1]))
conn, _ = server.accept()
with conn:
    if mode == "close":
        raise SystemExit(0)
    if read_exact(conn, 3) != b"\x05\x01\x00":
        raise SystemExit(1)
    if mode == "negotiation-fail":
        conn.sendall(b"\x05\xff")
        raise SystemExit(0)
    conn.sendall(b"\x05\x00")
    if read_exact(conn, 10) != b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00":
        raise SystemExit(1)
    if mode == "rep-fail":
        conn.sendall(b"\x05\x05\x00\x01\x7f\x00\x00\x01\x30\x39")
    elif mode == "rsv-fail":
        conn.sendall(b"\x05\x00\x01\x01\x7f\x00\x00\x01\x30\x39")
    elif mode == "zero-port":
        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
    elif mode == "truncated":
        conn.sendall(b"\x05\x00")
    else:
        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x30\x39")
PY
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$info_file" ] && break
    sleep 0.02
  done
  [ -s "$info_file" ] || { echo "mock SOCKS5 server did not start" >&2; exit 1; }
  MOCK_PORT="$(cat "$info_file")"
}

wait_mock() {
  wait "$MOCK_PID" || true
}

expect_check_success() {
  start_mock success
  check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"
  wait_mock
}

expect_check_failure() {
  local mode="$1"
  start_mock "$mode"
  if check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"; then
    echo "expected SOCKS5 UDP check failure for $mode" >&2
    exit 1
  fi
  wait_mock
}

expect_check_success
expect_check_failure negotiation-fail
expect_check_failure rep-fail
expect_check_failure rsv-fail
expect_check_failure zero-port
expect_check_failure truncated

REFUSED_PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
if check_socks5_udp_associate 127.0.0.1 "$REFUSED_PORT"; then
  echo "expected connection-refused SOCKS5 UDP check failure" >&2
  exit 1
fi

OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="$REFUSED_PORT"
OUTBOUND_UDP=true
OUTBOUND_GATEVPN=true
if printf 'n\n' | precheck_gatevpn; then
  echo "failed GateVPN precheck must not be accepted by default" >&2
  exit 1
fi
[ "$OUTBOUND_TYPE" = "socks5" ]
[ "$OUTBOUND_UDP" = true ]
if ! printf 'y\n' | precheck_gatevpn; then
  echo "explicitly retaining failed SOCKS5 UDP config should succeed" >&2
  exit 1
fi
[ "$OUTBOUND_TYPE" = "socks5" ]
[ "$OUTBOUND_UDP" = true ]
[ "$OUTBOUND_GATEVPN" = true ]

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
2\nproxy.example\n8080\nn\n'
  [ "$OUTBOUND_TYPE" = "http" ]
  [ "$OUTBOUND_UDP" = false ]
  [ -z "$OUTBOUND_USER" ]
  [ -z "$OUTBOUND_PASS" ]
}

choose_outbound_http_auth() {
  set_common
  choose_outbound <<< 
set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
write_mihomo_case gatevpn
assert_contains 'type: socks5' "$CONFIG_FILE"
assert_contains 'server: "127.0.0.1"' "$CONFIG_FILE"
assert_contains 'port: 7928' "$CONFIG_FILE"
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
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
assert outbound["server_port"] == 7928
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
OUTBOUND_USER=""
OUTBOUND_PASS="must-not-be-written"
OUTBOUND_NAME="upstream-out"
OUTBOUND_UDP=true
write_outbound_env
assert_contains 'OUTBOUND_UDP="true"' "$ENV_FILE"
assert_not_contains 'OUTBOUND_PASS=' "$ENV_FILE"

assert_contains 'network_mode: host' "$INSTALLER"
assert_not_contains 'host.docker.internal' "$INSTALLER"

start_mock() {
  local mode="$1" info_file="$TMP_ROOT/mock-$1.info"
  rm -f "$info_file"
  python3 - "$mode" "$info_file" <<'PY' >/dev/null 2>&1 &
import socket
import sys

mode = sys.argv[1]
info_file = sys.argv[2]

def read_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return data
        data += chunk
    return data

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(info_file, "w", encoding="ascii") as handle:
    handle.write(str(server.getsockname()[1]))
conn, _ = server.accept()
with conn:
    if mode == "close":
        raise SystemExit(0)
    if read_exact(conn, 3) != b"\x05\x01\x00":
        raise SystemExit(1)
    if mode == "negotiation-fail":
        conn.sendall(b"\x05\xff")
        raise SystemExit(0)
    conn.sendall(b"\x05\x00")
    if read_exact(conn, 10) != b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00":
        raise SystemExit(1)
    if mode == "rep-fail":
        conn.sendall(b"\x05\x05\x00\x01\x7f\x00\x00\x01\x30\x39")
    elif mode == "truncated":
        conn.sendall(b"\x05\x00")
    else:
        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x30\x39")
PY
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$info_file" ] && break
    sleep 0.02
  done
  [ -s "$info_file" ] || { echo "mock SOCKS5 server did not start" >&2; exit 1; }
  MOCK_PORT="$(cat "$info_file")"
}

wait_mock() {
  wait "$MOCK_PID" || true
}

expect_check_success() {
  start_mock success
  check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"
  wait_mock
}

expect_check_failure() {
  local mode="$1"
  start_mock "$mode"
  if check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"; then
    echo "expected SOCKS5 UDP check failure for $mode" >&2
    exit 1
  fi
  wait_mock
}

expect_check_success
expect_check_failure negotiation-fail
expect_check_failure rep-fail
expect_check_failure truncated

REFUSED_PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
if check_socks5_udp_associate 127.0.0.1 "$REFUSED_PORT"; then
  echo "expected connection-refused SOCKS5 UDP check failure" >&2
  exit 1
fi

OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
OUTBOUND_GATEVPN=true
if printf 'n\n' | precheck_gatevpn; then
  echo "failed GateVPN precheck must not be accepted by default" >&2
  exit 1
fi
[ "$OUTBOUND_TYPE" = "socks5" ]
[ "$OUTBOUND_UDP" = true ]

echo "outbound SOCKS5 UDP regression tests passed"
2\nproxy.example\n8080\ny\nhttp-user\nhttp-pass\n'
  CONFIG_FILE="$TMP_ROOT/http-auth.yaml"
  write_mihomo_config
  assert_contains 'type: http' "$CONFIG_FILE"
  assert_contains 'username: "http-user"' "$CONFIG_FILE"
  assert_contains 'password: "http-pass"' "$CONFIG_FILE"
}

choose_outbound_socks_auth() {
  set_common
  choose_outbound <<< 
set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
write_mihomo_case gatevpn
assert_contains 'type: socks5' "$CONFIG_FILE"
assert_contains 'server: "127.0.0.1"' "$CONFIG_FILE"
assert_contains 'port: 7928' "$CONFIG_FILE"
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
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
assert outbound["server_port"] == 7928
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
OUTBOUND_USER=""
OUTBOUND_PASS="must-not-be-written"
OUTBOUND_NAME="upstream-out"
OUTBOUND_UDP=true
write_outbound_env
assert_contains 'OUTBOUND_UDP="true"' "$ENV_FILE"
assert_not_contains 'OUTBOUND_PASS=' "$ENV_FILE"

assert_contains 'network_mode: host' "$INSTALLER"
assert_not_contains 'host.docker.internal' "$INSTALLER"

start_mock() {
  local mode="$1" info_file="$TMP_ROOT/mock-$1.info"
  rm -f "$info_file"
  python3 - "$mode" "$info_file" <<'PY' >/dev/null 2>&1 &
import socket
import sys

mode = sys.argv[1]
info_file = sys.argv[2]

def read_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return data
        data += chunk
    return data

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(info_file, "w", encoding="ascii") as handle:
    handle.write(str(server.getsockname()[1]))
conn, _ = server.accept()
with conn:
    if mode == "close":
        raise SystemExit(0)
    if read_exact(conn, 3) != b"\x05\x01\x00":
        raise SystemExit(1)
    if mode == "negotiation-fail":
        conn.sendall(b"\x05\xff")
        raise SystemExit(0)
    conn.sendall(b"\x05\x00")
    if read_exact(conn, 10) != b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00":
        raise SystemExit(1)
    if mode == "rep-fail":
        conn.sendall(b"\x05\x05\x00\x01\x7f\x00\x00\x01\x30\x39")
    elif mode == "truncated":
        conn.sendall(b"\x05\x00")
    else:
        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x30\x39")
PY
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$info_file" ] && break
    sleep 0.02
  done
  [ -s "$info_file" ] || { echo "mock SOCKS5 server did not start" >&2; exit 1; }
  MOCK_PORT="$(cat "$info_file")"
}

wait_mock() {
  wait "$MOCK_PID" || true
}

expect_check_success() {
  start_mock success
  check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"
  wait_mock
}

expect_check_failure() {
  local mode="$1"
  start_mock "$mode"
  if check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"; then
    echo "expected SOCKS5 UDP check failure for $mode" >&2
    exit 1
  fi
  wait_mock
}

expect_check_success
expect_check_failure negotiation-fail
expect_check_failure rep-fail
expect_check_failure truncated

REFUSED_PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
if check_socks5_udp_associate 127.0.0.1 "$REFUSED_PORT"; then
  echo "expected connection-refused SOCKS5 UDP check failure" >&2
  exit 1
fi

OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
OUTBOUND_GATEVPN=true
if printf 'n\n' | precheck_gatevpn; then
  echo "failed GateVPN precheck must not be accepted by default" >&2
  exit 1
fi
[ "$OUTBOUND_TYPE" = "socks5" ]
[ "$OUTBOUND_UDP" = true ]

echo "outbound SOCKS5 UDP regression tests passed"
3\nproxy.example\n1080\ny\ny\nsocks-user\nsocks-pass\n'
  CONFIG_FILE="$TMP_ROOT/socks-auth.yaml"
  write_mihomo_config
  assert_contains 'type: socks5' "$CONFIG_FILE"
  assert_contains 'username: "socks-user"' "$CONFIG_FILE"
  assert_contains 'password: "socks-pass"' "$CONFIG_FILE"
}

choose_outbound_gatevpn_no_auth() {
  set_common
  choose_outbound <<< 
set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
write_mihomo_case gatevpn
assert_contains 'type: socks5' "$CONFIG_FILE"
assert_contains 'server: "127.0.0.1"' "$CONFIG_FILE"
assert_contains 'port: 7928' "$CONFIG_FILE"
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
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
assert outbound["server_port"] == 7928
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
OUTBOUND_USER=""
OUTBOUND_PASS="must-not-be-written"
OUTBOUND_NAME="upstream-out"
OUTBOUND_UDP=true
write_outbound_env
assert_contains 'OUTBOUND_UDP="true"' "$ENV_FILE"
assert_not_contains 'OUTBOUND_PASS=' "$ENV_FILE"

assert_contains 'network_mode: host' "$INSTALLER"
assert_not_contains 'host.docker.internal' "$INSTALLER"

start_mock() {
  local mode="$1" info_file="$TMP_ROOT/mock-$1.info"
  rm -f "$info_file"
  python3 - "$mode" "$info_file" <<'PY' >/dev/null 2>&1 &
import socket
import sys

mode = sys.argv[1]
info_file = sys.argv[2]

def read_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return data
        data += chunk
    return data

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(info_file, "w", encoding="ascii") as handle:
    handle.write(str(server.getsockname()[1]))
conn, _ = server.accept()
with conn:
    if mode == "close":
        raise SystemExit(0)
    if read_exact(conn, 3) != b"\x05\x01\x00":
        raise SystemExit(1)
    if mode == "negotiation-fail":
        conn.sendall(b"\x05\xff")
        raise SystemExit(0)
    conn.sendall(b"\x05\x00")
    if read_exact(conn, 10) != b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00":
        raise SystemExit(1)
    if mode == "rep-fail":
        conn.sendall(b"\x05\x05\x00\x01\x7f\x00\x00\x01\x30\x39")
    elif mode == "truncated":
        conn.sendall(b"\x05\x00")
    else:
        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x30\x39")
PY
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$info_file" ] && break
    sleep 0.02
  done
  [ -s "$info_file" ] || { echo "mock SOCKS5 server did not start" >&2; exit 1; }
  MOCK_PORT="$(cat "$info_file")"
}

wait_mock() {
  wait "$MOCK_PID" || true
}

expect_check_success() {
  start_mock success
  check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"
  wait_mock
}

expect_check_failure() {
  local mode="$1"
  start_mock "$mode"
  if check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"; then
    echo "expected SOCKS5 UDP check failure for $mode" >&2
    exit 1
  fi
  wait_mock
}

expect_check_success
expect_check_failure negotiation-fail
expect_check_failure rep-fail
expect_check_failure truncated

REFUSED_PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
if check_socks5_udp_associate 127.0.0.1 "$REFUSED_PORT"; then
  echo "expected connection-refused SOCKS5 UDP check failure" >&2
  exit 1
fi

OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
OUTBOUND_GATEVPN=true
if printf 'n\n' | precheck_gatevpn; then
  echo "failed GateVPN precheck must not be accepted by default" >&2
  exit 1
fi
[ "$OUTBOUND_TYPE" = "socks5" ]
[ "$OUTBOUND_UDP" = true ]

echo "outbound SOCKS5 UDP regression tests passed"
4\n'
  [ "$OUTBOUND_TYPE" = "socks5" ]
  [ "$OUTBOUND_HOST" = "127.0.0.1" ]
  [ "$OUTBOUND_PORT" = "7928" ]
  [ "$OUTBOUND_UDP" = true ]
  [ "$OUTBOUND_GATEVPN" = true ]
  [ -z "$OUTBOUND_USER" ]
  [ -z "$OUTBOUND_PASS" ]
  CONFIG_FILE="$TMP_ROOT/gatevpn-no-auth.yaml"
  write_mihomo_config
  assert_not_contains 'username:' "$CONFIG_FILE"
  assert_not_contains 'password:' "$CONFIG_FILE"
}

choose_outbound_http_no_auth
choose_outbound_http_auth
choose_outbound_socks_auth
choose_outbound_gatevpn_no_auth

set_common
OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
write_mihomo_case gatevpn
assert_contains 'type: socks5' "$CONFIG_FILE"
assert_contains 'server: "127.0.0.1"' "$CONFIG_FILE"
assert_contains 'port: 7928' "$CONFIG_FILE"
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
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
assert outbound["server_port"] == 7928
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
OUTBOUND_PORT="7928"
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
OUTBOUND_PORT="7928"
OUTBOUND_USER=""
OUTBOUND_PASS="must-not-be-written"
OUTBOUND_NAME="upstream-out"
OUTBOUND_UDP=true
write_outbound_env
assert_contains 'OUTBOUND_UDP="true"' "$ENV_FILE"
assert_not_contains 'OUTBOUND_PASS=' "$ENV_FILE"

assert_contains 'network_mode: host' "$INSTALLER"
assert_not_contains 'host.docker.internal' "$INSTALLER"

start_mock() {
  local mode="$1" info_file="$TMP_ROOT/mock-$1.info"
  rm -f "$info_file"
  python3 - "$mode" "$info_file" <<'PY' >/dev/null 2>&1 &
import socket
import sys

mode = sys.argv[1]
info_file = sys.argv[2]

def read_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return data
        data += chunk
    return data

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(info_file, "w", encoding="ascii") as handle:
    handle.write(str(server.getsockname()[1]))
conn, _ = server.accept()
with conn:
    if mode == "close":
        raise SystemExit(0)
    if read_exact(conn, 3) != b"\x05\x01\x00":
        raise SystemExit(1)
    if mode == "negotiation-fail":
        conn.sendall(b"\x05\xff")
        raise SystemExit(0)
    conn.sendall(b"\x05\x00")
    if read_exact(conn, 10) != b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00":
        raise SystemExit(1)
    if mode == "rep-fail":
        conn.sendall(b"\x05\x05\x00\x01\x7f\x00\x00\x01\x30\x39")
    elif mode == "truncated":
        conn.sendall(b"\x05\x00")
    else:
        conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x30\x39")
PY
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$info_file" ] && break
    sleep 0.02
  done
  [ -s "$info_file" ] || { echo "mock SOCKS5 server did not start" >&2; exit 1; }
  MOCK_PORT="$(cat "$info_file")"
}

wait_mock() {
  wait "$MOCK_PID" || true
}

expect_check_success() {
  start_mock success
  check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"
  wait_mock
}

expect_check_failure() {
  local mode="$1"
  start_mock "$mode"
  if check_socks5_udp_associate 127.0.0.1 "$MOCK_PORT"; then
    echo "expected SOCKS5 UDP check failure for $mode" >&2
    exit 1
  fi
  wait_mock
}

expect_check_success
expect_check_failure negotiation-fail
expect_check_failure rep-fail
expect_check_failure truncated

REFUSED_PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
if check_socks5_udp_associate 127.0.0.1 "$REFUSED_PORT"; then
  echo "expected connection-refused SOCKS5 UDP check failure" >&2
  exit 1
fi

OUTBOUND_TYPE="socks5"
OUTBOUND_HOST="127.0.0.1"
OUTBOUND_PORT="7928"
OUTBOUND_UDP=true
OUTBOUND_GATEVPN=true
if printf 'n\n' | precheck_gatevpn; then
  echo "failed GateVPN precheck must not be accepted by default" >&2
  exit 1
fi
[ "$OUTBOUND_TYPE" = "socks5" ]
[ "$OUTBOUND_UDP" = true ]

echo "outbound SOCKS5 UDP regression tests passed"
