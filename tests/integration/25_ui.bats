#!/usr/bin/env bats
# Dashboard rendering, CLI help/usage behaviour and exit codes (non-interactive).
load helpers

setup_file() {
  clean_slate
  mock_release 1.0.0 --latest
  install_quick >/dev/null 2>&1
  sshudp create-user demo --days 30 >/dev/null 2>&1
}

@test "dashboard shows the live values and all 13 menu entries" {
  run env LANG=C.UTF-8 bash -c 'source /usr/local/lib/ssh-udp-custom/lib/common.sh; for m in validate config platform core firewall service users monitor client doctor backup update repair uninstall extras installer ui; do source /usr/local/lib/ssh-udp-custom/lib/$m.sh; done; ui_dashboard'
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH UDP CUSTOM MANAGER"* ]]
  squeezed="$(printf "%s" "$output" | tr -s " ")"
  [[ "$squeezed" == *"UDP Ports : 20000-50000"* ]]
  [[ "$squeezed" == *"UDP Service : ● ONLINE"* ]]
  [[ "$squeezed" == *"SSH Service : ● ONLINE"* ]]
  [[ "$squeezed" == *"Users : 1"* ]]
  for item in "User Manager" "Online Users" "UDP Configuration" "Client Configuration" "Traffic / Sessions" "Server Settings" "Firewall" "Logs" "Backup / Restore" "Diagnostics" "Update" "Repair" "Uninstall" "0. Exit"; do
    [[ "$output" == *"$item"* ]]
  done
}

@test "dashboard box is perfectly aligned (every line the same width, counted in characters)" {
  n="$(env LANG=C.UTF-8 LC_ALL=C.UTF-8 NO_COLOR=1 bash -c 'source /usr/local/lib/ssh-udp-custom/lib/common.sh; for m in validate config platform core firewall service users monitor client doctor backup update repair uninstall extras installer ui; do source /usr/local/lib/ssh-udp-custom/lib/$m.sh; done; ui_dashboard | while IFS= read -r l; do echo "${#l}"; done | sort -u | wc -l')"
  [ "$n" -eq 1 ]
}

@test "ASCII fallback works without UTF-8" {
  out="$(env LANG=C LC_ALL=C SSHUDP_ASCII=1 NO_COLOR=1 bash -c 'source /usr/local/lib/ssh-udp-custom/lib/common.sh; for m in validate config platform core firewall service users monitor client doctor backup update repair uninstall extras installer ui; do source /usr/local/lib/ssh-udp-custom/lib/$m.sh; done; ui_dashboard')"
  [[ "$out" == *"+----"* ]]
  [[ "$out" == *"* ONLINE"* ]]
  n="$(printf '%s\n' "$out" | awk '{ print length($0) }' | sort -u | wc -l)"
  [ "$n" -eq 1 ]
}

@test "help lists every documented command" {
  run sshudp help
  [ "$status" -eq 0 ]
  for c in status doctor users online create-user delete-user renew-user lock-user unlock-user cleanup-expired config client restart logs backup restore update repair version uninstall udpgw fail2ban core-update; do
    [[ "$output" == *"$c"* ]]
  done
}

@test "unknown commands fail with usage and exit 2" {
  run sshudp frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "root-only commands refuse to run as a normal user" {
  run su -s /bin/bash nobody -c 'sshudp create-user x1y --days 5'
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "config rejects invalid values and unknown keys, and never half-applies them" {
  before="$(cat /etc/ssh-udp-custom/config.conf)"
  for bad in "udp-port 0" "udp-port 70000" "udp-ports 50000-20000" "udp-exclude abc" "ssh-port x" "run-as evil" "firewall-mode flush" "server-host bad_host;id" "bogus 1"; do
    run sshudp config $bad
    [ "$status" -ne 0 ]
  done
  [ "$before" = "$(cat /etc/ssh-udp-custom/config.conf)" ]
}

@test "server host and IP can be configured and appear on the client card" {
  run sshudp config server-host vpn.example.com
  [ "$status" -eq 0 ]
  run sshudp config server-ip 203.0.113.10
  [ "$status" -eq 0 ]
  run sshudp client demo
  [[ "$output" == *"vpn.example.com"* ]]
  [[ "$output" == *"203.0.113.10"* ]]
  [[ "$output" == *"20000-50000"* ]]
}

@test "optional UDPGW: off by default, can be enabled/disabled, loopback only" {
  run sshudp udpgw status
  [[ "$output" == *"Enabled : no"* ]]
  run sshudp udpgw enable 7300
  echo "$output" >&3
  [ "$status" -eq 0 ]
  wait_for 10 bash -c 'ss -ltn | grep -q "127.0.0.1:7300"'
  ! ss -ltn | grep -q '0.0.0.0:7300'
  systemctl is-active --quiet ssh-udp-custom-udpgw.service
  run sshudp udpgw disable
  [ "$status" -eq 0 ]
  ! systemctl is-active --quiet ssh-udp-custom-udpgw.service
  [ ! -e /etc/systemd/system/ssh-udp-custom-udpgw.service ]
}

@test "optional Fail2ban: never forced, ignores loopback and the admin address, validates before enabling" {
  run sshudp fail2ban status
  [ "$status" -eq 0 ]
  [ ! -e /etc/fail2ban/jail.d/ssh-udp-custom.local ]
  export SSHUDP_ASSUME_YES=1
  run env SSH_CONNECTION="198.51.100.7 5555 10.0.0.1 22" SSHUDP_ASSUME_YES=1 sshudp fail2ban enable
  echo "$output" >&3
  [ "$status" -eq 0 ]
  grep -q 'ignoreip = 127.0.0.0/8 ::1 198.51.100.7' /etc/fail2ban/jail.d/ssh-udp-custom.local
  fail2ban-client -t
  run sshudp fail2ban disable
  [ ! -e /etc/fail2ban/jail.d/ssh-udp-custom.local ]
}
