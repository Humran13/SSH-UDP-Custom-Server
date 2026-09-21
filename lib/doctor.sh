# shellcheck shell=bash
# doctor.sh - read-only diagnostics. Never modifies the system.

DOC_PASS=0 DOC_WARN=0 DOC_FAIL=0

_d() { # _d LEVEL MESSAGE [FIX]
  local lvl="$1" msg="$2" fix="${3:-}" tag
  case "$lvl" in
    pass) tag="${C_GRN}[PASS]${C_RST}"; DOC_PASS=$((DOC_PASS + 1)) ;;
    warn) tag="${C_YEL}[WARN]${C_RST}"; DOC_WARN=$((DOC_WARN + 1)) ;;
    *) tag="${C_RED}[FAIL]${C_RST}"; DOC_FAIL=$((DOC_FAIL + 1)) ;;
  esac
  printf '%s %s\n' "$tag" "$msg"
  [[ "$lvl" != pass && -n "$fix" ]] && printf '       fix: %s\n' "$fix"
  return 0
}

_udp_listening() { ss -H -lunp 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" { f = 1 } END { exit f ? 0 : 1 }'; }
_tcp_listening() { ss -H -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" { f = 1 } END { exit f ? 0 : 1 }'; }

doctor_run() {
  local quick=0 a lp sp ip host ver id
  for a in "$@"; do [[ "$a" == "--quick" ]] && quick=1; done
  DOC_PASS=0 DOC_WARN=0 DOC_FAIL=0
  lp="$(cfg_get UDP_LISTEN_PORT)"
  sp="$(cfg_get SSH_PORT)"

  echo "${C_BLD}SSH UDP Custom - diagnostics${C_RST}  (manager $(sshudp_version))"
  echo

  # --- platform --------------------------------------------------------
  if ((!quick)); then
    ver="$(os_version)"; id="$(os_id)"
    if platform_check >/dev/null 2>&1; then
      _d pass "Supported OS: $(os_pretty)"
    else
      _d fail "Unsupported OS/architecture: ${id:-?} ${ver:-?} $(uname -m)" "see README support matrix"
    fi
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      _d pass "Running as root"
    else
      _d warn "Not running as root - some checks are limited" "run: sudo sshudp doctor"
    fi
    local m
    for m in curl ss ps tar flock useradd usermod userdel chpasswd getent sshd ip sha256sum; do
      if have "$m" || [[ -x "/usr/sbin/$m" ]]; then :; else
        _d fail "Required command missing: $m" "sudo apt-get install -y curl iproute2 procps util-linux passwd openssh-server coreutils tar"
      fi
    done
    if have nft || have iptables; then
      _d pass "Firewall tooling available (nft: $(have nft && echo yes || echo no), iptables: $(have iptables && echo yes || echo no))"
    else
      _d fail "Neither nft nor iptables found" "sudo apt-get install -y iptables"
    fi
  fi

  # --- installation integrity ------------------------------------------
  if [[ -x "$CORE_BIN" ]]; then
    _d pass "UDP core binary present ($CORE_BIN)"
    if core_verify_installed; then
      _d pass "UDP core checksum matches recorded value (version $(core_installed_version))"
    else
      _d fail "UDP core checksum does not match the recorded value" "sudo sshudp core-update"
    fi
  else
    _d fail "UDP core binary missing" "sudo sshudp repair"
  fi

  if [[ -r "$SSHUDP_CONF_FILE" ]] && cfg_file_ok "$SSHUDP_CONF_FILE"; then
    _d pass "Configuration file valid ($SSHUDP_CONF_FILE)"
  else
    _d fail "Configuration file missing or invalid" "sudo sshudp repair"
  fi
  if [[ -r "$SSHUDP_CORE_JSON" ]] && [[ "$(core_json_render)" == "$(cat "$SSHUDP_CORE_JSON")" ]]; then
    _d pass "UDP core config matches settings"
  else
    _d warn "UDP core config differs from settings or is missing" "sudo sshudp repair"
  fi

  # --- services --------------------------------------------------------
  if have_systemd; then
    if svc_is_active "$SVC_UDP"; then
      _d pass "UDP service running ($SVC_UDP)"
    else
      _d fail "UDP service not running (state: $(svc_state "$SVC_UDP"))" "sudo sshudp repair   (logs: sshudp logs)"
    fi
    svc_is_enabled "$SVC_UDP" && _d pass "UDP service enabled at boot" ||
      _d warn "UDP service not enabled at boot" "sudo sshudp repair"
    local sn
    sn="$(sshd_service_name)"
    if systemctl is-active --quiet "$sn" 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
      _d pass "SSH daemon running ($sn)"
    else
      _d fail "SSH daemon not running" "sudo systemctl start $sn"
    fi
    if ((!quick)); then
      svc_is_active "$SVC_EXPIRY.timer" && _d pass "Expiry timer active" ||
        _d fail "Expiry timer not active" "sudo sshudp repair"
      svc_is_active "$SVC_LIMITER.timer" && _d pass "Session-limit timer active" ||
        _d warn "Session-limit timer not active" "sudo sshudp repair"
      svc_is_active "$SVC_FW" && _d pass "Firewall unit active ($SVC_FW)" ||
        _d warn "Firewall unit not active" "sudo sshudp repair"
    fi
  else
    _d warn "systemd not available - service checks skipped"
  fi

  # --- sshd ------------------------------------------------------------
  if _sshd_test; then
    _d pass "sshd configuration valid (sshd -t)"
  else
    _d fail "sshd configuration invalid (sshd -t fails)" "run 'sudo sshd -t' and fix the reported error"
  fi
  if sshd_block_present; then
    _d pass "sshd tunnel-account policy installed"
  else
    _d fail "sshd tunnel-account policy missing" "sudo sshudp repair"
  fi
  if ((!quick)); then
    local first eff
    first="$(managed_users | head -1)"
    if [[ -n "$first" ]] && is_managed_user "$first" && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      eff="$("$(command -v sshd || echo /usr/sbin/sshd)" -T -C "user=$first,host=localhost,addr=127.0.0.1" 2>/dev/null)"
      if grep -qi '^passwordauthentication yes' <<<"$eff" && grep -qi '^allowtcpforwarding yes' <<<"$eff" &&
        grep -qi '^permittty no' <<<"$eff"; then
        _d pass "Effective sshd policy for '$first': password + forwarding, no TTY"
      else
        _d fail "Effective sshd policy for '$first' is not as expected" "check for conflicting Match/AllowUsers in /etc/ssh/sshd_config*"
      fi
      if grep -qiE '^(allowusers|allowgroups) ' <<<"$eff" && ! grep -qi "^allowgroups .*$SSHUDP_GROUP" <<<"$eff" &&
        ! grep -qiE "^allowusers .*\b$first\b" <<<"$eff"; then
        _d warn "sshd AllowUsers/AllowGroups may block tunnel accounts" "add group $SSHUDP_GROUP to AllowGroups"
      fi
    fi
  fi

  # --- ports -----------------------------------------------------------
  if _udp_listening "$lp"; then
    _d pass "UDP port $lp listening"
  else
    _d fail "UDP port $lp not listening" "sudo sshudp repair   (logs: sshudp logs)"
  fi
  if _tcp_listening "$sp"; then
    _d pass "SSH port $sp listening"
  else
    _d fail "SSH port $sp not listening (SSH_PORT in config may not match sshd)" "sshudp config ssh-port <port>"
  fi
  if ((!quick)); then
    local conf
    conf="$(fw_conflicts | tr '\n' ' ')"
    if [[ -z "$conf" ]]; then
      _d pass "No other UDP listeners inside the configured range"
    else
      _d warn "Other UDP listeners inside the range: $conf (excluded automatically at rule load)" "sudo sshudp config udp-exclude <ports>  then  sudo sshudp fw apply"
    fi

    # --- firewall ----------------------------------------------------
    if fw_rules_present; then
      _d pass "Firewall redirect rules present (backend: $(fw_state_get BACKEND '?'))"
    else
      _d fail "Firewall redirect rules missing" "sudo sshudp fw apply   (or: sudo sshudp repair)"
    fi
    if ufw_active; then
      fw_ufw_rule_present && _d pass "UFW allows $lp/udp" || _d fail "UFW rule for $lp/udp missing" "sudo sshudp fw apply"
    else
      _d pass "UFW not active (no UFW rule needed)"
    fi
    # The upstream core installs a blanket "all UDP ports" capture rule when run as root.
    if have iptables && iptables -w -t nat -S PREROUTING 2>/dev/null | grep -Eq -- "--dport 1:65535 .*-j DNAT"; then
      _d fail "A foreign rule redirects ALL UDP ports (1:65535) to the core (created by the upstream core run as root)" "sudo sshudp repair; remove the rule with: iptables -t nat -S PREROUTING"
    else
      _d pass "No blanket UDP capture rule (1:65535) present"
    fi
    if have nft && nft list ruleset 2>/dev/null | grep -Eq 'chain input \{' &&
      nft list ruleset 2>/dev/null | grep -Eq 'hook input priority filter; policy drop'; then
      _d warn "An nftables input chain has policy drop - make sure it allows $lp/udp" "add: nft add rule inet filter input udp dport $lp accept   (adapt to your ruleset)"
    fi

    # --- addressing --------------------------------------------------
    host="$(cfg_get SERVER_HOST)"
    ip="$(cfg_get SERVER_IP)"
    local det
    det="$(detect_public_ipv4 || true)"
    if [[ -n "$det" ]]; then
      if is_private_ipv4 "$det"; then
        _d warn "Detected address $det is private (NAT/no public IPv4?)" "sudo sshudp config server-ip <public-ip>"
      else
        _d pass "Public IPv4 detected: $det"
      fi
      [[ -n "$ip" && "$ip" != "$det" ]] && _d warn "Configured server IP ($ip) differs from detected ($det)" "sudo sshudp config server-ip $det"
    else
      _d warn "Could not detect the public IP" "sudo sshudp config server-ip <public-ip>"
    fi
    if [[ -z "$host" ]]; then
      _d warn "Hostname not configured (clients will use the IP)" "sudo sshudp config server-host <domain>   (optional)"
    elif ! valid_ipv4 "$host" && ! valid_ipv6 "$host"; then
      local res
      res="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 { print $1 }')"
      if [[ -z "$res" ]]; then
        _d warn "Hostname $host does not resolve" "create an A record pointing to ${ip:-$det}"
      elif [[ -n "${ip:-$det}" && "$res" != "${ip:-$det}" ]]; then
        _d warn "Hostname $host resolves to $res, not ${ip:-$det}" "fix the DNS A record"
      else
        _d pass "Hostname $host resolves to $res"
      fi
    fi

    # --- filesystem --------------------------------------------------
    local mode
    mode="$(stat -c %a "$SSHUDP_STATE_DIR" 2>/dev/null || echo '?')"
    [[ "$mode" == "700" ]] && _d pass "State directory permissions (700)" ||
      _d warn "State directory mode is $mode (expected 700)" "sudo sshudp repair"
    mode="$(stat -c %a "$SSHUDP_USERS_DIR" 2>/dev/null || echo '?')"
    [[ "$mode" == "700" ]] && _d pass "User metadata permissions (700)" ||
      _d warn "User metadata directory mode is $mode (expected 700)" "sudo sshudp repair"
    if [[ -x "$CORE_BIN" ]] && [[ "$(stat -c %U "$CORE_BIN")" == "root" && "$(stat -c %a "$CORE_BIN")" == "755" ]]; then
      _d pass "Core binary owned by root, mode 755"
    else
      _d warn "Core binary ownership/mode unexpected" "sudo sshudp repair"
    fi
    local free
    free="$(df -Pm "$SSHUDP_STATE_DIR" 2>/dev/null | awk 'NR==2 { print $4 }')"
    if [[ "$free" =~ ^[0-9]+$ ]] && ((free >= 200)); then
      _d pass "Disk space OK (${free} MiB free)"
    else
      _d warn "Low disk space (${free:-?} MiB free)" "free some space"
    fi
    local mem
    mem="$(awk '/MemAvailable/ { printf "%d", $2 / 1024 }' /proc/meminfo)"
    if [[ "$mem" =~ ^[0-9]+$ ]] && ((mem >= 128)); then
      _d pass "Memory OK (${mem} MiB available)"
    else
      _d warn "Low available memory (${mem:-?} MiB)" "the UDP core uses large socket buffers; consider a bigger VPS"
    fi

    # --- accounts ----------------------------------------------------
    local orph exp_unlocked u
    orph="$(orphan_users | tr '\n' ' ')"
    [[ -z "$orph" ]] && _d pass "All managed accounts have matching system accounts" ||
      _d warn "Metadata without a matching system account: $orph" "recreate with 'sshudp create-user' or delete the .meta files"
    exp_unlocked=""
    while IFS= read -r u; do
      [[ -n "$u" ]] && is_managed_user "$u" && user_is_expired "$u" && [[ "$(meta_get "$u" STATUS)" == "active" ]] && exp_unlocked+="$u "
    done < <(managed_users)
    [[ -z "$exp_unlocked" ]] && _d pass "No expired-but-active accounts" ||
      _d warn "Expired accounts still active: $exp_unlocked" "sudo sshudp cleanup-expired"
    if have_systemd && journalctl -u "$SVC_UDP" --since "-1h" -p err --no-pager -q 2>/dev/null | grep -q .; then
      _d warn "UDP service logged errors in the last hour" "sshudp logs udp"
    else
      _d pass "No recent UDP service errors"
    fi

    # --- network -----------------------------------------------------
    if curl -fsS --max-time 8 -o /dev/null --proto '=https' https://github.com 2>/dev/null; then
      _d pass "Outbound HTTPS connectivity (github.com reachable)"
    else
      _d warn "Cannot reach github.com over HTTPS (updates unavailable)" "check DNS/outbound firewall"
    fi
  fi

  echo
  printf 'Summary: %s%d passed%s, %s%d warnings%s, %s%d failed%s\n' \
    "$C_GRN" "$DOC_PASS" "$C_RST" "$C_YEL" "$DOC_WARN" "$C_RST" "$C_RED" "$DOC_FAIL" "$C_RST"
  ((DOC_FAIL == 0))
}
