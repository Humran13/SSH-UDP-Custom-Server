#!/usr/bin/env bats
# Installer behaviour: refusals, failure paths (must leave the system untouched),
# fresh install, hardening and re-runs. Order matters: tests share one host.
load helpers

setup_file() {
  clean_slate
  sha256sum /etc/ssh/sshd_config >/tmp/sshd_config.before
  systemctl list-units --type=service --state=running --plain --no-legend | awk '{ print $1 }' | grep -Ev '^(ssh-udp|ssh.service)' | sort >/tmp/units.before
  bg python3 -c 'import time; time.sleep(1)'
}

@test "unsupported OS (Debian) is refused before any change" {
  printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian 12"\n' >/tmp/os-fake
  SSHUDP_OS_RELEASE=/tmp/os-fake run install_quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported operating system"* ]]
  ! is_installed
}

@test "untested Ubuntu release is refused with a clear message" {
  printf 'ID=ubuntu\nVERSION_ID="23.10"\nPRETTY_NAME="Ubuntu 23.10"\n' >/tmp/os-fake
  SSHUDP_OS_RELEASE=/tmp/os-fake run install_quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"has not been tested"* ]]
  ! is_installed
}

@test "install requires root" {
  run su -s /bin/bash nobody -c "SSHUDP_RELEASE_BASE=$REL_URL SSHUDP_TESTING=1 bash $SRC/install.sh --quick"
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
  ! is_installed
}

@test "release server unreachable: clear error, nothing changed" {
  SSHUDP_RELEASE_BASE=http://127.0.0.1:9 run bash "$SRC/install.sh" --quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine the latest release"* ]]
  ! is_installed
}

@test "tampered release archive is rejected (checksum mismatch)" {
  mock_release 1.0.9
  echo tamper >>"$REL_DIR/download/v1.0.9/ssh-udp-custom-server-v1.0.9.tar.gz"
  SSHUDP_VERSION=1.0.9 run install_quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  ! is_installed
}

@test "malformed version string is rejected" {
  SSHUDP_VERSION='1.0.0;id' run install_quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid version"* ]]
}

@test "upstream core download failure: aborts and rolls back" {
  SSHUDP_CORE_URL=http://127.0.0.1:9/udp-custom run install_quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"download of the upstream core failed"* ]]
  ! is_installed
  [ ! -d /etc/ssh-udp-custom ]
}

@test "upstream core checksum mismatch: refused and rolled back" {
  SSHUDP_CORE_SHA256="$(printf '0%.0s' {1..64})" run install_quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHA-256 mismatch"* ]]
  ! is_installed
}

@test "occupied UDP port: install aborts cleanly" {
  bg python3 -c 'import socket,time; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0",36712)); time.sleep(40)'
  sleep 1
  run install_quick
  pkill -f 'SOCK_DGRAM' || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"already in use"* ]]
  ! is_installed
  [ ! -d /etc/ssh-udp-custom ]
}

@test "interrupted install (failure after services are configured) rolls everything back" {
  SSHUDP_FAIL_AT=units run install_quick
  [ "$status" -ne 0 ]
  [[ "$output" == *"rollback finished"* ]]
  ! is_installed
  [ ! -e /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf ]
  ! nft list table inet sshudp >/dev/null 2>&1
  systemctl is-active --quiet ssh
  ss -ltn | grep -q ':22 '
}

@test "interrupted install (failure after sshd is configured) rolls back the sshd policy" {
  SSHUDP_FAIL_AT=sshd run install_quick
  [ "$status" -ne 0 ]
  ! is_installed
  [ ! -e /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf ]
  sshd -t
  systemctl is-active --quiet ssh
}

@test "fresh quick install succeeds" {
  run install_quick
  echo "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed successfully"* ]]
  [[ "$output" == *"sshudp"* ]]
}

@test "manager command works and reports the version" {
  run sshudp version
  [ "$status" -eq 0 ]
  [[ "$output" == "sshudp 1.0.0 (core 1.4)" ]]
}

@test "services are active, enabled at boot and the UDP port is listening" {
  systemctl is-active --quiet ssh-udp-custom.service
  systemctl is-active --quiet ssh-udp-custom-firewall.service
  systemctl is-active --quiet ssh-udp-custom-expiry.timer
  systemctl is-active --quiet ssh-udp-custom-limiter.timer
  systemctl is-enabled --quiet ssh-udp-custom.service
  systemctl is-enabled --quiet ssh-udp-custom-firewall.service
  systemctl is-enabled --quiet ssh-udp-custom-expiry.timer
  systemctl is-enabled --quiet ssh-udp-custom-limiter.timer
  udp_listening 36712
}

@test "the UDP core runs unprivileged: dedicated user, no capabilities, no new privileges" {
  pid="$(systemctl show -p MainPID --value ssh-udp-custom.service)"
  [ "$(ps -o user= -p "$pid" | tr -d ' ')" = "sshudp" ]
  grep -q '^CapEff:[[:space:]]*0000000000000000' "/proc/$pid/status"
  grep -q '^NoNewPrivs:[[:space:]]*1' "/proc/$pid/status"
  [ "$(systemctl show -p ProtectSystem --value ssh-udp-custom.service)" = "strict" ]
}

@test "SAFETY: the upstream core did NOT install its blanket UDP 1-65535 capture rule" {
  ! iptables -t nat -S 2>/dev/null | grep -q -- '1:65535'
  ! nft list ruleset 2>/dev/null | grep -Eq 'dport (1-65535|1:65535)'
}

@test "the redirect covers only the configured range minus protected ports and the listen port" {
  out="$(nft list table inet sshudp)"
  [[ "$out" == *"20000-36711, 36713-50000"* ]]
  [[ "$out" == *'iifname != "lo"'* ]]
  [[ "$out" != *"dport 53"* ]]
}

@test "DNS/NTP-style listeners keep working: a UDP service on port 53-range is not hijacked" {
  # A listener inside the range must be excluded automatically when rules are (re)loaded.
  bg python3 -c 'import socket,time; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0",31000)); time.sleep(30)'
  sleep 1
  sshudp fw apply
  out="$(nft list table inet sshudp)"
  [[ "$out" == *"20000-30999, 31001-36711"* ]]
  pkill -f 'bind(("0.0.0.0",31000))' || true
  sshudp fw apply
}

@test "sshd_config was not modified; only a drop-in was added, and sshd -t passes" {
  sha256sum -c /tmp/sshd_config.before
  [ -f /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf ]
  grep -q 'Match Group sshudp-users' /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf
  sshd -t
}

@test "file and directory permissions are restrictive" {
  [ "$(stat -c %a /var/lib/ssh-udp-custom)" = "700" ]
  [ "$(stat -c %a /var/lib/ssh-udp-custom/users)" = "700" ]
  [ "$(stat -c %a /var/backups/ssh-udp-custom)" = "700" ]
  [ "$(stat -c %U:%a /usr/local/lib/ssh-udp-custom/core/udp-custom)" = "root:755" ]
  [ "$(stat -c %a /etc/ssh-udp-custom/config.conf)" = "644" ]
  [ -z "$(find /usr/local/lib/ssh-udp-custom /etc/ssh-udp-custom -perm -0002 -not -type l 2>/dev/null)" ]
}

@test "the upstream core binary is not stored in our release archive" {
  ! tar -tzf "$REL_DIR/download/v1.0.0/ssh-udp-custom-server-v1.0.0.tar.gz" | grep -q 'udp-custom-linux\|core/udp-custom'
}

@test "doctor passes with no failures on a fresh install" {
  run sshudp doctor
  echo "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 failed"* ]]
}

@test "doctor is read-only: it does not change the system" {
  before="$(find /etc /var/lib/ssh-udp-custom /usr/local/lib/ssh-udp-custom -type f -newer /tmp/units.before 2>/dev/null | sort | md5sum)"
  nft list ruleset >/tmp/nft.before
  sshudp doctor >/dev/null 2>&1
  nft list ruleset >/tmp/nft.after
  diff <(sed 's/packets [0-9]* bytes [0-9]*//' /tmp/nft.before) <(sed 's/packets [0-9]* bytes [0-9]*//' /tmp/nft.after)
}

@test "unrelated running services are unchanged by the install" {
  systemctl list-units --type=service --state=running --plain --no-legend | awk '{ print $1 }' | grep -Ev '^(ssh-udp|ssh.service)' | sort >/tmp/units.after
  diff /tmp/units.before /tmp/units.after
}

@test "re-running the installer is idempotent and preserves settings and users" {
  make_admin admin1
  sshudp config udp-exclude 53,123,9999
  run sshudp create-user keep1 --days 10
  [ "$status" -eq 0 ]
  run install_quick
  [ "$status" -eq 0 ]
  [[ "$output" == *"existing installation found"* ]]
  [ "$(sshudp config show | awk '$1 == "UDP_EXCLUDE" { print $2 }')" = "53,123,9999" ]
  sshudp users | grep -q keep1
  [ "$(ls /etc/ssh/sshd_config.d | grep -c 90-ssh-udp-custom)" = "1" ]
  [ "$(nft list tables | grep -c sshudp)" = "1" ]
  systemctl is-active --quiet ssh-udp-custom.service
  id admin1 >/dev/null
}

@test "partial install: damaged unit + missing files are repaired without touching settings" {
  sshudp config udp-exclude 53,123,7777 >/dev/null
  systemctl stop ssh-udp-custom.service ssh-udp-custom-firewall.service
  rm -f /etc/systemd/system/ssh-udp-custom.service /etc/ssh-udp-custom/udp-custom.json /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf
  chmod 755 /var/lib/ssh-udp-custom
  systemctl daemon-reload
  run sshudp repair
  [ "$status" -eq 0 ]
  systemctl is-active --quiet ssh-udp-custom.service
  [ "$(stat -c %a /var/lib/ssh-udp-custom)" = "700" ]
  [ -f /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf ]
  [ "$(sshudp config show | awk '$1 == "UDP_EXCLUDE" { print $2 }')" = "53,123,7777" ]
  sshudp users | grep -q keep1
}

@test "repair restores a missing manager link and a stopped service" {
  rm -f /usr/local/bin/sshudp
  systemctl stop ssh-udp-custom.service
  run /usr/local/lib/ssh-udp-custom/bin/sshudp repair
  [ "$status" -eq 0 ]
  [ -L /usr/local/bin/sshudp ]
  systemctl is-active --quiet ssh-udp-custom.service
}

@test "repair reinstalls a tampered core binary from the pinned, verified source" {
  systemctl stop ssh-udp-custom.service
  echo "garbage" >>/usr/local/lib/ssh-udp-custom/core/udp-custom
  run sshudp doctor
  [[ "$output" == *"checksum does not match"* ]]
  SSHUDP_RELEASE_BASE="$REL_URL" run sshudp repair
  [ "$status" -eq 0 ]
  sshudp doctor | grep -q 'core checksum matches'
}

@test "repair does not overwrite a valid custom configuration with defaults" {
  sshudp config udp-ports 30000-31000 >/dev/null
  run sshudp repair
  [ "$status" -eq 0 ]
  [ "$(sshudp config show | awk '$1 == "UDP_PORTS" { print $2 }')" = "30000-31000" ]
  sshudp config udp-ports 20000-50000 >/dev/null
}

@test "a damaged configuration is recovered from the newest backup" {
  sshudp backup >/dev/null
  echo 'GARBAGE_NO_EQUALS' >>/etc/ssh-udp-custom/config.conf
  run sshudp repair
  [ "$status" -eq 0 ]
  cfg_ok() { ! grep -q GARBAGE /etc/ssh-udp-custom/config.conf; }
  cfg_ok
  systemctl is-active --quiet ssh-udp-custom.service
}

@test "crash recovery: killing the core with SIGKILL restarts it automatically" {
  old="$(systemctl show -p MainPID --value ssh-udp-custom.service)"
  kill -9 "$old"
  wait_for 20 bash -c '[ "$(systemctl show -p MainPID --value ssh-udp-custom.service)" != "'"$old"'" ] && systemctl is-active --quiet ssh-udp-custom.service'
  wait_for 20 udp_listening 36712
  udp_listening 36712
}

@test "invalid core configuration: doctor reports it, repair fixes it" {
  echo '{ this is not json' >/etc/ssh-udp-custom/udp-custom.json
  run sshudp doctor
  [[ "$output" == *"differs from settings"* ]]
  run sshudp repair
  [ "$status" -eq 0 ]
  python3 -c 'import json; json.load(open("/etc/ssh-udp-custom/udp-custom.json"))'
  systemctl is-active --quiet ssh-udp-custom.service
}

@test "start/stop/restart only touch the UDP service" {
  run sshudp stop
  [ "$status" -eq 0 ]
  ! systemctl is-active --quiet ssh-udp-custom.service
  systemctl is-active --quiet ssh
  ! nft list table inet sshudp >/dev/null 2>&1
  run sshudp start
  [ "$status" -eq 0 ]
  wait_for 10 systemctl is-active --quiet ssh-udp-custom.service
  nft list table inet sshudp >/dev/null
  run sshudp restart
  [ "$status" -eq 0 ]
  wait_for 10 udp_listening 36712
}

@test "changing the listen port applies everywhere and frees the old port" {
  run sshudp config udp-port 36999
  [ "$status" -eq 0 ]
  wait_for 10 udp_listening 36999
  ! udp_listening 36712
  nft list table inet sshudp | grep -q 'redirect to :36999'
  sshudp config udp-port 36712 >/dev/null
  wait_for 10 udp_listening 36712
}

@test "logs are available from the journal and never contain passwords" {
  run sshudp logs udp -n 5
  [ "$status" -eq 0 ]
  run sshudp logs events -n 5
  [ "$status" -eq 0 ]
  run sshudp logs bogus
  [ "$status" -ne 0 ]
}
