#!/usr/bin/env bats
load helper
setup() { unit_setup; }
teardown() { unit_teardown; }

# ---------------------------------------------------------------- kv files
@test "kv_get returns default when file is missing" {
  [ "$(kv_get "$TMP/nope" KEY fallback)" = "fallback" ];
}
@test "kv_get reads a value" {
  printf 'A=1\nB=two\n' >"$TMP/f"
  [ "$(kv_get "$TMP/f" B)" = "two" ]
}
@test "kv_get: last assignment wins" {
  printf 'A=1\nA=2\n' >"$TMP/f"
  [ "$(kv_get "$TMP/f" A)" = "2" ]
}
@test "kv_get ignores comments" {
  printf '#A=evil\nA=good\n' >"$TMP/f"
  [ "$(kv_get "$TMP/f" A)" = "good" ]
}
@test "kv_get distinguishes empty value from missing key" {
  printf 'A=\n' >"$TMP/f"
  [ "$(kv_get "$TMP/f" A default)" = "" ]
  [ "$(kv_get "$TMP/f" B default)" = "default" ]
}
@test "kv_get keeps '=' inside values" {
  printf 'A=x=y=z\n' >"$TMP/f"
  [ "$(kv_get "$TMP/f" A)" = "x=y=z" ]
}
@test "kv_get never executes command substitutions in values" {
  printf 'A=$(touch %s/pwned)\n' "$TMP" >"$TMP/f"
  v="$(kv_get "$TMP/f" A)"
  [ "$v" = "\$(touch $TMP/pwned)" ]
  [ ! -e "$TMP/pwned" ]
}
@test "kv_set adds and replaces keys" {
  kv_set "$TMP/f" A 1
  kv_set "$TMP/f" B 2
  kv_set "$TMP/f" A 3
  [ "$(kv_get "$TMP/f" A)" = "3" ]
  [ "$(kv_get "$TMP/f" B)" = "2" ]
  [ "$(grep -c '^A=' "$TMP/f")" = "1" ]
}
@test "kv_set rejects newline injection" {
  run kv_set "$TMP/f" A $'1\nEVIL=1'
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/f" ] || ! grep -q EVIL "$TMP/f"
}
@test "kv_set rejects bad key names" {
  run kv_set "$TMP/f" 'a b' 1
  [ "$status" -ne 0 ]
  run kv_set "$TMP/f" 'lower' 1
  [ "$status" -ne 0 ]
}
@test "atomic_write refuses to write through a symlink" {
  ln -s "$TMP/target" "$TMP/link"
  run bash -c "source '$SSHUDP_LIB_HOME/common.sh'; echo data | atomic_write '$TMP/link'"
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/target" ]
}
@test "atomic_write sets the requested mode and leaves no temp files" {
  echo hi | atomic_write "$TMP/out" 0600
  [ "$(stat -c %a "$TMP/out")" = "600" ]
  [ -z "$(find "$TMP" -maxdepth 1 -name '.tmp.*')" ]
}

# ----------------------------------------------------------------- config
@test "cfg_get falls back to built-in defaults" {
  [ "$(cfg_get UDP_LISTEN_PORT)" = "36712" ]
  [ "$(cfg_get UDP_PORTS)" = "20000-50000" ]
  [ "$(cfg_get RUN_AS)" = "sshudp" ]
}
@test "cfg_get unknown key fails" {
  run cfg_get NOT_A_KEY; [ "$status" -ne 0 ];
}
@test "cfg_set validates values" {
  cfg_write_defaults
  run cfg_set UDP_LISTEN_PORT 0
  [ "$status" -ne 0 ]
  run cfg_set UDP_LISTEN_PORT 70000
  [ "$status" -ne 0 ]
  run cfg_set UDP_PORTS 5-1
  [ "$status" -ne 0 ]
  run cfg_set RUN_AS someoneelse
  [ "$status" -ne 0 ]
  run cfg_set FIREWALL_MODE flush
  [ "$status" -ne 0 ]
  run cfg_set SERVER_HOST 'a.com;id'
  [ "$status" -ne 0 ]
  cfg_set UDP_LISTEN_PORT 40000
  [ "$(cfg_get UDP_LISTEN_PORT)" = "40000" ]
}
@test "cfg_set rejects unknown keys" {
  cfg_write_defaults; run cfg_set EVIL 1; [ "$status" -ne 0 ];
}
@test "cfg_get ignores a hostile invalid value in the file" {
  cfg_write_defaults
  printf 'UDP_LISTEN_PORT=1; rm -rf /\n' >>"$SSHUDP_CONF_FILE"
  [ "$(cfg_get UDP_LISTEN_PORT)" = "36712" ]
}
@test "cfg_file_ok accepts a written default file" {
  cfg_write_defaults; cfg_file_ok "$SSHUDP_CONF_FILE";
}
@test "cfg_file_ok rejects unknown keys" {
  cfg_write_defaults; echo 'HACK=1' >>"$SSHUDP_CONF_FILE"; ! cfg_file_ok "$SSHUDP_CONF_FILE";
}
@test "cfg_file_ok rejects lines without '='" {
  cfg_write_defaults; echo 'garbage' >>"$SSHUDP_CONF_FILE"; ! cfg_file_ok "$SSHUDP_CONF_FILE";
}
@test "cfg_file_ok rejects invalid values" {
  cfg_write_defaults; echo 'SSH_PORT=99999' >>"$SSHUDP_CONF_FILE"; ! cfg_file_ok "$SSHUDP_CONF_FILE";
}
@test "cfg_write_defaults produces mode 644" {
  cfg_write_defaults; [ "$(stat -c %a "$SSHUDP_CONF_FILE")" = "644" ];
}
@test "core json is generated only from validated values" {
  cfg_write_defaults
  cfg_set UDP_LISTEN_PORT 40001
  j="$(core_json_render)"
  [[ "$j" == *'"listen": ":40001"'* ]]
  [[ "$j" == *'"mode": "passwords"'* ]]
  [[ "$j" == *'"stream_buffer": 33554432'* ]]
}
@test "core json is valid JSON" {
  cfg_write_defaults
  core_json_render | python3 -c 'import json,sys; json.load(sys.stdin)'
}
@test "server_address prefers hostname over IP" {
  cfg_write_defaults
  cfg_set SERVER_IP 203.0.113.10
  [ "$(server_address)" = "203.0.113.10" ]
  cfg_set SERVER_HOST vpn.example.com
  [ "$(server_address)" = "vpn.example.com" ]
}
@test "detect_public_ipv4 uses fallbacks and validates answers" {
  mkdir -p "$TMP/web"
  echo "not an ip" >"$TMP/web/bad"
  echo "203.0.113.77" >"$TMP/web/good"
  PORT=$((20000 + RANDOM % 5000))
  ( cd "$TMP/web" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 3>&- ) &
  echo $! >"$TMP/pid"
  sleep 1
  SSHUDP_IP_ENDPOINTS="http://127.0.0.1:1/x http://127.0.0.1:$PORT/bad http://127.0.0.1:$PORT/good"
  run detect_public_ipv4
  kill "$(cat "$TMP/pid")" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$output" = "203.0.113.77" ]
}

# --------------------------------------------------------------- platform
mk_os() { printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s"\n' "$1" "$2" "$3" >"$TMP/os-release"; export SSHUDP_OS_RELEASE="$TMP/os-release"; }

@test "platform: Ubuntu 22.04 on x86_64 is accepted" {
  mk_os ubuntu 22.04 "Ubuntu 22.04"; uname() { echo x86_64; }; platform_check;
}
@test "platform: Ubuntu 24.04 accepted" {
  mk_os ubuntu 24.04 x; uname() { echo x86_64; }; platform_check;
}
@test "platform: Ubuntu 20.04 accepted" {
  mk_os ubuntu 20.04 x; uname() { echo x86_64; }; platform_check;
}
@test "platform: Ubuntu 18.04 refused with a clear message" {
  mk_os ubuntu 18.04 x; uname() { echo x86_64; }
  run platform_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"18.04"* ]]
}
@test "platform: untested Ubuntu 23.10 refused" {
  mk_os ubuntu 23.10 x; uname() { echo x86_64; }; run platform_check; [ "$status" -ne 0 ];
}
@test "platform: Debian refused" {
  mk_os debian 12 x; uname() { echo x86_64; }; run platform_check; [ "$status" -ne 0 ]; [[ "$output" == *"Ubuntu"* ]];
}
@test "platform: arm64 refused with explanation" {
  mk_os ubuntu 22.04 x; uname() { echo aarch64; }
  run platform_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"x86_64"* ]]
}
@test "platform: SSHUDP_FORCE_UNSUPPORTED overrides an untested release" {
  mk_os ubuntu 23.10 x; uname() { echo x86_64; }
  SSHUDP_FORCE_UNSUPPORTED=1 run platform_check
  [ "$status" -eq 0 ]
}
@test "platform: FORCE never overrides the CPU architecture check" {
  mk_os ubuntu 22.04 x; uname() { echo aarch64; }
  SSHUDP_FORCE_UNSUPPORTED=1 run platform_check
  [ "$status" -ne 0 ]
}
@test "os_field parses quoted and unquoted values without sourcing" {
  printf 'ID=ubuntu\nVERSION_ID="22.04"\nEVIL=$(touch %s/x)\n' "$TMP" >"$TMP/os-release"
  export SSHUDP_OS_RELEASE="$TMP/os-release"
  [ "$(os_id)" = "ubuntu" ]
  [ "$(os_version)" = "22.04" ]
  [ ! -e "$TMP/x" ]
}
@test "path overrides are ignored outside testing mode" {
  run env -u SSHUDP_TESTING SSHUDP_CONF_DIR=/tmp/evil bash -c "source '$SSHUDP_LIB_HOME/common.sh'; echo \$SSHUDP_CONF_DIR"
  [ "$output" = "/etc/ssh-udp-custom" ]
}
@test "curl protocol is https-only outside testing mode" {
  run env -u SSHUDP_TESTING bash -c "source '$SSHUDP_LIB_HOME/common.sh'; _curl_proto"
  [ "$output" = "=https" ]
}

# ----------------------------------------------------------------- client
@test "client card never contains a stored password and masks nothing it does not have" {
  cfg_write_defaults; cfg_set SERVER_IP 203.0.113.10
  ensure_group() { :; }
  meta_write demo 1001 2026-01-01 2026-02-01 active 0
  is_managed_user() { return 0; }
  out="$(client_show demo)"
  [[ "$out" == *"203.0.113.10"* ]]
  [[ "$out" == *"not stored"* ]]
  [[ "$out" == *"PASSWORD"* ]]
}
@test "client card shows the given password once and warns to save it" {
  cfg_write_defaults; cfg_set SERVER_IP 203.0.113.10
  meta_write demo 1001 2026-01-01 2026-02-01 active 0
  is_managed_user() { return 0; }
  out="$(client_show demo 'S3cretPassw0rd')"
  [[ "$out" == *"S3cretPassw0rd"* ]]
  [[ "$out" == *"Save the password"* ]]
}
@test "client card lines are all the same width (ASCII mode)" {
  cfg_write_defaults; cfg_set SERVER_IP 203.0.113.10
  meta_write demo 1001 2026-01-01 2026-02-01 active 0
  is_managed_user() { return 0; }
  SSHUDP_ASCII=1
  widths="$(client_show demo | grep -E '^[|+]' | awk '{ print length($0) }' | sort -u | wc -l)"
  [ "$widths" -eq 1 ]
}
@test "client card does not invent unsupported fields" {
  cfg_write_defaults; cfg_set SERVER_IP 203.0.113.10
  meta_write demo 1001 2026-01-01 2026-02-01 active 0
  is_managed_user() { return 0; }
  out="$(client_show demo)"
  [[ "$out" != *"SNI"* ]]
  [[ "$out" != *"payload"* ]]
  [[ "$out" != *"vmess://"* ]]
}
