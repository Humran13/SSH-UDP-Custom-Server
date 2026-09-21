# shellcheck shell=bash
# extras.sh - optional features: UDPGW and Fail2ban. Both are OFF by default.
#
# UDPGW (badvpn-udpgw) is NOT needed for the UDP Custom transport. It is only
# useful when an app tunnels UDP traffic (DNS, voice, games) *through the SSH
# connection* and its "UDPGW" option is switched on. We use the distribution's
# pinned, checksum-verified upstream SOURCE (Ubuntu ships no package) instead of an unknown binary, bind it to 127.0.0.1
# only (reachable solely via the SSH tunnel) and run it as an unprivileged user.

udpgw_bin() { [[ -x "$SSHUDP_INSTALL_DIR/udpgw/badvpn-udpgw" ]] && printf '%s' "$SSHUDP_INSTALL_DIR/udpgw/badvpn-udpgw" || true; }

# Build badvpn-udpgw from the pinned upstream source tag (BSD-3-Clause). Ubuntu has no
# badvpn package, and we refuse to fetch a random prebuilt binary. Build tools are
# installed only for this, only when needed; the source SHA-256 is verified first.
udpgw_build() {
  local url sha ver tmp got n
  url="$(upstream_get UDPGW_URL)"
  sha="$(upstream_get UDPGW_SHA256)"
  ver="$(upstream_get UDPGW_VERSION)"
  [[ -n "$url" && "$sha" =~ ^[0-9a-f]{64}$ ]] || { log_err "upstream.conf lacks UDPGW pins"; return 1; }
  if [[ "${SSHUDP_TESTING:-}" == "1" && -n "${SSHUDP_UDPGW_URL:-}" ]]; then url="$SSHUDP_UDPGW_URL"; fi
  local t
  for t in cmake make gcc; do
    have "$t" || { log_info "installing build tools (cmake make gcc libc6-dev)..."; apt_install cmake make gcc libc6-dev || { log_err "could not install build tools"; return 1; }; break; }
  done
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sshudp-udpgw.XXXXXX")" || return 1
  log_info "downloading badvpn $ver source (pinned)..."
  if ! http_get "$url" "$tmp/src.tgz"; then rm -rf -- "$tmp"; log_err "download failed"; return 1; fi
  got="$(core_sha256 "$tmp/src.tgz")"
  if [[ "$got" != "$sha" ]]; then rm -rf -- "$tmp"; log_err "SHA-256 mismatch for badvpn source"; return 1; fi
  while IFS= read -r n; do
    [[ "$n" == /* || "$n" == *..* ]] && { rm -rf -- "$tmp"; log_err "unsafe path in source archive"; return 1; }
  done < <(tar -tzf "$tmp/src.tgz")
  mkdir -p "$tmp/src" "$tmp/build"
  tar -xzf "$tmp/src.tgz" -C "$tmp/src" --strip-components=1 --no-same-owner --no-same-permissions || { rm -rf -- "$tmp"; return 1; }
  if ! (cd "$tmp/build" && cmake "$tmp/src" -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_C_FLAGS=-std=gnu99 >/dev/null 2>&1 && make -j"$(nproc 2>/dev/null || echo 1)" >/dev/null 2>&1); then
    rm -rf -- "$tmp"
    log_err "building badvpn-udpgw failed"
    return 1
  fi
  mkdir -p "$SSHUDP_INSTALL_DIR/udpgw"
  install -m 0755 "$tmp/build/udpgw/badvpn-udpgw" "$SSHUDP_INSTALL_DIR/udpgw/badvpn-udpgw" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$tmp"
  ev "udpgw built: badvpn $ver"
}

udpgw_enable() {
  need_root
  local port="${1:-$(cfg_get UDPGW_PORT)}"
  valid_port "$port" || die "invalid UDPGW port"
  if ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" { f = 1 } END { exit f ? 0 : 1 }' && ! svc_is_active "$SVC_UDPGW"; then
    die "TCP port $port is already in use by another program"
  fi
  if [[ -z "$(udpgw_bin)" ]]; then
    udpgw_build || die "could not build UDPGW (nothing was changed)"
  fi
  service_user_ensure
  cfg_set UDPGW_PORT "$port" && cfg_set UDPGW_ENABLED yes || return 1
  render_unit "$SSHUDP_INSTALL_DIR/systemd/$SVC_UDPGW" "$SSHUDP_SYSTEMD_DIR/$SVC_UDPGW" || return 1
  _sc daemon-reload
  _sc enable --now "$SVC_UDPGW" >/dev/null 2>&1 || die "could not start $SVC_UDPGW"
  ev "udpgw enabled on 127.0.0.1:$port"
  log_ok "UDPGW listening on 127.0.0.1:$port (client option: UDPGW 127.0.0.1:$port)"
}

udpgw_disable() {
  need_root
  if have_systemd; then
    systemctl disable --now "$SVC_UDPGW" >/dev/null 2>&1 || true
  fi
  rm -f -- "$SSHUDP_SYSTEMD_DIR/$SVC_UDPGW"
  _sc daemon-reload
  cfg_set UDPGW_ENABLED no || true
  ev "udpgw disabled"
  log_ok "UDPGW disabled (the built binary and any build tools were left in place)"
}

udpgw_status() {
  local port
  port="$(cfg_get UDPGW_PORT)"
  printf 'Enabled : %s\n' "$(cfg_get UDPGW_ENABLED)"
  printf 'Port    : 127.0.0.1:%s\n' "$port"
  printf 'Service : %s\n' "$(svc_state "$SVC_UDPGW")"
  printf 'Binary  : %s\n' "$(udpgw_bin || true)"
  echo "Note    : optional; only for apps that tunnel UDP through SSH (not needed for UDP Custom itself)."
}

# ---------------------------------------------------------------- fail2ban --
F2B_JAIL="/etc/fail2ban/jail.d/ssh-udp-custom.local"

fail2ban_enable() {
  need_root
  local sp ign
  sp="$(cfg_get SSH_PORT)"
  if ! have fail2ban-client; then
    confirm "fail2ban is not installed. Install it now?" n || { log_info "cancelled"; return 0; }
    apt_install fail2ban ||
      die "could not install fail2ban"
  fi
  # Tunnel sessions reach sshd from 127.0.0.1 (the UDP relay), so loopback MUST be
  # ignored or one bad password could ban every tunnel user. The admin's own
  # current address is ignored too so this can never lock the administrator out.
  local backend="auto"
  if [[ ! -e /var/log/auth.log ]]; then # journald-only systems (default on current Ubuntu)
    backend="systemd"
    python3 -c "import systemd.journal" 2>/dev/null || apt_install python3-systemd || die "could not install python3-systemd"
  fi
  ign="127.0.0.0/8 ::1"
  if [[ "${SSH_CONNECTION:-}" =~ ^([0-9a-fA-F.:]+)\  ]]; then ign+=" ${BASH_REMATCH[1]}"; fi
  {
    echo "# Managed by ssh-udp-custom-server. Conservative SSH-only settings."
    echo "[DEFAULT]"
    echo "ignoreip = $ign"
    echo
    echo "[sshd]"
    echo "enabled  = true"
    echo "backend  = $backend"
    echo "port     = $sp"
    echo "maxretry = 8"
    echo "findtime = 10m"
    echo "bantime  = 15m"
  } | atomic_write "$F2B_JAIL" 0644 root:root || return 1
  if fail2ban-client -t >/dev/null 2>&1; then
    _sc enable --now fail2ban >/dev/null 2>&1 || true
    _sc restart fail2ban >/dev/null 2>&1 || true
    ev "fail2ban jail installed"
    log_ok "fail2ban enabled for sshd (8 failures / 10 min -> 15 min ban; loopback and your current IP are exempt)"
  else
    rm -f -- "$F2B_JAIL"
    die "fail2ban rejected the configuration; nothing was changed"
  fi
}

fail2ban_disable() {
  need_root
  rm -f -- "$F2B_JAIL"
  if have fail2ban-client && have_systemd && systemctl is-active --quiet fail2ban; then
    systemctl restart fail2ban >/dev/null 2>&1 || true
  fi
  log_ok "removed our fail2ban settings (fail2ban itself was left installed)"
}

fail2ban_status() {
  if [[ -e "$F2B_JAIL" ]]; then echo "Our jail file: present ($F2B_JAIL)"; else echo "Our jail file: not installed"; fi
  if have fail2ban-client; then
    fail2ban-client status sshd 2>/dev/null || echo "sshd jail not active"
  else
    echo "fail2ban is not installed (optional)"
  fi
}

# apt_install PKG... - install without recommends; refresh package lists once if needed.
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1 && return 0
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1
}
