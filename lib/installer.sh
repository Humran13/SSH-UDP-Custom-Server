# shellcheck shell=bash
# installer.sh - installation logic (sourced by install.sh after the release
# has been downloaded and verified, or by a local checkout in tests).
#
# Guarantees: root only; no dist-upgrade; never disables/flushes firewalls;
# never overwrites sshd_config; sshd only reloaded after `sshd -t` passes;
# rollback of everything created by a failed FIRST install.

INST_ROLLBACK=()
INST_FRESH=1

_rb() { INST_ROLLBACK+=("$1"); } # register an undo action (evaluated by name only)

installer_rollback() {
  local i
  INST_DONE=1
  trap - EXIT INT TERM
  log_warn "installation failed - undoing changes made by this run"
  for ((i = ${#INST_ROLLBACK[@]} - 1; i >= 0; i--)); do
    case "${INST_ROLLBACK[$i]}" in
      units) units_remove ;;
      firewall) fw_purge ;;
      sshd) sshd_unconfigure ;;
      sysctl) sysctl_restore ;;
      files) rm_project_path "$SSHUDP_INSTALL_DIR"; rm -f -- "$SSHUDP_BIN_LINK" ;;
      data) rm_project_path "$SSHUDP_CONF_DIR" "$SSHUDP_STATE_DIR" ;;
      svcuser) userdel "$SSHUDP_SVC_USER" >/dev/null 2>&1 || true ;;
      group) groupdel "$SSHUDP_GROUP" >/dev/null 2>&1 || true ;;
    esac
  done
  log_warn "rollback finished; the system is as it was before (OpenSSH untouched)"
}

_step() { # _step NAME -- honours SSHUDP_FAIL_AT for interruption tests
  if [[ "${SSHUDP_FAIL_AT:-}" == "$1" ]]; then
    log_err "simulated failure at step: $1"
    return 1
  fi
  return 0
}

inst_preflight() {
  need_root
  platform_check || exit 1
  have_systemd || die "systemd is required (PID 1 is not systemd)"
  local free
  free="$(df -Pm /usr/local 2>/dev/null | awk 'NR==2 { print $4 }')"
  [[ "$free" =~ ^[0-9]+$ ]] && ((free < 100)) && die "not enough disk space in /usr/local (${free} MiB free, 100 needed)"
  # Network: fail fast BEFORE modifying anything.
  if ! curl -fsS --max-time 10 -o /dev/null --proto "$(_curl_proto)" "$(upstream_get CORE_URL)" -r 0-0 2>/dev/null &&
    [[ "${SSHUDP_TESTING:-}" != "1" ]]; then
    die "cannot reach the upstream download host (raw.githubusercontent.com) - check network/DNS"
  fi
}

inst_dependencies() {
  local missing=() cmd
  # command -> package
  declare -A need=([curl]=curl [ss]=iproute2 [ip]=iproute2 [ps]=procps [flock]=util-linux
    [useradd]=passwd [chpasswd]=passwd [tar]=tar [awk]=gawk [sha256sum]=coreutils)
  for cmd in "${!need[@]}"; do
    have "$cmd" || [[ -x "/usr/sbin/$cmd" ]] || missing+=("${need[$cmd]}")
  done
  [[ -x /usr/sbin/sshd ]] || have sshd || missing+=(openssh-server)
  # A firewall tool: keep what exists; only if NEITHER exists install iptables.
  # (We never install the 'nftables' package: on some releases it enables a
  # boot-time 'flush ruleset' service that would wipe other firewalls.)
  if ! have nft && ! have iptables; then missing+=(iptables); fi
  [[ -e /lib/x86_64-linux-gnu/libpam.so.0 || -e /usr/lib/x86_64-linux-gnu/libpam.so.0 ]] || missing+=(libpam0g)
  if ((${#missing[@]} == 0)); then
    log_ok "dependencies already satisfied"
    return 0
  fi
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  log_info "installing packages: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || log_warn "apt-get update reported problems"
  apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null || die "package installation failed"
}

# Interactive questions for Advanced Install; every answer is validated.
inst_advanced_prompts() {
  local v
  echo
  echo "${C_BLD}Advanced install${C_RST} - press Enter to accept the default in [brackets]."
  while :; do
    ask v "SSH port of your OpenSSH server" "$(cfg_get SSH_PORT)"
    valid_port "$v" && { cfg_set SSH_PORT "$v"; break; }
    log_warn "invalid port"
  done
  while :; do
    ask v "UDP listen port (used by the core; also allowed in UFW)" "$(cfg_get UDP_LISTEN_PORT)"
    valid_port "$v" && { cfg_set UDP_LISTEN_PORT "$v"; break; }
    log_warn "invalid port"
  done
  while :; do
    ask v "UDP port range clients may use (e.g. 20000-50000 or 10000-20000,30000-40000)" "$(cfg_get UDP_PORTS)"
    valid_port_spec "$v" && { cfg_set UDP_PORTS "$v"; break; }
    log_warn "invalid range list"
  done
  while :; do
    ask v "Ports to EXCLUDE from the range (comma list, 'none' for nothing)" "$(cfg_get UDP_EXCLUDE)"
    [[ "$v" == none ]] && v=""
    if [[ -z "$v" ]] || valid_port_spec "$v"; then cfg_set UDP_EXCLUDE "$v"; break; fi
    log_warn "invalid port list"
  done
  while :; do
    ask v "Hostname/domain for clients (blank = use IP)" ""
    [[ -z "$v" ]] || valid_hostname "$v" || { log_warn "invalid hostname"; continue; }
    cfg_set SERVER_HOST "$v"
    break
  done
  ask v "Public IP override (blank = auto-detect)" ""
  if [[ -n "$v" ]]; then
    if valid_ipv4 "$v" || valid_ipv6 "$v"; then cfg_set SERVER_IP "$v"; else log_warn "invalid IP ignored"; fi
  fi
  ask v "Firewall integration: auto / nft / iptables / none" "$(cfg_get FIREWALL_MODE)"
  valid_choice "$v" auto nft iptables none && cfg_set FIREWALL_MODE "$v"
  ask v "Default max simultaneous logins per user (0 = unlimited)" "$(cfg_get DEFAULT_MAXLOGINS)"
  valid_maxlogins "$v" && cfg_set DEFAULT_MAXLOGINS "$v"
  ask v "Run the UDP core as: sshudp (dedicated user, recommended) / root" "$(cfg_get RUN_AS)"
  valid_choice "$v" sshudp root && cfg_set RUN_AS "$v"
  ask v "Enable optional UDPGW (badvpn) for UDP-over-SSH apps? yes/no" "no"
  [[ "$v" == yes ]] && cfg_set UDPGW_ENABLED yes
  cfg_set INSTALL_MODE advanced
}

inst_detect_settings() {
  local ip sp
  if [[ -z "$(cfg_get SERVER_IP)" ]]; then
    ip="$(detect_public_ipv4 || true)"
    if [[ -n "$ip" ]]; then
      cfg_set SERVER_IP "$ip"
      is_private_ipv4 "$ip" && log_warn "detected address $ip is private - set the public IP later: sshudp config server-ip <ip>"
    else
      log_warn "could not detect the public IP - set it later: sshudp config server-ip <ip>"
    fi
  fi
  if [[ "$(cfg_get INSTALL_MODE)" == quick || ! -s "$SSHUDP_CONF_FILE" ]]; then
    sp="$(detect_sshd_port)"
    cfg_set SSH_PORT "$sp"
  fi
}

# Choose the listen port for a fresh install: keep 36712 unless it is taken.
inst_check_ports() {
  local lp
  lp="$(cfg_get UDP_LISTEN_PORT)"
  if ss -H -lun 2>/dev/null | awk -v p=":$lp" '$4 ~ p"$" { f = 1 } END { exit f ? 0 : 1 }'; then
    if svc_is_active "$SVC_UDP"; then return 0; fi
    log_err "UDP port $lp is already in use by another program."
    log_err "Choose another with the Advanced install, or free the port. Nothing was changed."
    return 1
  fi
}

installer_main() { # installer_main [--quick|--advanced] [--yes]
  local mode="" a
  for a in "$@"; do
    case "$a" in
      --quick) mode=quick ;;
      --advanced) mode=advanced ;;
      --yes | -y) SSHUDP_ASSUME_YES=1 ;;
    esac
  done
  [[ -n "$mode" ]] || mode="${SSHUDP_MODE:-}"
  inst_preflight

  if [[ -z "$mode" ]]; then
    if [[ -t 0 || -r /dev/tty ]]; then
      echo
      echo "${C_BLD}SSH UDP Custom Server${C_RST}  v$(tr -d "[:space:]" <"$SSHUDP_LIB_HOME/../VERSION" 2>/dev/null)"
      echo " 1. Quick Install (recommended)"
      echo " 2. Advanced Install"
      echo " 3. Exit"
      local c
      ask c "Select" "1"
      case "$c" in 1) mode=quick ;; 2) mode=advanced ;; *) echo "Bye."; return 0 ;; esac
    else
      mode=quick
    fi
  fi

  if [[ -d "$SSHUDP_INSTALL_DIR" && -s "$SSHUDP_CONF_FILE" ]]; then
    INST_FRESH=0
    log_info "existing installation found - updating files, keeping your settings and users"
  fi
  lock_acquire_safe
  set -e
  trap 'installer_on_exit' EXIT
  trap 'exit 130' INT TERM

  inst_dependencies
  _step deps || return 1

  # ---- payload -----------------------------------------------------------
  ((INST_FRESH)) && _rb files
  mkdir -p "$SSHUDP_INSTALL_DIR"
  inst_copy_payload || die "could not install program files"
  _step payload || return 1

  # ---- core (download BEFORE touching services/firewall) -----------------
  core_install || die "could not obtain the upstream core"
  _step core || return 1

  # ---- data dirs and config ----------------------------------------------
  ((INST_FRESH)) && _rb data
  ensure_dirs
  if ((INST_FRESH)) || [[ ! -s "$SSHUDP_CONF_FILE" ]]; then
    cfg_write_defaults
    cfg_set INSTALL_MODE "$mode"
    [[ "$mode" == advanced ]] && inst_advanced_prompts
  fi
  inst_detect_settings
  inst_check_ports || return 1
  cfg_set INSTALLED_VERSION "$(sshudp_version)"
  _step config || return 1

  # ---- accounts, sshd, firewall, services ---------------------------------
  if ((INST_FRESH)); then
    getent group "$SSHUDP_GROUP" >/dev/null 2>&1 || _rb group
    getent passwd "$SSHUDP_SVC_USER" >/dev/null 2>&1 || _rb svcuser
  fi
  service_user_ensure || die "could not create the service user"
  ensure_group || die "could not create group $SSHUDP_GROUP"
  _rb sysctl
  sysctl_configure || true
  ((INST_FRESH)) && { _rb units; _rb firewall; _rb sshd; }
  core_json_write || die "could not write the core configuration"
  units_install || die "could not install systemd units"
  _step units || return 1
  sshd_configure || die "could not configure sshd (nothing restarted; your SSH session is safe)"
  _step sshd || return 1
  units_enable_all
  ensure_bin_link || die "could not create the sshudp command"
  if [[ "$(cfg_get UDPGW_ENABLED)" == yes ]]; then udpgw_enable "$(cfg_get UDPGW_PORT)" || log_warn "UDPGW could not be enabled"; fi
  units_start_all || die "services failed to start (see: journalctl -u $SVC_UDP)"
  _step start || return 1

  # ---- health check -------------------------------------------------------
  inst_health_check || die "post-install health check failed"
  INST_DONE=1
  trap - EXIT INT TERM
  set +e
  ev "installed v$(sshudp_version) mode=$mode"
  inst_summary
}

lock_acquire_safe() { mkdir -p "$SSHUDP_STATE_DIR"; chmod 0700 "$SSHUDP_STATE_DIR"; lock_acquire; }


inst_copy_payload() { # copy from the verified source tree (SSHUDP_LIB_HOME/..) into the install dir
  local src
  src="$(cd "$SSHUDP_LIB_HOME/.." && pwd)"
  if [[ "$src" == "$(cd "$SSHUDP_INSTALL_DIR" 2>/dev/null && pwd)" ]]; then return 0; fi
  install_tree "$src"
}

inst_health_check() {
  local i lp
  lp="$(cfg_get UDP_LISTEN_PORT)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if svc_is_active "$SVC_UDP" && _udp_listening "$lp"; then break; fi
    sleep 1
  done
  svc_is_active "$SVC_UDP" || { log_err "UDP service is not running"; return 1; }
  _udp_listening "$lp" || { log_err "UDP port $lp is not listening"; return 1; }
  sshd_block_present || { log_err "sshd policy missing"; return 1; }
  _sshd_test || { log_err "sshd config invalid"; return 1; }
  fw_rules_present || { log_err "firewall rules missing"; return 1; }
  # Safety: our core must NOT have installed its own blanket capture rule.
  if have iptables && iptables -w -t nat -S PREROUTING 2>/dev/null | grep -Eq -- "--dport 1:65535 .*-j DNAT"; then
    log_err "unexpected blanket UDP DNAT rule detected"
    return 1
  fi
  return 0
}

inst_summary() {
  local ip
  ip="$(cfg_get SERVER_IP)"
  echo
  echo "${C_GRN}SSH UDP Custom Server installed successfully.${C_RST}"
  echo
  echo "  Manager        : sshudp"
  echo "  Status         : sshudp status"
  echo "  Diagnostics    : sshudp doctor"
  echo "  Create user    : sshudp create-user"
  echo "  Configuration  : $SSHUDP_CONF_DIR/"
  echo
  printf '  Server %s   SSH port %s   UDP ports %s\n' "${ip:-?}" "$(cfg_get SSH_PORT)" "$(cfg_get UDP_PORTS)"
  echo
  echo "Client compatibility with HTTP Custom has not been verified end-to-end;"
  echo "see docs/CLIENT-SETUP.md."
}

INST_DONE=0
installer_on_exit() {
  local rc=$?
  [[ "$BASHPID" == "$$" ]] || return 0 # only the main shell may roll back
  ((INST_DONE)) && return 0
  ((rc == 0)) && rc=1
  trap - EXIT INT TERM
  if ((INST_FRESH)); then
    installer_rollback
  else
    log_err "the re-install failed part-way; your previous data is untouched. Try: sudo sshudp repair"
  fi
  exit "$rc"
}
