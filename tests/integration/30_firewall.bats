#!/usr/bin/env bats
# Coexistence with UFW / nftables / iptables. We may only add and remove OUR objects.
load helpers

setup_file() {
  clean_slate
  ufw --force disable >/dev/null 2>&1 || true
  mock_release 1.0.0 --latest
}

teardown_file() {
  ufw --force disable >/dev/null 2>&1 || true
  iptables -D INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || true
  iptables -t nat -D PREROUTING -p tcp --dport 8080 -j REDIRECT --to-ports 80 2>/dev/null || true
  nft delete table inet unrelated 2>/dev/null || true
}

@test "existing nftables ruleset: only our table is added and later removed" {
  nft add table inet unrelated
  nft add chain inet unrelated input '{ type filter hook input priority 0; policy accept; }'
  nft add rule inet unrelated input tcp dport 9999 accept
  nft list table inet unrelated >/tmp/unrelated.before
  run install_quick
  [ "$status" -eq 0 ]
  nft list table inet sshudp >/dev/null
  diff /tmp/unrelated.before <(nft list table inet unrelated)
}

@test "the manager never flushes rulesets: an unrelated table survives fw remove/apply/restart" {
  sshudp fw remove
  diff /tmp/unrelated.before <(nft list table inet unrelated)
  sshudp fw apply
  sshudp restart
  diff /tmp/unrelated.before <(nft list table inet unrelated)
}

@test "the firewall unit re-creates our rules at boot (stop/start cycle) and removes them on stop" {
  systemctl stop ssh-udp-custom-firewall.service
  ! nft list table inet sshudp >/dev/null 2>&1
  nft list table inet unrelated >/dev/null
  systemctl start ssh-udp-custom-firewall.service
  nft list table inet sshudp >/dev/null
}

@test "iptables backend: own chains only; unrelated INPUT and nat rules are preserved" {
  iptables -A INPUT -p tcp --dport 8443 -j ACCEPT
  iptables -t nat -A PREROUTING -p tcp --dport 8080 -j REDIRECT --to-ports 80
  iptables-save -t filter | grep -c 'dport 8443' >/tmp/ipt.count
  run sshudp config firewall-mode iptables
  [ "$status" -eq 0 ]
  ! nft list table inet sshudp >/dev/null 2>&1
  iptables -t nat -S | grep -q 'SSHUDP_PRE'
  iptables -t nat -S SSHUDP_PRE | grep -q 'REDIRECT --to-ports 36712'
  iptables -S INPUT | grep -q -- '-j SSHUDP_IN'
  iptables -S INPUT | grep -q -- '--dport 8443 -j ACCEPT'
  iptables -t nat -S PREROUTING | grep -q -- '--dport 8080 -j REDIRECT --to-ports 80'
  ! iptables -t nat -S | grep -q -- '1:65535'
}

@test "iptables backend: doctor passes and stats are readable" {
  run sshudp doctor
  [ "$status" -eq 0 ]
  run sshudp traffic
  [ "$status" -eq 0 ]
}

@test "iptables backend: removal deletes only our chains" {
  run sshudp fw remove
  [ "$status" -eq 0 ]
  ! iptables -t nat -S | grep -q SSHUDP
  ! iptables -S | grep -q SSHUDP
  iptables -S INPUT | grep -q -- '--dport 8443 -j ACCEPT'
  iptables -t nat -S PREROUTING | grep -q -- '--dport 8080'
  sshudp fw apply
  iptables -t nat -S | grep -q SSHUDP_PRE
}

@test "returning to nftables backend cleans the iptables objects" {
  run sshudp config firewall-mode nft
  [ "$status" -eq 0 ]
  ! iptables -t nat -S | grep -q SSHUDP
  nft list table inet sshudp >/dev/null
}

@test "UFW active: only the listen port rule is added; existing rules and UFW state untouched" {
  systemctl unmask ufw >/dev/null 2>&1 || true
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 8443/tcp >/dev/null
  ufw --force enable >/dev/null
  ufw status | head -1 | grep -qi 'active'
  ufw status numbered >/tmp/ufw.before
  run sshudp fw apply
  [ "$status" -eq 0 ]
  ufw status | grep -qE '^36712/udp +ALLOW'
  ufw status | grep -qE '^22/tcp +ALLOW'
  ufw status | grep -qE '^8443/tcp +ALLOW'
  ufw status | head -1 | grep -qi 'active'
  [ "$(ufw status | grep -c '36712/udp')" -le 2 ]
}

@test "UFW: applying twice does not duplicate the rule" {
  sshudp fw apply
  sshudp fw apply
  [ "$(ufw status | grep -E '^36712/udp +ALLOW' | grep -c ALLOW)" = "1" ]
}

@test "UFW: doctor sees the rule; removing it is detected" {
  run sshudp doctor
  [[ "$output" == *"UFW allows 36712/udp"* ]]
  ufw delete allow 36712/udp >/dev/null
  run sshudp doctor
  [[ "$output" == *"UFW rule for 36712/udp missing"* ]]
  [ "$status" -ne 0 ]
  sshudp fw apply
  run sshudp doctor
  echo "$output" >&3
  [ "$status" -eq 0 ]
}

@test "UFW: a pre-existing identical rule is never deleted by us" {
  sshudp uninstall --yes --remove-users --keep-config >/dev/null 2>&1
  ufw allow 36712/udp >/dev/null
  run install_quick
  [ "$status" -eq 0 ]
  run sshudp uninstall --yes --remove-users --keep-config
  [ "$status" -eq 0 ]
  ufw status | grep -qE '^36712/udp +ALLOW'
  ufw delete allow 36712/udp >/dev/null
}

@test "UFW: uninstall removes only the rule we added and leaves UFW enabled" {
  run install_quick
  [ "$status" -eq 0 ]
  ufw status | grep -qE '^36712/udp +ALLOW'
  run sshudp uninstall --yes --remove-users --purge
  [ "$status" -eq 0 ]
  ! ufw status | grep -q '36712/udp'
  ufw status | grep -qE '^22/tcp +ALLOW'
  ufw status | grep -qE '^8443/tcp +ALLOW'
  ufw status | head -1 | grep -qi 'active'
  ! nft list table inet sshudp >/dev/null 2>&1
  nft list table inet unrelated >/dev/null
}

@test "no usable firewall backend: install still succeeds and doctor explains the gap" {
  ufw --force disable >/dev/null
  run install_quick
  [ "$status" -eq 0 ]
  run sshudp config firewall-mode none
  [ "$status" -eq 0 ]
  ! nft list table inet sshudp >/dev/null 2>&1
  run sshudp doctor
  [[ "$output" == *"Firewall redirect rules"* ]]
  sshudp config firewall-mode auto >/dev/null
}
