# shellcheck shell=bash
# backup.sh - backup and restore of project configuration and account metadata.
#
# NOT included by default: /etc/shadow, password hashes, SSH keys, plaintext
# passwords. `--with-hashes` is an explicit opt-in that adds the password hashes
# of MANAGED tunnel users only, in a 0600 archive (see docs/SECURITY.md).

BACKUP_FORMAT=1
_ARCHIVE_PATH_RE='^(\./)?(manifest\.conf|config/config\.conf|config/udp-custom\.json|users/[a-z_][a-z0-9_-]{2,31}\.meta|secrets/hashes\.txt)$'
_ARCHIVE_DIR_RE='^(\./)?(config|users|secrets)?/?$'

backup_dir_ensure() {
  mkdir -p "$SSHUDP_BACKUP_DIR" && chmod 0700 "$SSHUDP_BACKUP_DIR"
}

# backup_create [--with-hashes] [--tag NAME]  -> prints the archive path
backup_create() {
  local hashes=0 tag="" stage out ts u h n=0
  while (($#)); do
    case "$1" in
      --with-hashes) hashes=1 ;;
      --tag) shift; tag="${1:-}" ;;
    esac
    shift || true
  done
  [[ -z "$tag" || "$tag" =~ ^[a-z0-9]{1,16}$ ]] || { log_err "invalid backup tag"; return 1; }
  backup_dir_ensure || return 1
  stage="$(mktemp -d "$SSHUDP_BACKUP_DIR/.stage.XXXXXX")" || return 1
  chmod 0700 "$stage"
  mkdir -p "$stage/config" "$stage/users"
  [[ -r "$SSHUDP_CONF_FILE" ]] && cp -- "$SSHUDP_CONF_FILE" "$stage/config/config.conf"
  [[ -r "$SSHUDP_CORE_JSON" ]] && cp -- "$SSHUDP_CORE_JSON" "$stage/config/udp-custom.json"
  for u in $(managed_users); do
    cp -- "$SSHUDP_USERS_DIR/$u.meta" "$stage/users/$u.meta"
    n=$((n + 1))
  done
  if ((hashes)); then
    mkdir -p "$stage/secrets"
    : >"$stage/secrets/hashes.txt"
    chmod 0600 "$stage/secrets/hashes.txt"
    for u in $(managed_users); do
      is_managed_user "$u" || continue
      h="$(getent shadow "$u" | cut -d: -f2)"
      [[ -n "$h" ]] && printf '%s:%s\n' "$u" "$h" >>"$stage/secrets/hashes.txt"
    done
  fi
  {
    printf 'FORMAT=%s\n' "$BACKUP_FORMAT"
    printf 'VERSION=%s\n' "$(sshudp_version)"
    printf 'CREATED=%s\n' "$(date -u +%FT%TZ)"
    printf 'USERS=%s\n' "$n"
    printf 'HASHES=%s\n' "$((hashes ? 1 : 0))"
  } >"$stage/manifest.conf"
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$SSHUDP_BACKUP_DIR/sshudp-backup-$ts${tag:+-$tag}.tar.gz"
  [[ -e "$out" ]] && out="$SSHUDP_BACKUP_DIR/sshudp-backup-$ts-$RANDOM${tag:+$tag}.tar.gz"
  (umask 077 && tar -C "$stage" --owner=0 --group=0 --numeric-owner -czf "$out" .) || {
    rm -rf -- "$stage"
    log_err "could not create archive"
    return 1
  }
  chmod 0600 "$out"
  rm -rf -- "$stage"
  ev "backup created: $(basename -- "$out") users=$n hashes=$hashes"
  printf '%s\n' "$out"
}

backup_list() {
  local f
  backup_dir_ensure
  for f in "$SSHUDP_BACKUP_DIR"/sshudp-backup-*.tar.gz; do
    [[ -e "$f" ]] || continue
    valid_backup_name "$(basename -- "$f")" || continue
    printf '%s  %s\n' "$(basename -- "$f")" "$(human_bytes "$(stat -c %s "$f")")"
  done
}

# Resolve user input to an archive path (bare name in the backup dir, or a path
# whose final component is a valid backup name). Symlinks are refused.
_backup_resolve() {
  local in="$1" base path
  base="$(basename -- "$in")"
  valid_backup_name "$base" || { log_err "not a valid backup file name: $base"; return 1; }
  if [[ "$in" == */* ]]; then path="$in"; else path="$SSHUDP_BACKUP_DIR/$in"; fi
  [[ -f "$path" && ! -L "$path" ]] || { log_err "backup not found (or is a symlink): $path"; return 1; }
  printf '%s' "$path"
}

# backup_validate_archive PATH -> 0 if every member is an allowed path and a
# regular file/directory (no symlinks, hardlinks, devices, absolute or .. paths).
backup_validate_archive() {
  local f="$1" names types count total
  names="$(tar -tzf "$f" 2>/dev/null)" || { log_err "not a readable gzip tar archive"; return 1; }
  types="$(tar -tvzf "$f" 2>/dev/null | cut -c1)" || return 1
  count="$(printf '%s\n' "$names" | wc -l)"
  ((count <= 5000)) || { log_err "archive has too many entries"; return 1; }
  [[ "$(printf '%s\n' "$types" | wc -l)" == "$count" ]] || { log_err "archive listing is inconsistent (unusual file names)"; return 1; }
  if printf '%s\n' "$types" | grep -qv '^[-d]$'; then
    log_err "archive contains links or special files - refusing"
    return 1
  fi
  local n
  while IFS= read -r n; do
    [[ "$n" == *..* ]] && { log_err "path traversal in archive: $n"; return 1; }
    [[ "$n" == /* ]] && { log_err "absolute path in archive: $n"; return 1; }
    if [[ "$n" =~ $_ARCHIVE_PATH_RE || "$n" =~ $_ARCHIVE_DIR_RE ]]; then :; else
      log_err "unexpected path in archive: $n"
      return 1
    fi
  done <<<"$names"
  total="$(tar -tvzf "$f" 2>/dev/null | awk '{ s += $3 } END { print s + 0 }')"
  ((total <= 10485760)) || { log_err "archive content too large"; return 1; }
  return 0
}

_meta_file_ok() { # validate an extracted meta file strictly
  local f="$1" name
  name="$(basename -- "$f" .meta)"
  valid_username "$name" || return 1
  [[ "$(kv_get "$f" USERNAME)" == "$name" ]] || return 1
  [[ "$(kv_get "$f" UID)" =~ ^[0-9]{1,10}$ ]] || return 1
  valid_date "$(kv_get "$f" CREATED)" || return 1
  valid_date "$(kv_get "$f" EXPIRES)" || return 1
  valid_choice "$(kv_get "$f" STATUS)" active locked expired || return 1
  valid_maxlogins "$(kv_get "$f" MAXLOGINS)" || return 1
  local lines
  lines="$(grep -c . "$f")"
  ((lines == 6))
}

# restore_run FILE [--yes]
restore_run() {
  local rc=0 tmpd
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/sshudp-restore.XXXXXX")" || return 1
  chmod 0700 "$tmpd"
  _restore_apply "$1" "$tmpd" || rc=$?
  rm -rf -- "$tmpd"
  return "$rc"
}

_restore_apply() {
  local in="$1" tmp="$2" path mver cur f u pre restored=0 hashes
  path="$(_backup_resolve "$in")" || return 1
  backup_validate_archive "$path" || return 1
  tar -xzf "$path" -C "$tmp" --no-same-owner --no-same-permissions --no-overwrite-dir || {
    log_err "extraction failed"
    return 1
  }
  [[ -f "$tmp/manifest.conf" && ! -L "$tmp/manifest.conf" ]] || { log_err "archive has no manifest"; return 1; }
  [[ "$(kv_get "$tmp/manifest.conf" FORMAT)" == "$BACKUP_FORMAT" ]] || { log_err "unsupported backup format"; return 1; }
  mver="$(kv_get "$tmp/manifest.conf" VERSION)"
  cur="$(sshudp_version)"
  if [[ ! "$mver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_err "invalid version in backup manifest"
    return 1
  fi
  if ((${mver%%.*} > ${cur%%.*})); then
    log_err "backup was made by a newer major version ($mver > $cur); update sshudp first"
    return 1
  fi
  if [[ -f "$tmp/config/config.conf" ]]; then
    cfg_file_ok "$tmp/config/config.conf" || { log_err "backup config.conf is invalid"; return 1; }
  fi
  for f in "$tmp"/users/*.meta; do
    [[ -e "$f" ]] || continue
    _meta_file_ok "$f" || { log_err "invalid account metadata in backup: $(basename -- "$f")"; return 1; }
  done
  log_info "backup OK: version $mver, $(kv_get "$tmp/manifest.conf" USERS) user(s)"
  pre="$(backup_create --tag prerestore)" || { log_err "could not back up current state first"; return 1; }
  log_info "current state saved to $(basename -- "$pre")"

  if [[ -f "$tmp/config/config.conf" ]]; then
    atomic_write "$SSHUDP_CONF_FILE" 0644 root:root <"$tmp/config/config.conf" || return 1
    # Runtime version marker always reflects what is installed, not the backup.
    cfg_set INSTALLED_VERSION "$cur" || true
  fi
  mkdir -p "$SSHUDP_USERS_DIR" && chmod 0700 "$SSHUDP_USERS_DIR"
  for f in "$tmp"/users/*.meta; do
    [[ -e "$f" ]] || continue
    u="$(basename -- "$f" .meta)"
    atomic_write "$SSHUDP_USERS_DIR/$u.meta" 0600 root:root <"$f" || return 1
    restored=$((restored + 1))
  done
  hashes="$(kv_get "$tmp/manifest.conf" HASHES 0)"
  if [[ "$hashes" == "1" && -f "$tmp/secrets/hashes.txt" ]]; then
    _restore_hashes "$tmp/secrets/hashes.txt"
  fi
  ev "restore applied from $(basename -- "$path"): $restored user metadata file(s)"
  log_ok "restored configuration and $restored account record(s)"
  local o
  o="$(orphan_users | tr '\n' ' ')"
  [[ -z "$o" ]] || log_warn "no system account for: $o (re-create them, or restore with a --with-hashes backup)"
  return 0
}

_restore_hashes() {
  local f="$1" u h exp
  local hre='^!?\$[0-9a-z]+\$[A-Za-z0-9./$,=+-]+$'
  while IFS=: read -r u h; do
    valid_username "$u" && [[ "$h" =~ $hre ]] && [[ -r "$(_meta_file "$u")" ]] || continue
    if ! os_user_exists "$u"; then
      ensure_group || continue
      exp="$(meta_get "$u" EXPIRES)"
      useradd --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
        --no-user-group --gid "$SSHUDP_GROUP" --expiredate "$(_os_expiry "$exp")" \
        --comment "sshudp managed tunnel account" -- "$u" || continue
      meta_set "$u" UID "$(os_user_uid "$u")"
    fi
    is_managed_user "$u" && usermod -p "$h" -- "$u" && log_info "password hash restored for $u"
  done <"$f"
}
