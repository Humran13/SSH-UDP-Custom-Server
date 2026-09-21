#!/usr/bin/env bats
# Interactive installer menus, driven through a real pseudo-terminal (util-linux `script`).
load helpers

setup_file() {
  clean_slate
  mock_release 1.0.0 --latest
}

teardown_file() { clean_slate; }

pty() { # pty "<answers>"  - run the bootstrap installer with a controlling terminal
  printf '%b' "$1" | script -qefc "SSHUDP_TESTING=1 SSHUDP_RELEASE_BASE=$REL_URL TERM=dumb NO_COLOR=1 bash $SRC/install.sh" /dev/null
}

@test "menu: choosing 3 (Exit) installs nothing" {
  run pty '3\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Quick Install"* ]]
  [[ "$output" == *"Advanced Install"* ]]
  [[ "$output" == *"Exit"* ]]
  ! is_installed
}

@test "menu: an invalid choice does not install anything either" {
  run pty '9\n'
  ! is_installed
}

@test "Quick Install through the menu (just press Enter) works" {
  run pty '\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed successfully"* ]]
  systemctl is-active --quiet ssh-udp-custom.service
  udp_listening 36712
  [ "$(grep '^INSTALL_MODE=' /etc/ssh-udp-custom/config.conf | cut -d= -f2)" = "quick" ]
  sshudp uninstall --yes --remove-users --purge >/dev/null 2>&1
}

@test "Advanced Install validates every answer (re-prompts on bad input) and applies the good ones" {
  # 2=advanced; SSH port: Enter; listen port: bad then 36800; range: bad then 30000-31000;
  # exclusions: bad then 30500; host: bad then vpn.example.com; IP: 203.0.113.9; fw: auto;
  # login limit: 2; run-as: sshudp; UDPGW: no
  run pty '2\n\n99999\n36800\n50000-20000\n30000-31000\nabc\n30500\nbad_host!\nvpn.example.com\n203.0.113.9\nauto\n2\nsshudp\nno\n'
  echo "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid port"* ]]
  [[ "$output" == *"invalid range list"* ]]
  [[ "$output" == *"invalid port list"* ]]
  [[ "$output" == *"invalid hostname"* ]]
  [[ "$output" == *"installed successfully"* ]]
  wait_for 15 udp_listening 36800
  ! udp_listening 36712
  c=/etc/ssh-udp-custom/config.conf
  [ "$(grep '^UDP_LISTEN_PORT=' $c | cut -d= -f2)" = "36800" ]
  [ "$(grep '^UDP_PORTS=' $c | cut -d= -f2)" = "30000-31000" ]
  [ "$(grep '^UDP_EXCLUDE=' $c | cut -d= -f2)" = "30500" ]
  [ "$(grep '^SERVER_HOST=' $c | cut -d= -f2)" = "vpn.example.com" ]
  [ "$(grep '^SERVER_IP=' $c | cut -d= -f2)" = "203.0.113.9" ]
  [ "$(grep '^DEFAULT_MAXLOGINS=' $c | cut -d= -f2)" = "2" ]
  [ "$(grep '^INSTALL_MODE=' $c | cut -d= -f2)" = "advanced" ]
  out="$(nft list table inet sshudp)"
  [[ "$out" == *"30000-30499, 30501-31000"* ]]
  [[ "$out" == *"redirect to :36800"* ]]
  run sshudp create-user demo --days 3
  [[ "$output" == *"Max logins"* ]]
  [[ "$output" == *"vpn.example.com"* ]]
  sshudp doctor | grep -q '0 failed'
}

@test "advanced settings survive re-running the installer in quick mode" {
  run pty '\n'
  [ "$status" -eq 0 ]
  [ "$(grep '^UDP_LISTEN_PORT=' /etc/ssh-udp-custom/config.conf | cut -d= -f2)" = "36800" ]
  udp_listening 36800
}

@test "no terminal at all (curl | bash in automation): Quick Install is used, nothing blocks" {
  sshudp uninstall --yes --remove-users --purge >/dev/null 2>&1
  run timeout 240 env SSHUDP_TESTING=1 SSHUDP_RELEASE_BASE="$REL_URL" setsid bash "$SRC/install.sh" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed successfully"* ]]
}
