#!/usr/bin/env bats
# Manager updates (upgrade, rollback, tamper resistance) and backup/restore.
load helpers

setup_file() {
  clean_slate
  mock_release 1.0.0 --latest
  SSHUDP_RELEASE_BASE="$REL_URL" bash "$SRC/install.sh" --quick >/dev/null 2>&1
  make_admin admin1
  sshudp create-user keep1 --days 20 >/tmp/keep1.card 2>&1
  pw_from_card </tmp/keep1.card >/tmp/keep1.pw
  export SSHUDP_RELEASE_BASE="$REL_URL"
}

upd() { SSHUDP_RELEASE_BASE="$REL_URL" sshudp update "$@"; }

@test "update --check reports no update when versions match" {
  run upd --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
}

@test "update to the same version is a no-op" {
  run upd --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already up to date"* ]]
}

@test "update --check announces a newer release" {
  mock_release 1.1.0 --latest
  run upd --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"update available: v1.0.0 -> v1.1.0"* ]]
}

@test "tampered release archive: update aborts, nothing changes" {
  mock_release 1.1.5
  echo x >>"$REL_DIR/download/v1.1.5/ssh-udp-custom-server-v1.1.5.tar.gz"
  run upd --version 1.1.5 --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ "$(sshudp version)" = "sshudp 1.0.0 (core 1.4)" ]
  systemctl is-active --quiet ssh-udp-custom.service
}

@test "release with a syntax error is rejected before installation" {
  MOCK_HOOK='echo "if then fi" >> "$1/lib/users.sh"' mock_release 1.1.6
  run upd --version 1.1.6 --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"syntax error"* ]]
  [ "$(sshudp version)" = "sshudp 1.0.0 (core 1.4)" ]
}

@test "successful upgrade: version changes, settings and users preserved, services healthy" {
  sshudp config udp-exclude 53,123,4444 >/dev/null
  run upd --yes
  echo "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated to v1.1.0"* ]]
  [ "$(sshudp version)" = "sshudp 1.1.0 (core 1.4)" ]
  [ "$(sshudp config show | awk '$1 == "UDP_EXCLUDE" { print $2 }')" = "53,123,4444" ]
  sshudp users | grep -q keep1
  tunnel_ok keep1 "$(cat /tmp/keep1.pw)"
  systemctl is-active --quiet ssh-udp-custom.service
  udp_listening 36712
  [ "$(sshudp config show >/dev/null; grep '^INSTALLED_VERSION=' /etc/ssh-udp-custom/config.conf | cut -d= -f2)" = "1.1.0" ]
  ls /var/backups/ssh-udp-custom | grep -q preupdate
}

@test "update keeps the verified core and does not re-download it needlessly" {
  sshudp doctor | grep -q 'core checksum matches'
  [ -x /usr/local/lib/ssh-udp-custom/core/udp-custom ]
}

@test "failed health check after upgrade triggers automatic rollback" {
  MOCK_HOOK='sed -i "s/^post_update() {/post_update() {\n  return 1/" "$1/lib/update.sh"' mock_release 1.2.0 --latest
  run upd --yes
  echo "$output" >&3
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolling back"* ]]
  [[ "$output" == *"rolled back to v1.1.0"* ]]
  [ "$(sshudp version)" = "sshudp 1.1.0 (core 1.4)" ]
  systemctl is-active --quiet ssh-udp-custom.service
  udp_listening 36712
  sshudp users | grep -q keep1
  [ ! -d /usr/local/lib/ssh-udp-custom.failed ]
}

@test "forced health-check failure hook also rolls back" {
  SSHUDP_FAIL_AT=update-health run upd --version 1.2.0 --yes
  [ "$status" -ne 0 ]
  [ "$(sshudp version)" = "sshudp 1.1.0 (core 1.4)" ]
  systemctl is-active --quiet ssh-udp-custom.service
}

@test "downgrade is not offered as an update" {
  mock_release 1.0.5 --latest
  run upd --yes
  [[ "$output" == *"nothing to do"* ]]
  [ "$(sshudp version)" = "sshudp 1.1.0 (core 1.4)" ]
  mock_release 1.1.0 --latest
}

@test "core-update re-fetches and verifies the pinned core, then the service is healthy" {
  run sshudp core-update
  [ "$status" -eq 0 ]
  systemctl is-active --quiet ssh-udp-custom.service
  sshudp doctor | grep -q 'core checksum matches'
}

# ------------------------------------------------------------ backup/restore
@test "backup creates a timestamped 0600 archive without shadow data or keys" {
  run sshudp backup
  [ "$status" -eq 0 ]
  f="$(ls -1t /var/backups/ssh-udp-custom/sshudp-backup-*.tar.gz | head -1)"
  [ "$(stat -c %a "$f")" = "600" ]
  ! tar -tzf "$f" | grep -Eqi 'shadow|passwd|hashes|\.ssh|id_'
  tar -tzf "$f" | grep -q 'users/keep1.meta'
  tar -tzf "$f" | grep -q 'config/config.conf'
}

@test "restore brings back an earlier configuration and keeps a pre-restore safety copy" {
  sshudp backup >/dev/null
  f="$(ls -1t /var/backups/ssh-udp-custom/sshudp-backup-*.tar.gz | head -1)"
  sshudp config udp-exclude 53,123,5555 >/dev/null
  run sshudp restore "$(basename "$f")"
  echo "$output" >&3
  [ "$status" -eq 0 ]
  [ "$(sshudp config show | awk '$1 == "UDP_EXCLUDE" { print $2 }')" = "53,123,4444" ]
  ls /var/backups/ssh-udp-custom | grep -q prerestore
  systemctl is-active --quiet ssh-udp-custom.service
  udp_listening 36712
}

@test "restore rejects a corrupt archive and changes nothing" {
  cp /var/backups/ssh-udp-custom/$(ls -1t /var/backups/ssh-udp-custom | grep '^sshudp-backup' | head -1) /tmp/x.tgz
  head -c 200 /tmp/x.tgz >/var/backups/ssh-udp-custom/sshudp-backup-20250101-000001.tar.gz
  before="$(sha256sum /etc/ssh-udp-custom/config.conf)"
  run sshudp restore sshudp-backup-20250101-000001.tar.gz
  [ "$status" -ne 0 ]
  [ "$before" = "$(sha256sum /etc/ssh-udp-custom/config.conf)" ]
}

@test "restore rejects a malicious archive with path traversal / absolute paths / symlinks" {
  d="$(mktemp -d)"
  mkdir -p "$d/w"
  echo pwn >"$d/w/evil"
  ( cd "$d/w" && tar -czf /var/backups/ssh-udp-custom/sshudp-backup-20250101-000002.tar.gz --transform='s|^evil$|../../../tmp/PWNED|' evil )
  run sshudp restore sshudp-backup-20250101-000002.tar.gz
  [ "$status" -ne 0 ]
  [ ! -e /tmp/PWNED ]
  ln -s /etc/shadow "$d/w/users.meta"
  ( cd "$d/w" && tar -czf /var/backups/ssh-udp-custom/sshudp-backup-20250101-000003.tar.gz users.meta )
  run sshudp restore sshudp-backup-20250101-000003.tar.gz
  [ "$status" -ne 0 ]
  ( cd "$d/w" && tar -czPf /var/backups/ssh-udp-custom/sshudp-backup-20250101-000004.tar.gz --transform="s|^evil\$|/tmp/PWNED2|" evil )
  run sshudp restore sshudp-backup-20250101-000004.tar.gz
  [ "$status" -ne 0 ]
  [ ! -e /tmp/PWNED2 ]
}

@test "restore rejects arbitrary paths and traversal in the file argument" {
  run sshudp restore ../../../etc/passwd
  [ "$status" -ne 0 ]
  run sshudp restore /etc/shadow
  [ "$status" -ne 0 ]
}

@test "restore rejects a backup from an incompatible (newer major) version" {
  d="$(mktemp -d)"
  mkdir -p "$d/config" "$d/users"
  cp /etc/ssh-udp-custom/config.conf "$d/config/"
  printf 'FORMAT=1\nVERSION=9.0.0\nCREATED=2026-01-01T00:00:00Z\nUSERS=0\nHASHES=0\n' >"$d/manifest.conf"
  ( cd "$d" && tar -czf /var/backups/ssh-udp-custom/sshudp-backup-20250101-000005.tar.gz . )
  run sshudp restore sshudp-backup-20250101-000005.tar.gz
  [ "$status" -ne 0 ]
  [[ "$output" == *"newer major"* ]]
}

@test "backup --with-hashes is explicit; a restore on a wiped account brings the same password back" {
  pw="$(cat /tmp/keep1.pw)"
  run sshudp backup --with-hashes
  [ "$status" -eq 0 ]
  f="$(ls -1t /var/backups/ssh-udp-custom/sshudp-backup-*.tar.gz | head -1)"
  [ "$(stat -c %a "$f")" = "600" ]
  tar -tzf "$f" | grep -q 'secrets/hashes.txt'
  userdel keep1
  run sshudp restore "$(basename "$f")"
  [ "$status" -eq 0 ]
  getent passwd keep1
  [ "$(id -gn keep1)" = "sshudp-users" ]
  tunnel_ok keep1 "$pw" 18095
}

@test "backups list only project archives" {
  touch /var/backups/ssh-udp-custom/random.tar.gz
  run sshudp backups
  [[ "$output" == *"sshudp-backup-"* ]]
  [[ "$output" != *"random.tar.gz"* ]]
}
