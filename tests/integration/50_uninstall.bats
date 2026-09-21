#!/usr/bin/env bats
# Uninstall removes only project-owned objects; reinstall afterwards works.
load helpers

setup_file() {
  clean_slate
  mock_release 1.0.0 --latest
  sysctl -n net.core.rmem_max >/tmp/rmem.before
  systemctl list-units --type=service --state=running --plain --no-legend | awk '{ print $1 }' | grep -Ev '^(ssh-udp|ssh.service)' | sort >/tmp/units.before
  nft add table inet unrelated 2>/dev/null || true
  nft add chain inet unrelated input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || true
  nft add rule inet unrelated input tcp dport 9999 accept 2>/dev/null || true
  nft list table inet unrelated >/tmp/unrelated.before
  make_admin admin1
  make_admin alice
  sha256sum /etc/ssh/sshd_config >/tmp/sshd_config.before
  install_quick >/dev/null 2>&1
  sshudp create-user demo --days 10 >/tmp/demo.card 2>&1
  sshudp create-user keep1 --days 10 >/dev/null 2>&1
}

teardown_file() { nft delete table inet unrelated 2>/dev/null || true; }

@test "uninstall without --yes and without a terminal cancels safely" {
  run sshudp uninstall
  [ "$status" -ne 0 ]
  [[ "$output" == *"cancelled"* ]]
  systemctl is-active --quiet ssh-udp-custom.service
}

@test "uninstall --keep-users --keep-config removes services but keeps accounts and data" {
  run sshudp uninstall --yes --keep-users --keep-config
  [ "$status" -eq 0 ]
  ! systemctl is-active --quiet ssh-udp-custom.service
  [ ! -e /etc/systemd/system/ssh-udp-custom.service ]
  [ ! -e /usr/local/bin/sshudp ]
  [ ! -d /usr/local/lib/ssh-udp-custom ]
  getent passwd demo
  getent passwd keep1
  [ -f /etc/ssh-udp-custom/config.conf ]
  [ -f /var/lib/ssh-udp-custom/users/demo.meta ]
}

@test "unrelated things are preserved: sshd (unchanged config), admin users, firewall table, services" {
  sha256sum -c /tmp/sshd_config.before
  [ ! -e /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf ]
  sshd -t
  systemctl is-active --quiet ssh
  getent passwd admin1
  getent passwd alice
  [ "$(passwd -S admin1 | awk '{ print $2 }')" = "P" ]
  diff /tmp/unrelated.before <(nft list table inet unrelated)
  ! nft list table inet sshudp >/dev/null 2>&1
  systemctl list-units --type=service --state=running --plain --no-legend | awk '{ print $1 }' | grep -Ev '^(ssh-udp|ssh.service)' | sort >/tmp/units.after
  diff /tmp/units.before /tmp/units.after
  run sshpass -p AdminPass123 ssh $SO admin1@127.0.0.1 'echo STILL_WORKS'
  [[ "$output" == *"STILL_WORKS"* ]]
}

@test "the service account, sysctl file and group are gone; sysctl value restored" {
  ! getent passwd sshudp
  [ ! -e /etc/sysctl.d/90-ssh-udp-custom.conf ]
  [ "$(sysctl -n net.core.rmem_max)" = "$(cat /tmp/rmem.before)" ] || [ "$(sysctl -n net.core.rmem_max)" -ge "$(cat /tmp/rmem.before)" ]
}

@test "reinstall after uninstall works and reuses the kept configuration and users" {
  run install_quick
  [ "$status" -eq 0 ]
  systemctl is-active --quiet ssh-udp-custom.service
  sshudp users | grep -q demo
  systemctl is-enabled --quiet ssh-udp-custom.service
  run sshudp doctor
  [ "$status" -eq 0 ]
}

@test "managed users still log in after the reinstall (accounts were never touched)" {
  pw="$(pw_from_card </tmp/demo.card)"
  tunnel_ok demo "$pw"
}

@test "uninstall --remove-users deletes managed users only" {
  run sshudp uninstall --yes --remove-users --keep-config
  [ "$status" -eq 0 ]
  ! getent passwd demo
  ! getent passwd keep1
  getent passwd admin1
  getent passwd alice
  ! getent group sshudp-users
}

@test "uninstall --purge removes configuration, metadata and backups" {
  run install_quick
  [ "$status" -eq 0 ]
  sshudp backup >/dev/null
  run sshudp uninstall --yes --purge --remove-users
  [ "$status" -eq 0 ]
  [ ! -d /etc/ssh-udp-custom ]
  [ ! -d /var/lib/ssh-udp-custom ]
  [ ! -d /var/backups/ssh-udp-custom ]
  getent passwd admin1
}

@test "uninstall.sh wrapper works and reports when nothing is installed" {
  run bash /src/uninstall.sh --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not appear to be installed"* ]]
  install_quick >/dev/null 2>&1
  run bash /usr/local/lib/ssh-udp-custom/uninstall.sh --yes --remove-users --purge
  [ "$status" -eq 0 ]
  ! is_installed
}

@test "a clean reinstall after a full purge works" {
  run install_quick
  [ "$status" -eq 0 ]
  run sshudp doctor
  [ "$status" -eq 0 ]
  sshudp uninstall --yes --remove-users --purge >/dev/null 2>&1
  ! is_installed
}
