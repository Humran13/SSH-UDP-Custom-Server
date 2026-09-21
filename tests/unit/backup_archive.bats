#!/usr/bin/env bats
# Archive-safety tests: hostile tarballs must be rejected before anything is extracted or applied.
load helper
setup() {
  unit_setup
  W="$TMP/work"
  mkdir -p "$W/good/config" "$W/good/users"
  cfg_write_defaults
  cp "$SSHUDP_CONF_FILE" "$W/good/config/config.conf"
  printf 'USERNAME=demo\nUID=1001\nCREATED=2026-01-01\nEXPIRES=2026-12-31\nSTATUS=active\nMAXLOGINS=0\n' >"$W/good/users/demo.meta"
  printf 'FORMAT=1\nVERSION=1.0.0\nCREATED=2026-01-01T00:00:00Z\nUSERS=1\nHASHES=0\n' >"$W/good/manifest.conf"
  printf '1.0.0\n' >"$SSHUDP_INSTALL_DIR/VERSION"
}
teardown() { unit_teardown; }

mk() { ( cd "$W/good" && tar -czf "$SSHUDP_BACKUP_DIR/$1" . ); }
name=sshudp-backup-20260101-120000.tar.gz

@test "a well-formed archive passes validation" {
  mk $name; backup_validate_archive "$SSHUDP_BACKUP_DIR/$name";
}
@test "not a gzip file is rejected" {
  echo "hello" >"$SSHUDP_BACKUP_DIR/$name"
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
}
@test "truncated (corrupt) archive is rejected" {
  mk $name
  head -c 100 "$SSHUDP_BACKUP_DIR/$name" >"$TMP/trunc"
  mv "$TMP/trunc" "$SSHUDP_BACKUP_DIR/$name"
  run restore_run "$name"
  [ "$status" -ne 0 ]
}
@test "path traversal member (../evil) is rejected" {
  echo pwn >"$W/evil"
  ( cd "$W/good" && tar -czf "$SSHUDP_BACKUP_DIR/$name" --transform='s|^evil$|../evil|' -C "$W" evil . ) || true
  ( cd "$W" && tar -czf "$SSHUDP_BACKUP_DIR/$name" --transform='s|^evil$|../evil|' evil )
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"traversal"* || "$output" == *"unexpected"* ]]
}
@test "absolute path member is rejected" {
  echo pwn >"$W/evil"
  ( cd "$W" && tar -czPf "$SSHUDP_BACKUP_DIR/$name" --transform="s|^evil\$|$TMP/abs-evil|" evil )
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
}
@test "symlink member is rejected" {
  ln -s /etc/passwd "$W/good/users/link.meta"
  mk $name
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"links"* ]]
}
@test "hardlink member is rejected" {
  ln "$W/good/users/demo.meta" "$W/good/users/other.meta"
  mk $name
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
}
@test "unexpected file name is rejected" {
  echo x >"$W/good/config/evil.sh"
  mk $name
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected"* ]]
}
@test "extra top-level file is rejected" {
  echo x >"$W/good/authorized_keys"
  mk $name
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
}
@test "username in meta path must be valid" {
  cp "$W/good/users/demo.meta" "$W/good/users/Bad.Name.meta"
  mk $name
  run backup_validate_archive "$SSHUDP_BACKUP_DIR/$name"
  [ "$status" -ne 0 ]
}
@test "restore refuses names that are not valid backup names" {
  run restore_run ../../etc/passwd
  [ "$status" -ne 0 ]
  run restore_run "/etc/passwd"
  [ "$status" -ne 0 ]
}
@test "restore refuses a symlinked archive" {
  mk $name
  ln -s "$SSHUDP_BACKUP_DIR/$name" "$SSHUDP_BACKUP_DIR/sshudp-backup-20260101-130000.tar.gz"
  run restore_run sshudp-backup-20260101-130000.tar.gz
  [ "$status" -ne 0 ]
}
@test "restore refuses a manifest from a newer major version" {
  sed -i 's/^VERSION=.*/VERSION=9.0.0/' "$W/good/manifest.conf"
  mk $name
  run restore_run $name
  [ "$status" -ne 0 ]
  [[ "$output" == *"newer major"* ]]
}
@test "restore refuses an unknown backup format" {
  sed -i 's/^FORMAT=.*/FORMAT=7/' "$W/good/manifest.conf"
  mk $name
  run restore_run $name
  [ "$status" -ne 0 ]
}
@test "restore refuses invalid metadata (bad date)" {
  sed -i 's/^EXPIRES=.*/EXPIRES=not-a-date/' "$W/good/users/demo.meta"
  mk $name
  run restore_run $name
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid account metadata"* ]]
}
@test "restore refuses metadata with injected extra lines" {
  echo 'ROOTSHELL=1' >>"$W/good/users/demo.meta"
  mk $name
  run restore_run $name
  [ "$status" -ne 0 ]
}
@test "restore refuses a config with unknown keys" {
  echo 'HACK=1' >>"$W/good/config/config.conf"
  mk $name
  run restore_run $name
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.conf is invalid"* ]]
}
@test "nothing is applied when validation fails" {
  echo 'HACK=1' >>"$W/good/config/config.conf"
  mk $name
  before="$(cat "$SSHUDP_CONF_FILE")"
  run restore_run $name
  [ "$(cat "$SSHUDP_CONF_FILE")" = "$before" ]
  [ -z "$(ls "$SSHUDP_USERS_DIR")" ]
}
@test "valid restore applies config and metadata and backs up current state first" {
  cfg_set UDP_LISTEN_PORT 41000
  sed -i 's/^UDP_LISTEN_PORT=.*/UDP_LISTEN_PORT=42000/' "$W/good/config/config.conf"
  mk $name
  run restore_run $name
  [ "$status" -eq 0 ]
  [ "$(cfg_get UDP_LISTEN_PORT)" = "42000" ]
  [ -f "$SSHUDP_USERS_DIR/demo.meta" ]
  ls "$SSHUDP_BACKUP_DIR" | grep -q prerestore
}
@test "backup_create writes a 0600 archive with the expected members only" {
  meta_write demo 1001 2026-01-01 2026-12-31 active 0
  is_managed_user() { return 0; }
  out="$(backup_create)"
  [ "$(stat -c %a "$out")" = "600" ]
  backup_validate_archive "$out"
  tar -tzf "$out" | grep -q 'users/demo.meta'
  ! tar -tzf "$out" | grep -qi 'shadow\|hashes\|\.ssh\|id_rsa'
}
@test "backup_create --with-hashes adds secrets only on request" {
  meta_write demo 1001 2026-01-01 2026-12-31 active 0
  is_managed_user() { return 0; }
  getent() { [ "$1" = shadow ] && echo 'demo:$6$salt$hash:19000:0:99999:7:::'; }
  out="$(backup_create --with-hashes)"
  tar -tzf "$out" | grep -q 'secrets/hashes.txt'
  backup_validate_archive "$out"
}
@test "backup tag is validated" {
  run backup_create --tag 'bad tag;x'
  [ "$status" -ne 0 ]
}
@test "backup listing only shows valid names" {
  touch "$SSHUDP_BACKUP_DIR/sshudp-backup-20260101-120000.tar.gz" "$SSHUDP_BACKUP_DIR/random.tar.gz"
  out="$(backup_list)"
  [[ "$out" == *"sshudp-backup-20260101-120000.tar.gz"* ]]
  [[ "$out" != *"random.tar.gz"* ]]
}
