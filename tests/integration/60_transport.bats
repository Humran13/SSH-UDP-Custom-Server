#!/usr/bin/env bats
# Transport-level tests through the real project firewall path.
#
# HONEST SCOPE: the upstream "udp-custom" core speaks a private, closed protocol
# that only the proprietary HTTP Custom app implements completely. What is tested
# here with the open-source Hysteria v1 client (same QUIC/TLS/obfuscation layers):
#   - packets sent to a port inside the configured range are redirected by OUR
#     rules to the core, and the obfuscated QUIC/TLS handshake completes;
#   - excluded/out-of-range ports are NOT captured;
#   - the core, not our code, answers (wrong ALPN -> TLS alert from the core).
# The application-level login of the real app is NOT reproducible here. The
# "REFERENCE" tests use a stock Hysteria v1 *server* (not the upstream binary) to
# prove that our sshd tunnel-account policy works when SSH rides a QUIC/UDP relay.
load helpers

HY=/src/tests/fixtures/hy-client

setup_file() {
  if [ ! -x "$HY" ]; then return 0; fi
  clean_slate
  mock_release 1.0.0 --latest
  install_quick >/dev/null 2>&1
  ip netns del cli 2>/dev/null || true
  ip link del vth0 2>/dev/null || true
  ip netns add cli
  ip link add vth0 type veth peer name vth1
  ip link set vth1 netns cli
  ip addr add 10.99.0.1/24 dev vth0
  ip link set vth0 up
  ip netns exec cli ip addr add 10.99.0.2/24 dev vth1
  ip netns exec cli ip link set vth1 up
  ip netns exec cli ip link set lo up
}

teardown_file() {
  ip netns del cli 2>/dev/null || true
  ip link del vth0 2>/dev/null || true
  pkill -f 'hy-client server' 2>/dev/null || true
}

need_hy() { [ -x "$HY" ] || skip "hysteria v1 client fixture not built (tests/fixtures/hy-client)"; }

# probe HOST_PORT [ALPN] [OBFS]  -> prints the client's debug log
probe() {
  local target="$1" alpn="${2:-h3}" obfs="${3-2023@ePro.Dev.Team}"
  cat >/tmp/probe.json <<EOF
{"server":"$target","protocol":"udp","up_mbps":50,"down_mbps":50,"obfs":"$obfs","alpn":"$alpn","auth_str":"probe:probe","insecure":true,"handshake_timeout":4,
 "relay_tcp":{"listen":"127.0.0.1:2299","remote":"127.0.0.1:22"}}
EOF
  QUIC_GO_LOG_LEVEL=debug timeout 6 ip netns exec cli "$HY" client -c /tmp/probe.json 2>&1 || true
}

@test "a port inside the configured range reaches the core through our redirect (QUIC/TLS handshake completes)" {
  need_hy
  out="$(probe 10.99.0.1:25000)"
  [[ "$out" == *"HandshakeDoneFrame"* ]]
  [[ "$out" == *"Installed 1-RTT"* ]]
}

@test "the redirect counters increase (traffic really took the range-redirect path)" {
  need_hy
  n="$(nft list table inet sshudp | awk '/redirect to/ { for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i + 1); exit } }')"
  [ "${n:-0}" -gt 0 ]
}

@test "the direct listen port also works" {
  need_hy
  out="$(probe 10.99.0.1:36712)"
  [[ "$out" == *"HandshakeDoneFrame"* ]]
}

@test "the answer comes from the upstream core: a wrong ALPN is refused by its TLS stack" {
  need_hy
  out="$(probe 10.99.0.1:25001 hysteria)"
  [[ "$out" == *"no application protocol"* ]]
}

@test "without the transport's obfuscation parameter nothing answers" {
  need_hy
  out="$(probe 10.99.0.1:25002 h3 wrong-key)"
  [[ "$out" != *"HandshakeDoneFrame"* ]]
}

@test "an EXCLUDED port (53) is not captured" {
  need_hy
  out="$(probe 10.99.0.1:53)"
  [[ "$out" != *"HandshakeDoneFrame"* ]]
}

@test "a port OUTSIDE the range (19999) is not captured" {
  need_hy
  out="$(probe 10.99.0.1:19999)"
  [[ "$out" != *"HandshakeDoneFrame"* ]]
}

@test "after 'sshudp stop' the range no longer reaches the core; after 'start' it does again" {
  need_hy
  sshudp stop >/dev/null
  out="$(probe 10.99.0.1:25000)"
  [[ "$out" != *"HandshakeDoneFrame"* ]]
  sshudp start >/dev/null
  wait_for 10 udp_listening 36712
  out="$(probe 10.99.0.1:25000)"
  [[ "$out" == *"HandshakeDoneFrame"* ]]
}

@test "changing the range at runtime moves the captured ports" {
  need_hy
  sshudp config udp-ports 30000-30100 >/dev/null
  out="$(probe 10.99.0.1:30050)"
  [[ "$out" == *"HandshakeDoneFrame"* ]]
  out="$(probe 10.99.0.1:25000)"
  [[ "$out" != *"HandshakeDoneFrame"* ]]
  sshudp config udp-ports 20000-50000 >/dev/null
}

# ------------------------------------------------------------- REFERENCE
@test "REFERENCE (stock Hysteria v1 server, not the upstream core): SSH tunnel account works over a QUIC/UDP relay, data intact" {
  need_hy
  ensure_web
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/ref.key -out /tmp/ref.crt -days 2 -subj /CN=ref >/dev/null 2>&1
  cat >/tmp/ref-server.json <<EOF
{"listen":":36990","protocol":"udp","cert":"/tmp/ref.crt","key":"/tmp/ref.key","obfs":"ref-obfs","alpn":"h3","auth_str":"ref-auth","up_mbps":100,"down_mbps":100}
EOF
  bg "$HY" server -c /tmp/ref-server.json
  run sshudp create-user demo --days 5
  pw="$(echo "$output" | pw_from_card)"
  cat >/tmp/ref-client.json <<EOF
{"server":"127.0.0.1:36990","protocol":"udp","up_mbps":100,"down_mbps":100,"obfs":"ref-obfs","alpn":"h3","auth_str":"ref-auth","insecure":true,
 "relay_tcp":{"listen":"127.0.0.1:2298","remote":"127.0.0.1:22"}}
EOF
  bg "$HY" client -c /tmp/ref-client.json
  wait_for 15 bash -c 'ss -ltn | grep -q ":2298 "'
  # SSH through the relay (client -> UDP/QUIC -> server -> sshd)
  sshpass -p "$pw" ssh $SO -p 2298 -N -L 18097:127.0.0.1:8080 demo@127.0.0.1 3>&- &
  spid=$!
  wait_for 15 bash -c 'curl -fs http://127.0.0.1:18097/probe.txt | grep -q SSH_UDP_TEST_OK'
  want="$(sha256sum /tmp/web/blob.bin | cut -d' ' -f1)"
  got="$(curl -fs http://127.0.0.1:18097/blob.bin | sha256sum | cut -d' ' -f1)"
  kill "$spid" 2>/dev/null || true
  [ "$want" = "$got" ]
  # the account still cannot run commands through the relay
  run sshpass -p "$pw" ssh $SO -p 2298 demo@127.0.0.1 'echo SHOULD_NOT_RUN'
  [[ "$output" != *SHOULD_NOT_RUN* ]]
}

@test "REFERENCE negative control: with the UDP relay server stopped, the same SSH attempt fails (so traffic really used UDP)" {
  need_hy
  pkill -f 'hy-client server' || true
  sleep 1
  pw="$(sshudp reset-password demo | pw_from_card)"
  run timeout 15 sshpass -p "$pw" ssh $SO -o ConnectTimeout=6 -p 2298 demo@127.0.0.1 true
  [ "$status" -ne 0 ]
  pkill -f 'hy-client client' || true
}
