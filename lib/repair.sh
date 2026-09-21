# shellcheck shell=bash
# repair.sh - (re)create everything derived from configuration. Idempotent and
# non-destructive: valid user settings and accounts are never reset.

ensure_dirs() {
  mkdir -p "$SSHUDP_CONF_DIR" "$SSHUDP_STATE_DIR" "$SSHUDP_USERS_DIR" "$SSHUDP_STATE_SUB" "$SSHUDP_BACKUP_DIR"
  chmod 0755 "$SSHUDP_CONF_DIR"
  chmod 0700 "$SSHUDP_STATE_DIR" "$SSHUDP_USERS_DIR" "$SSHUDP_STATE_SUB" "$SSHUDP_BACKUP_DIR"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown root:root "$SSHUDP_CONF_DIR" "$SSHUDP_STATE_DIR" "$SSHUDP_USERS_DIR" "$SSHUDP_STATE_SUB" "$SSHUDP_BACKUP_DIR"
  fi
}

ensure_bin_link() {
  local target="$SSHUDP_INSTALL_DIR/bin/sshudp"
  [[ -x "$target" ]] || return 1
  if [[ ! -L "$SSHUDP_BIN_LINK" || "$(readlink "$SSHUDP_BIN_LINK")" != "$target" ]]; then
    ln -sfn "$target" "$SSHUDP_BIN_LINK"
  fi
}

# apply_runtime: regenerate JSON/units/sshd policy/sysctl/firewall from config.
apply_runtime() {
  service_user_ensure || return 1
  ensure_group || return 1
  core_json_write || return 1
  sysctl_configure || log_warn "sysctl tuning skipped"
  units_install || return 1
  sshd_configure || return 1
  units_enable_all
  if have_systemd; then
    svc_restart "$SVC_FW" || log_warn "firewall unit failed to start"
    svc_restart "$SVC_UDP" || return 1
    wait_service_ready || log_warn "the UDP core did not start listening within 20 s"
    systemctl start "$SVC_EXPIRY.timer" "$SVC_LIMITER.timer" 2>/dev/null || true
    if [[ "$(cfg_get UDPGW_ENABLED)" == "yes" ]]; then
      systemctl enable --now "$SVC_UDPGW" >/dev/null 2>&1 || true
    fi
  fi
}

repair_run() {
  need_root
  local latest_bak
  log_info "repairing installation (settings and accounts are preserved)"
  ensure_dirs
  ensure_bin_link || log_warn "could not verify the sshudp command link"

  if ! cfg_file_ok "$SSHUDP_CONF_FILE" 2>/dev/null; then
    latest_bak="$(ls -1t "$SSHUDP_BACKUP_DIR"/sshudp-backup-*.tar.gz 2>/dev/null | head -1 || true)"
    if [[ -n "$latest_bak" ]] && restore_run "$latest_bak" >/dev/null 2>&1; then
      log_ok "configuration recovered from $(basename -- "$latest_bak")"
    else
      log_warn "configuration missing/invalid and no usable backup: writing defaults"
      [[ -e "$SSHUDP_CONF_FILE" ]] && cp -p -- "$SSHUDP_CONF_FILE" "$SSHUDP_CONF_FILE.damaged.$(date +%s)"
      cfg_write_defaults
      cfg_set SSH_PORT "$(detect_sshd_port)" || true
      cfg_set INSTALLED_VERSION "$(sshudp_version)" || true
    fi
  fi
  if ! core_verify_installed; then
    log_info "UDP core missing or modified - reinstalling the pinned version"
    core_install || return 1
  fi
  apply_runtime || { log_err "could not re-apply runtime configuration"; return 1; }
  ensure_dirs
  echo
  doctor_run --quick
}

detect_sshd_port() {
  local p s
  s="$(command -v sshd || echo /usr/sbin/sshd)"
  mkdir -p /run/sshd 2>/dev/null || true
  p="$("$s" -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
  if valid_port "$p"; then printf '%s' "$p"; else printf '22'; fi
}

# wait_service_ready: after a (re)start, wait until the core is actually listening.
wait_service_ready() {
  local i lp
  lp="$(cfg_get UDP_LISTEN_PORT)"
  for i in $(seq 1 20); do
    _udp_listening "$lp" && return 0
    sleep 1
  done
  return 1
}
