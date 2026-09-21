#!/usr/bin/env bats
# Account management, expiry, session limits and isolation from non-managed users.
load helpers

setup_file() {
  clean_slate
  mock_release 1.0.0 --latest
  SSHUDP_RELEASE_BASE="$REL_URL" bash "$SRC/install.sh" --quick >/dev/null 2>&1
  make_admin admin1
  ensure_web
}

@test "create-user with generated password shows a client card once" {
  run sshudp create-user demo --days 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH UDP CUSTOM ACCOUNT"* ]]
  [[ "$output" == *"Username   : demo"* ]]
  [[ "$output" == *"Save the password now"* ]]
  echo "$output" | pw_from_card >/tmp/demo.pw
  [ "$(wc -c </tmp/demo.pw)" -ge 14 ]
}

@test "account is a locked-down tunnel account: nologin shell, own group, no sudo/admin groups" {
  [ "$(getent passwd demo | cut -d: -f7)" = "/usr/sbin/nologin" ]
  [ "$(id -gn demo)" = "sshudp-users" ]
  ! id -nG demo | grep -Eq '\b(sudo|adm|root|wheel|shadow|docker)\b'
  ! sudo -l -U demo 2>/dev/null | grep -q 'may run'
  [ ! -d "$(getent passwd demo | cut -d: -f6)" ]
}

@test "metadata is stored separately, root-only, without any password" {
  f=/var/lib/ssh-udp-custom/users/demo.meta
  [ "$(stat -c %a:%U "$f")" = "600:root" ]
  grep -q '^EXPIRES=' "$f"
  ! grep -qi 'pass\|hash' "$f"
}

@test "OS-level account expiry is set as a second line of defence" {
  exp="$(grep '^EXPIRES=' /var/lib/ssh-udp-custom/users/demo.meta | cut -d= -f2)"
  os="$(chage -l demo | awk -F': ' '/Account expires/ { print $2 }')"
  [ "$(date -d "$os" +%F)" = "$(date -d "$exp +1 day" +%F)" ]
}

@test "the account works: password login, port forwarding, data integrity (sha256)" {
  tunnel_ok demo "$(cat /tmp/demo.pw)"
}

@test "the account cannot get a shell, run commands or allocate a TTY" {
  run sshpass -p "$(cat /tmp/demo.pw)" ssh $SO demo@127.0.0.1 'echo SHOULD_NOT_RUN'
  [[ "$output" != *SHOULD_NOT_RUN* ]]
  [[ "$output" == *"not available"* ]]
  run sshpass -p "$(cat /tmp/demo.pw)" ssh $SO -tt demo@127.0.0.1
  [[ "$output" == *"PTY allocation request failed"* || "$output" == *"not available"* ]]
}

@test "a wrong password is rejected" {
  login_fails demo wrongpassword123
}

@test "the plaintext password never appears on disk, in the journal or in the process list" {
  pw="$(cat /tmp/demo.pw)"
  ! grep -rqF "$pw" /var/lib/ssh-udp-custom /etc/ssh-udp-custom /var/backups/ssh-udp-custom 2>/dev/null
  ! journalctl --no-pager 2>/dev/null | grep -qF "$pw"
  ! ps -eo args | grep -F "$pw" | grep -qv grep
}

@test "duplicate username is rejected" {
  run sshudp create-user demo --days 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "an existing NON-managed system user cannot be taken over by create-user" {
  run sshudp create-user admin1 --days 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(getent passwd admin1 | cut -d: -f7)" = "/bin/bash" ]
}

@test "invalid usernames are rejected without side effects" {
  for bad in 'Bad;name' 'x$(id)' 'a' 'root' 'UPPER' '../etc' 'two words' 'nl'$'\n''x'; do
    run sshudp create-user "$bad" --days 5
    [ "$status" -ne 0 ]
  done
  ! getent passwd 'Bad;name'
  [ ! -e /var/lib/ssh-udp-custom/users/a.meta ]
}

@test "invalid validity values are rejected" {
  for bad in 0 -1 99999 abc 2020-01-01 2026-13-40 '5;id'; do
    run sshudp create-user gen1 --days "$bad"
    [ "$status" -ne 0 ]
    ! getent passwd gen1
  done
}

@test "passwords on the command line are refused (they would leak via ps)" {
  run sshudp create-user gen1 --password Secret12345 --days 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"not accepted on the command line"* ]]
  ! getent passwd gen1
}

@test "own password via stdin works and a weak/invalid one is rejected" {
  run bash -c "printf 'MyOwnPass123\n' | sshudp create-user stdin1 --password-stdin --days 5"
  [ "$status" -eq 0 ]
  tunnel_ok stdin1 MyOwnPass123 18082
  run bash -c "printf 'short\n' | sshudp create-user gen1 --password-stdin --days 5"
  [ "$status" -ne 0 ]
  run bash -c "printf 'has space in it\n' | sshudp create-user gen1 --password-stdin --days 5"
  [ "$status" -ne 0 ]
  ! getent passwd gen1
}

@test "explicit expiry date is accepted; past date rejected" {
  run sshudp create-user gen1 --expires 2099-01-01
  [ "$status" -eq 0 ]
  grep -q '^EXPIRES=2099-01-01' /var/lib/ssh-udp-custom/users/gen1.meta
  sshudp delete-user gen1 --yes
  run sshudp create-user gen1 --expires 2020-01-01
  [ "$status" -ne 0 ]
}

@test "lock blocks login (and kills sessions); unlock restores it" {
  pw="$(cat /tmp/demo.pw)"
  run sshudp lock-user demo
  [ "$status" -eq 0 ]
  login_fails demo "$pw"
  sshudp users | grep -E '^demo +locked'
  run sshudp unlock-user demo
  [ "$status" -eq 0 ]
  tunnel_ok demo "$pw"
}

@test "renew extends from the current expiry" {
  before="$(grep '^EXPIRES=' /var/lib/ssh-udp-custom/users/demo.meta | cut -d= -f2)"
  run sshudp renew-user demo 10
  [ "$status" -eq 0 ]
  after="$(grep '^EXPIRES=' /var/lib/ssh-udp-custom/users/demo.meta | cut -d= -f2)"
  [ "$after" = "$(date -d "$before +10 days" +%F)" ]
}

@test "automatic expiry: the systemd service locks expired managed users only" {
  run sshudp create-user exp1 --days 3
  echo "$output" | pw_from_card >/tmp/exp1.pw
  # make exp1 expired yesterday (metadata AND OS-level expiry stay consistent for the test)
  sed -i "s/^EXPIRES=.*/EXPIRES=$(date -d yesterday +%F)/" /var/lib/ssh-udp-custom/users/exp1.meta
  passwd_before="$(passwd -S admin1)"
  systemctl start ssh-udp-custom-expiry.service
  [ "$(passwd -S exp1 | awk '{ print $2 }')" = "L" ]
  grep -q '^STATUS=expired' /var/lib/ssh-udp-custom/users/exp1.meta
  login_fails exp1 "$(cat /tmp/exp1.pw)"
  # untouched: the healthy managed user and the unrelated administrator
  [ "$(passwd -S demo | awk '{ print $2 }')" = "P" ]
  [ "$(passwd -S admin1)" = "$passwd_before" ]
  journalctl -t sshudp --no-pager | grep -q 'user expired and locked: exp1'
}

@test "unlock refuses an expired user; renew reactivates it" {
  run sshudp unlock-user exp1
  [ "$status" -ne 0 ]
  [[ "$output" == *"expired"* ]]
  run sshudp renew-user exp1 5
  [ "$status" -eq 0 ]
  tunnel_ok exp1 "$(cat /tmp/exp1.pw)" 18083
}

@test "the expiry timer is scheduled daily and persistent" {
  systemctl cat ssh-udp-custom-expiry.timer | grep -q 'OnCalendar=daily'
  systemctl cat ssh-udp-custom-expiry.timer | grep -q 'Persistent=true'
  systemctl list-timers --no-legend | grep -q ssh-udp-custom-expiry
}

@test "cleanup-expired --delete removes only expired managed users" {
  sed -i "s/^EXPIRES=.*/EXPIRES=$(date -d yesterday +%F)/" /var/lib/ssh-udp-custom/users/exp1.meta
  run sshudp cleanup-expired --delete
  [ "$status" -eq 0 ]
  ! getent passwd exp1
  [ ! -e /var/lib/ssh-udp-custom/users/exp1.meta ]
  getent passwd demo
  getent passwd admin1
}

@test "isolation: non-managed users cannot be locked, renewed, deleted or shown" {
  for c in "lock-user admin1" "unlock-user admin1" "renew-user admin1 5" "delete-user admin1 --yes" "user-info admin1"; do
    run sshudp $c
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a user managed by sshudp"* ]]
  done
  getent passwd admin1
  [ "$(passwd -S admin1 | awk '{ print $2 }')" = "P" ]
}

@test "isolation: forged metadata for a normal user does not make it managed" {
  uid="$(id -u admin1)"
  printf 'USERNAME=admin1\nUID=%s\nCREATED=2026-01-01\nEXPIRES=2020-01-01\nSTATUS=active\nMAXLOGINS=0\n' "$uid" >/var/lib/ssh-udp-custom/users/admin1.meta
  chmod 600 /var/lib/ssh-udp-custom/users/admin1.meta
  run sshudp cleanup-expired
  [ "$status" -eq 0 ]
  [ "$(passwd -S admin1 | awk '{ print $2 }')" = "P" ]
  run sshudp delete-user admin1 --yes
  [ "$status" -ne 0 ]
  getent passwd admin1
  rm -f /var/lib/ssh-udp-custom/users/admin1.meta
}

@test "isolation: metadata whose UID no longer matches (reused name) is not managed" {
  sshudp create-user bob --days 5 >/dev/null
  sed -i 's/^UID=.*/UID=4242/' /var/lib/ssh-udp-custom/users/bob.meta
  run sshudp delete-user bob --yes
  [ "$status" -ne 0 ]
  getent passwd bob
  sed -i "s/^UID=.*/UID=$(id -u bob)/" /var/lib/ssh-udp-custom/users/bob.meta
  sshudp delete-user bob --yes
}

@test "reset-password sets a new working password and invalidates the old one" {
  old="$(cat /tmp/demo.pw)"
  run sshudp reset-password demo
  [ "$status" -eq 0 ]
  new="$(echo "$output" | pw_from_card)"
  [ "$new" != "$old" ]
  login_fails demo "$old"
  tunnel_ok demo "$new"
  echo "$new" >/tmp/demo.pw
}

@test "login limit: excess simultaneous sessions are terminated, the oldest stays" {
  run sshudp create-user lim1 --days 5 --limit 1
  echo "$output" | pw_from_card >/tmp/lim1.pw
  pw="$(cat /tmp/lim1.pw)"
  sshpass -p "$pw" ssh $SO -N -L 18090:127.0.0.1:8080 lim1@127.0.0.1 3>&- &
  sleep 3
  sshpass -p "$pw" ssh $SO -N -L 18091:127.0.0.1:8080 lim1@127.0.0.1 3>&- &
  sleep 3
  [ "$(sshudp online | grep -c '^lim1')" -ge 2 ]
  run sshudp enforce-limits
  sleep 2
  [ "$(sshudp online | grep -c '^lim1')" -eq 1 ]
  pkill -f 'ssh .*lim1@127.0.0.1' || true
}

@test "online view lists connected managed users and marks the transport" {
  pw="$(cat /tmp/demo.pw)"
  sshpass -p "$pw" ssh $SO -N -L 18092:127.0.0.1:8080 demo@127.0.0.1 3>&- &
  sleep 3
  run sshudp online
  pkill -f 'ssh .*demo@127.0.0.1' || true
  [[ "$output" == *"demo"* ]]
  [[ "$output" == *"loopback"* ]]
}

@test "traffic report is service-level and does not fabricate per-user numbers" {
  run sshudp traffic
  [ "$status" -eq 0 ]
  [[ "$output" == *"Per-user traffic is not reported"* ]]
}

@test "delete-user removes the account, its sessions and its metadata" {
  run sshudp delete-user lim1 --yes
  [ "$status" -eq 0 ]
  ! getent passwd lim1
  [ ! -e /var/lib/ssh-udp-custom/users/lim1.meta ]
  getent passwd admin1
}

@test "user listing and search work" {
  run sshudp users
  [[ "$output" == *"demo"* ]]
  run sshudp users emo
  [[ "$output" == *"demo"* ]]
  run sshudp users zzzz
  [[ "$output" != *"demo"* ]]
}

@test "client command shows the card without a password and never a stored secret" {
  run sshudp client demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"not stored"* ]]
  ! echo "$output" | grep -qF "$(cat /tmp/demo.pw)"
}

@test "existing administrator SSH access is unaffected" {
  tmp="$(mktemp)"
  run sshpass -p AdminPass123 ssh $SO admin1@127.0.0.1 'echo ADMIN_SHELL_OK'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADMIN_SHELL_OK"* ]]
}
