# shellcheck shell=bash
# update.sh - manager self-update with verification, backup and automatic rollback.
#
# Release layout (GitHub Releases, or SSHUDP_RELEASE_BASE in tests):
#   <base>/latest/download/VERSION                          -> "1.2.3"
#   <base>/download/v1.2.3/ssh-udp-custom-server-v1.2.3.tar.gz
#   <base>/download/v1.2.3/SHA256SUMS
# The tarball is only used after its SHA-256 matches SHA256SUMS, its members are
# checked for path traversal, and its contents pass syntax/version checks.

release_base() { printf '%s' "${SSHUDP_RELEASE_BASE:-https://github.com/$SSHUDP_REPO/releases}"; }

valid_semver() { [[ "${1-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# semver_gt A B -> 0 if A > B
semver_gt() {
  local a="$1" b="$2"
  [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
}

latest_version() {
  local tmp v
  tmp="$(mktemp "${TMPDIR:-/tmp}/sshudp-ver.XXXXXX")" || return 1
  if ! http_get "$(release_base)/latest/download/VERSION" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  v="$(tr -d '[:space:]' <"$tmp")"
  rm -f -- "$tmp"
  valid_semver "$v" || return 1
  printf '%s' "$v"
}

# fetch_release VERSION DESTDIR -> extracts and verifies into DESTDIR/ssh-udp-custom-server-vX
fetch_release() {
  local v="$1" dest="$2" name base tar sums want got top n
  name="ssh-udp-custom-server-v$v"
  base="$(release_base)/download/v$v"
  tar="$dest/$name.tar.gz"
  sums="$dest/SHA256SUMS"
  http_get "$base/$name.tar.gz" "$tar" || { log_err "download failed: $base/$name.tar.gz"; return 1; }
  http_get "$base/SHA256SUMS" "$sums" || { log_err "download failed: SHA256SUMS"; return 1; }
  want="$(awk -v f="$name.tar.gz" '$2 == f || $2 == "*" f { print $1; exit }' "$sums")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { log_err "no checksum for $name.tar.gz in SHA256SUMS"; return 1; }
  got="$(sha256sum -- "$tar" | awk '{ print $1 }')"
  [[ "$got" == "$want" ]] || { log_err "checksum mismatch for release archive"; return 1; }
  # member sanity: no absolute paths, no "..", only regular files/dirs, single top dir
  while IFS= read -r n; do
    [[ "$n" == /* || "$n" == *..* ]] && { log_err "unsafe path in release archive: $n"; return 1; }
    [[ "$n" == "$name" || "$n" == "$name/"* ]] || { log_err "unexpected path in release archive: $n"; return 1; }
  done < <(tar -tzf "$tar")
  if tar -tvzf "$tar" | cut -c1 | grep -qv '^[-d]$'; then
    log_err "release archive contains links or special files"
    return 1
  fi
  mkdir -p "$dest/x"
  tar -xzf "$tar" -C "$dest/x" --no-same-owner --no-same-permissions || return 1
  top="$dest/x/$name"
  [[ -f "$top/VERSION" && "$(tr -d '[:space:]' <"$top/VERSION")" == "$v" ]] || { log_err "release VERSION mismatch"; return 1; }
  [[ -f "$top/bin/sshudp" && -f "$top/lib/common.sh" && -f "$top/upstream.conf" ]] || { log_err "release is incomplete"; return 1; }
  local f
  for f in "$top/bin/sshudp" "$top"/lib/*.sh "$top"/scripts/*.sh; do
    [[ -e "$f" ]] && ! bash -n "$f" 2>/dev/null && { log_err "syntax error in release file: ${f#"$top"/}"; return 1; }
  done
  printf '%s' "$top"
}

# install_tree SRC_TOP  -> place a verified release under $SSHUDP_INSTALL_DIR (atomic swap)
install_tree() {
  local src="$1" new="$SSHUDP_INSTALL_DIR.new" old="$SSHUDP_INSTALL_DIR.old" d
  rm -rf -- "$new" "$old"
  mkdir -p "$new"
  for d in bin lib scripts systemd; do
    [[ -d "$src/$d" ]] && cp -a -- "$src/$d" "$new/$d"
  done
  for d in VERSION upstream.conf uninstall.sh LICENSE; do
    [[ -f "$src/$d" ]] && cp -a -- "$src/$d" "$new/$d"
  done
  chmod -R go-w "$new"
  chmod 0755 "$new/bin/sshudp"
  [[ -f "$new/uninstall.sh" ]] && chmod 0755 "$new/uninstall.sh"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then chown -R root:root "$new"; fi
  # keep the (large, verified) core binary and the optional UDPGW build if they exist
  if [[ -d "$SSHUDP_INSTALL_DIR/core" ]]; then cp -a -- "$SSHUDP_INSTALL_DIR/core" "$new/core"; fi
  if [[ -d "$SSHUDP_INSTALL_DIR/udpgw" ]]; then cp -a -- "$SSHUDP_INSTALL_DIR/udpgw" "$new/udpgw"; fi
  if [[ -d "$SSHUDP_INSTALL_DIR" ]]; then mv -- "$SSHUDP_INSTALL_DIR" "$old"; fi
  if ! mv -- "$new" "$SSHUDP_INSTALL_DIR"; then
    [[ -d "$old" ]] && mv -- "$old" "$SSHUDP_INSTALL_DIR"
    return 1
  fi
}

update_run() {
  need_root
  local check=0 want="" yes=0 a cur latest tmp top snap
  while (($#)); do
    case "$1" in
      --check) check=1 ;;
      --yes | -y) yes=1 ;;
      --version) shift; want="${1:-}" ;;
    esac
    shift || true
  done
  cur="$(sshudp_version)"
  if [[ -n "$want" ]]; then
    valid_semver "$want" || die "invalid version: $want"
    latest="$want"
  else
    latest="$(latest_version)" || die "could not determine the latest version (network or release problem)"
  fi
  log_info "installed: v$cur    available: v$latest"
  if [[ "$latest" == "$cur" ]]; then
    log_ok "already up to date"
    return 0
  fi
  if [[ -z "$want" ]] && ! semver_gt "$latest" "$cur"; then
    log_ok "installed version is newer than the latest release; nothing to do"
    return 0
  fi
  ((check)) && { echo "update available: v$cur -> v$latest"; return 0; }
  if ((!yes)) && ! confirm "Update v$cur -> v$latest now?" y; then
    log_info "cancelled"
    return 0
  fi
  lock_acquire
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sshudp-update.XXXXXX")" || die "cannot create temp dir"
  chmod 0700 "$tmp"
  local rc=0
  _update_apply "$cur" "$latest" "$tmp" || rc=$?
  rm -rf -- "$tmp"
  return "$rc"
}

_update_apply() {
  local cur="$1" latest="$2" tmp="$3" top snap bk
  log_info "backing up configuration and metadata..."
  bk="$(backup_create --tag preupdate)" || die "backup failed - aborting update"
  snap="$SSHUDP_BACKUP_DIR/lib-v$cur-$(date +%Y%m%d-%H%M%S)"
  cp -a -- "$SSHUDP_INSTALL_DIR" "$snap" || die "could not snapshot the current installation"
  log_info "downloading and verifying v$latest..."
  top="$(fetch_release "$latest" "$tmp")" || { log_err "update aborted; nothing was changed"; return 1; }
  log_info "installing..."
  if ! install_tree "$top"; then
    log_err "installation of the new files failed; restoring"
    _update_rollback "$snap" "$cur"
    return 1
  fi
  ensure_bin_link || true
  # Health check runs with the NEW code (fresh process).
  if [[ "${SSHUDP_FAIL_AT:-}" == "update-health" ]] || ! "$SSHUDP_INSTALL_DIR/bin/sshudp" _post-update "$cur"; then
    log_err "health check failed after update - rolling back to v$cur"
    _update_rollback "$snap" "$cur"
    return 1
  fi
  rm -rf -- "$SSHUDP_INSTALL_DIR.old"
  ev "updated v$cur -> v$latest"
  log_ok "updated to v$latest (backup: $(basename -- "$bk"))"
}

_update_rollback() {
  local snap="$1" cur="$2"
  rm -rf -- "$SSHUDP_INSTALL_DIR.failed"
  [[ -d "$SSHUDP_INSTALL_DIR" ]] && mv -- "$SSHUDP_INSTALL_DIR" "$SSHUDP_INSTALL_DIR.failed"
  if cp -a -- "$snap" "$SSHUDP_INSTALL_DIR"; then
    ensure_bin_link || true
    "$SSHUDP_INSTALL_DIR/bin/sshudp" _post-update "$cur" >/dev/null 2>&1 || log_warn "post-rollback health check reported problems"
    rm -rf -- "$SSHUDP_INSTALL_DIR.failed" "$SSHUDP_INSTALL_DIR.old"
    ev "update rolled back to v$cur"
    log_ok "rolled back to v$cur"
  else
    log_err "rollback copy failed; previous files are in $snap"
  fi
}

# Runs inside the freshly installed code: migrate, re-apply, verify.
post_update() {
  local from="${1:-}"
  need_root
  # If this release pins a different (tested) core, install it.
  if ! core_verify_installed || [[ "$(upstream_get CORE_SHA256)" != "$(core_installed_sha)" ]]; then
    log_info "installing the core pinned by this release..."
    core_install || return 1
  fi
  cfg_file_ok "$SSHUDP_CONF_FILE" || { log_err "configuration invalid after update"; return 1; }
  apply_runtime || return 1
  cfg_set INSTALLED_VERSION "$(sshudp_version)" || true
  doctor_run --quick
}

core_update() {
  need_root
  lock_acquire
  log_info "current core: v$(core_installed_version) (pinned by this release: v$(upstream_get CORE_VERSION))"
  core_install || return 1
  svc_restart "$SVC_UDP"
  wait_service_ready || true
  sleep 1
  doctor_run --quick
}
