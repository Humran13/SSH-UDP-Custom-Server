# shellcheck shell=bash
# uninstall.sh - remove ONLY what this project created.
#
# Never touched: OpenSSH itself, the global sshd_config (except our marked
# block on old systems), other users, other firewall rules, the firewall's
# enabled/disabled state, packages installed as dependencies.

# uninstall_run [--yes] [--remove-users|--keep-users] [--purge|--keep-config]
uninstall_run() {
  need_root
  local yes=0 rmusers="" purge="" a u
  for a in "$@"; do
    case "$a" in
      --yes | -y) yes=1; SSHUDP_ASSUME_YES=1 ;;
      --remove-users) rmusers=yes ;;
      --keep-users) rmusers=no ;;
      --purge) purge=yes ;;
      --keep-config) purge=no ;;
    esac
  done
  echo "This will remove SSH UDP Custom Server (services, timers, firewall rules,"
  echo "sshd tunnel policy, manager). OpenSSH and unrelated settings are left alone."
  if ((!yes)); then
    confirm "Continue with uninstall?" n || { log_info "cancelled"; return 1; }
  fi
  local n
  n="$(count_users)"
  if [[ -z "$rmusers" ]]; then
    if ((n > 0)) && confirm "Also delete the $n managed tunnel user(s)? (No keeps them as ordinary locked-shell accounts)" n; then
      rmusers=yes
    else
      rmusers=no
    fi
  fi
  if [[ -z "$purge" ]]; then
    confirm "Delete configuration, account metadata and backups too? (No = keep them for a later reinstall)" n && purge=yes || purge=no
  fi
  lock_acquire
  ev "uninstall started (remove-users=$rmusers purge=$purge)"

  # 1. services and units
  units_remove
  # 2. firewall: only our own objects
  fw_purge
  # 3. sshd policy (validated, reload only)
  sshd_unconfigure
  # 4. sysctl values we raised
  sysctl_restore
  # 5. optional add-ons that we configured
  rm -f -- "$F2B_JAIL"
  # 6. users
  if [[ "$rmusers" == yes ]]; then
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      if is_managed_user "$u"; then
        user_delete "$u" && log_ok "deleted user $u"
      fi
    done < <(managed_users)
  fi
  # service account and group (only if we created them and nothing uses them)
  if getent passwd "$SSHUDP_SVC_USER" >/dev/null 2>&1 && [[ "$(getent passwd "$SSHUDP_SVC_USER" | cut -d: -f5)" == "ssh-udp-custom transport" ]]; then
    userdel "$SSHUDP_SVC_USER" >/dev/null 2>&1 || true
  fi
  if getent group "$SSHUDP_GROUP" >/dev/null 2>&1 && [[ -z "$(getent group "$SSHUDP_GROUP" | cut -d: -f4)" ]] &&
    ! getent passwd | awk -F: -v g="$(getent group "$SSHUDP_GROUP" | cut -d: -f3)" '$4 == g { f = 1 } END { exit f ? 0 : 1 }'; then
    groupdel "$SSHUDP_GROUP" >/dev/null 2>&1 || true
  fi
  # 7. data
  if [[ "$purge" == yes ]]; then
    rm_project_path "$SSHUDP_CONF_DIR" "$SSHUDP_STATE_DIR" "$SSHUDP_BACKUP_DIR"
    log_ok "configuration, metadata and backups deleted"
  else
    log_info "kept: $SSHUDP_CONF_DIR  $SSHUDP_STATE_DIR  $SSHUDP_BACKUP_DIR"
  fi
  # 8. program files last
  rm -f -- "$SSHUDP_BIN_LINK"
  rm_project_path "$SSHUDP_INSTALL_DIR" "$SSHUDP_INSTALL_DIR.old" "$SSHUDP_INSTALL_DIR.new"
  log_ok "SSH UDP Custom Server has been removed."
  echo "OpenSSH, other users and unrelated firewall rules were not touched."
  return 0
}
