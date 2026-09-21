# shellcheck shell=bash
# service.sh - systemd units, sshd drop-in, sysctl and service-user handling.

SSHD_MAIN_CONFIG="${SSHUDP_SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_BLOCK_BEGIN="# BEGIN ssh-udp-custom (managed - do not edit)"
SSHD_BLOCK_END="# END ssh-udp-custom"

# ---------------------------------------------------------------- systemd --
_sc() { # systemctl wrapper that never touches units outside this project
  have_systemd || return 0
  systemctl "$@"
}

# Manual operations clear the start-rate counter first: newer systemd counts them, while the
# limit is only meant to stop crash loops.
svc_start() { _sc reset-failed "${1:-$SVC_UDP}" 2>/dev/null; _sc start "${1:-$SVC_UDP}"; }
svc_stop() { _sc stop "${1:-$SVC_UDP}"; }
svc_restart() { _sc reset-failed "${1:-$SVC_UDP}" 2>/dev/null; _sc restart "${1:-$SVC_UDP}"; }
svc_enable() { _sc enable "$@" >/dev/null 2>&1; }
svc_is_active() { have_systemd && systemctl is-active --quiet "${1:-$SVC_UDP}"; }
svc_is_enabled() { have_systemd && systemctl is-enabled --quiet "${1:-$SVC_UDP}" 2>/dev/null; }
svc_state() { systemctl is-active "${1:-$SVC_UDP}" 2>/dev/null || true; }

# Render a unit template. Placeholders are replaced with validated values only.
render_unit() { # render_unit TEMPLATE DEST
  local tpl="$1" dest="$2" run_as user group supp
  run_as="$(cfg_get RUN_AS)"
  if [[ "$run_as" == "root" ]]; then
    user="root" group="root" supp=""
  else
    user="$SSHUDP_SVC_USER" group="$SSHUDP_SVC_USER" supp="shadow"
  fi
  sed \
    -e "s|@LIB@|$SSHUDP_INSTALL_DIR|g" \
    -e "s|@CONF@|$SSHUDP_CONF_DIR|g" \
    -e "s|@STATE@|$SSHUDP_STATE_DIR|g" \
    -e "s|@RUN_USER@|$user|g" \
    -e "s|@RUN_GROUP@|$group|g" \
    -e "s|@SUPP_GROUPS@|$supp|g" \
    -e "s|@UDPGW_PORT@|$(cfg_get UDPGW_PORT)|g" \
    -e "s|@UDPGW_USER@|$SSHUDP_SVC_USER|g" \
    "$tpl" | atomic_write "$dest" 0644 root:root
}

units_install() { # install core units (+ udpgw unit only if enabled)
  local t name
  for t in "$SSHUDP_INSTALL_DIR"/systemd/*.service "$SSHUDP_INSTALL_DIR"/systemd/*.timer; do
    [[ -e "$t" ]] || continue
    name="$(basename -- "$t")"
    [[ "$name" == "$SVC_UDPGW" && "$(cfg_get UDPGW_ENABLED)" != "yes" ]] && continue
    render_unit "$t" "$SSHUDP_SYSTEMD_DIR/$name" || return 1
  done
  _sc daemon-reload
}

units_remove() {
  local n
  for n in "$SVC_UDP" "$SVC_FW" "$SVC_EXPIRY.service" "$SVC_EXPIRY.timer" \
    "$SVC_LIMITER.service" "$SVC_LIMITER.timer" "$SVC_UDPGW"; do
    if have_systemd; then
      systemctl stop "$n" >/dev/null 2>&1 || true
      systemctl disable "$n" >/dev/null 2>&1 || true
    fi
    rm -f -- "$SSHUDP_SYSTEMD_DIR/$n"
  done
  _sc daemon-reload
}

units_enable_all() {
  svc_enable "$SVC_FW" "$SVC_UDP" "$SVC_EXPIRY.timer" "$SVC_LIMITER.timer"
}

units_start_all() {
  svc_start "$SVC_FW" || return 1
  svc_start "$SVC_UDP" || return 1
  _sc start "$SVC_EXPIRY.timer" "$SVC_LIMITER.timer"
}

# ------------------------------------------------------------ service user --
service_user_ensure() {
  local run_as
  run_as="$(cfg_get RUN_AS)"
  [[ "$run_as" == "root" ]] && return 0
  if ! getent passwd "$SSHUDP_SVC_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
      --user-group --comment "ssh-udp-custom transport" -- "$SSHUDP_SVC_USER" || return 1
  fi
}

# ------------------------------------------------------------------- sshd --
_sshd_block() {
  cat <<EOF
# Tunnel accounts created by ssh-udp-custom (group $SSHUDP_GROUP): password login,
# port forwarding only - no shell, no TTY, no agent/X11 forwarding, no tunnels.
# Other users and the global sshd configuration are not affected.
Match Group $SSHUDP_GROUP
    PasswordAuthentication yes
    AuthenticationMethods password
    AllowTcpForwarding yes
    GatewayPorts no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
EOF
}

sshd_uses_include() {
  [[ -d "$SSHUDP_SSHD_DROPIN_DIR" ]] &&
    grep -Eqs '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_MAIN_CONFIG"
}

sshd_reload() {
  local n
  have_systemd || return 0
  n="$(sshd_service_name)"
  systemctl reload "$n" 2>/dev/null || systemctl reload-or-restart "$n" 2>/dev/null || true
}

# Install our Match block; validate with `sshd -t`; roll back on failure.
# Never restarts sshd (reload only), so existing SSH sessions survive.
sshd_configure() {
  local dropin="$SSHUDP_SSHD_DROPIN_DIR/$SSHUDP_DROPIN_NAME" bak=""
  if ! have sshd && [[ ! -x /usr/sbin/sshd ]]; then
    log_err "OpenSSH server (sshd) is not installed"
    return 1
  fi
  mkdir -p "$SSHUDP_BACKUP_DIR"
  if sshd_uses_include; then
    [[ -e "$dropin" ]] && bak="$(mktemp "$SSHUDP_BACKUP_DIR/.dropin.XXXXXX")" && cp -p -- "$dropin" "$bak"
    _sshd_block | atomic_write "$dropin" 0644 root:root || return 1
    if ! _sshd_test; then
      if [[ -n "$bak" ]]; then mv -f -- "$bak" "$dropin"; else rm -f -- "$dropin"; fi
      log_err "sshd rejected the configuration; change rolled back"
      return 1
    fi
    [[ -n "$bak" ]] && rm -f -- "$bak"
  else
    # Old OpenSSH without an Include line: append a marked block (backup first).
    bak="$SSHUDP_BACKUP_DIR/sshd_config.$(date +%Y%m%d-%H%M%S).bak"
    cp -p -- "$SSHD_MAIN_CONFIG" "$bak" || return 1
    _sshd_strip_block "$SSHD_MAIN_CONFIG"
    {
      cat "$SSHD_MAIN_CONFIG"
      printf '\n%s\n' "$SSHD_BLOCK_BEGIN"
      _sshd_block
      printf '%s\n' "$SSHD_BLOCK_END"
    } | atomic_write "$SSHD_MAIN_CONFIG" 0644 root:root || return 1
    if ! _sshd_test; then
      cp -p -- "$bak" "$SSHD_MAIN_CONFIG"
      log_err "sshd rejected the configuration; original restored from $bak"
      return 1
    fi
  fi
  sshd_reload
}

_sshd_test() {
  local s
  s="$(command -v sshd || echo /usr/sbin/sshd)"
  mkdir -p /run/sshd 2>/dev/null || true
  "$s" -t 2>/dev/null
}

_sshd_strip_block() { # remove our marked block (if any) from a file, in place
  local f="$1"
  grep -qF "$SSHD_BLOCK_BEGIN" "$f" 2>/dev/null || return 0
  awk -v b="$SSHD_BLOCK_BEGIN" -v e="$SSHD_BLOCK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }' "$f" | atomic_write "$f" 0644 root:root
}

sshd_unconfigure() {
  local dropin="$SSHUDP_SSHD_DROPIN_DIR/$SSHUDP_DROPIN_NAME"
  rm -f -- "$dropin"
  if [[ -r "$SSHD_MAIN_CONFIG" ]] && grep -qF "$SSHD_BLOCK_BEGIN" "$SSHD_MAIN_CONFIG"; then
    _sshd_strip_block "$SSHD_MAIN_CONFIG"
  fi
  if _sshd_test; then
    sshd_reload
  else
    log_warn "sshd -t failed after removing our block; sshd was NOT reloaded"
  fi
}

sshd_block_present() {
  [[ -e "$SSHUDP_SSHD_DROPIN_DIR/$SSHUDP_DROPIN_NAME" ]] ||
    { [[ -r "$SSHD_MAIN_CONFIG" ]] && grep -qF "$SSHD_BLOCK_BEGIN" "$SSHD_MAIN_CONFIG"; }
}

# -------------------------------------------------------------- sysctl -----
# The upstream core itself runs `sysctl -w net.core.{r,w}mem_max=16777216` at
# start. We do the same once, persistently and reversibly, and only ever RAISE.
sysctl_configure() {
  local k cur want=16777216 prev="$SSHUDP_STATE_SUB/sysctl.prev" changed=0 lines=""
  mkdir -p "$SSHUDP_STATE_SUB"
  for k in net.core.rmem_max net.core.wmem_max; do
    cur="$(sysctl -n "$k" 2>/dev/null || echo 0)"
    if [[ "$cur" =~ ^[0-9]+$ ]] && ((cur < want)); then
      [[ -e "$prev" ]] && grep -q "^$k=" "$prev" || printf '%s=%s\n' "$k" "$cur" >>"$prev"
      lines+="$k = $want"$'\n'
      changed=1
    fi
  done
  ((changed)) || return 0
  {
    echo "# ssh-udp-custom: larger UDP socket buffers for the QUIC-based core"
    printf '%s' "$lines"
  } | atomic_write "$SSHUDP_SYSCTL_FILE" 0644 root:root || return 1
  sysctl -q -p "$SSHUDP_SYSCTL_FILE" >/dev/null 2>&1 || log_warn "could not apply sysctl values live (container?)"
}

sysctl_restore() {
  local prev="$SSHUDP_STATE_SUB/sysctl.prev" k v
  if [[ -r "$prev" ]]; then
    while IFS='=' read -r k v; do
      [[ "$k" =~ ^net\.core\.[rw]mem_max$ && "$v" =~ ^[0-9]+$ ]] && sysctl -q -w "$k=$v" >/dev/null 2>&1 || true
    done <"$prev"
    rm -f -- "$prev"
  fi
  rm -f -- "$SSHUDP_SYSCTL_FILE"
}
