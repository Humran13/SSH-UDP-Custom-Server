# shellcheck shell=bash
# firewall.sh - project-owned firewall rules.
#
# Design rules (see docs/ARCHITECTURE.md):
#  * We never flush, reset, disable or replace anything we did not create.
#  * nftables: everything lives in our own table "sshudp"; removal = delete that table.
#  * iptables: everything lives in our own chains SSHUDP_PRE / SSHUDP_IN / SSHUDP_OUT,
#    referenced by one jump rule each; removal = delete the jumps, flush+delete our chains.
#  * UFW (if active): one "allow <listen-port>/udp" rule, recorded so that only
#    a rule WE added is removed later. The range redirect happens in PREROUTING
#    (before UFW's INPUT filtering), so UFW only ever needs the listen port.
#  * The redirect only matches packets arriving on a non-loopback interface.

FW_STATE_FILE="$SSHUDP_STATE_SUB/firewall.state"
NFT_TABLE="sshudp"
IPT_PRE="SSHUDP_PRE"
IPT_IN="SSHUDP_IN"
IPT_OUT="SSHUDP_OUT"

fw_state_get() { kv_get "$FW_STATE_FILE" "$1" "${2:-}"; }
fw_state_set() { kv_set "$FW_STATE_FILE" "$1" "$2"; }

ufw_active() {
  have ufw || return 1
  ufw status 2>/dev/null | head -1 | grep -qi '^Status: active'
}

nft_usable() {
  have nft || return 1
  nft list tables >/dev/null 2>&1
}

ipt_bins() { # iptables binaries that work on this host
  local b
  for b in iptables ip6tables; do
    have "$b" && "$b" -w -t nat -S >/dev/null 2>&1 && printf '%s\n' "$b"
  done
}

fw_backend() { # resolves FIREWALL_MODE=auto
  local mode
  mode="$(cfg_get FIREWALL_MODE)"
  case "$mode" in
    nft) nft_usable && { echo nft; return; } ;;
    iptables) [[ -n "$(ipt_bins)" ]] && { echo iptables; return; } ;;
    none) echo none; return ;;
    auto)
      if nft_usable; then echo nft; return; fi
      if [[ -n "$(ipt_bins)" ]]; then echo iptables; return; fi
      ;;
  esac
  echo none
}

# UDP ports that currently have a listener (excluding our own core).
udp_listening_ports() {
  ss -H -lunp 2>/dev/null | awk '
    { n = split($4, a, ":"); p = a[n]
      if (p ~ /^[0-9]+$/ && $0 !~ /"udp-custom"/) print p }' | sort -un
}

# Effective redirect ranges (one "a-b" per line): configured ranges minus
# user exclusions, protected ports, the listen port and live UDP listeners.
fw_effective_ranges() {
  local inc exc extra listen lp
  inc="$(ports_normalize "$(cfg_get UDP_PORTS)")"
  exc="$(cfg_get UDP_EXCLUDE)"
  listen="$(cfg_get UDP_LISTEN_PORT)"
  extra="$SSHUDP_PROTECTED_PORTS,$listen"
  [[ -n "$exc" ]] && extra="$extra,$exc"
  for lp in $(udp_listening_ports); do extra="$extra,$lp"; done
  ports_subtract "$inc" "$(ports_normalize "$extra")"
}

# Listeners that sit inside the configured range (for warnings only).
fw_conflicts() {
  local inc lp
  inc="$(ports_normalize "$(cfg_get UDP_PORTS)")"
  for lp in $(udp_listening_ports); do
    port_in_lines "$lp" "$inc" && printf '%s\n' "$lp"
  done
  return 0
}

_svc_uid() {
  local u
  u="$(cfg_get RUN_AS)"
  id -u "$u" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------- nftables --
_nft_ruleset() { # _nft_ruleset FAMILY RANGES_LINES
  local fam="$1" set lp uid
  set="$(printf '%s\n' "$2" | awk -F- '{ printf "%s%s", (n++ ? ", " : ""), ($1 == $2 ? $1 : $1 "-" $2) }')"
  lp="$(cfg_get UDP_LISTEN_PORT)"
  uid="$(_svc_uid)"
  local rule="# (no ports to redirect)"
  [[ -n "$set" ]] && rule="iifname != \"lo\" udp dport { $set } counter redirect to :$lp"
  cat <<EOF
table $fam $NFT_TABLE
delete table $fam $NFT_TABLE
table $fam $NFT_TABLE {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
    $rule
  }
  chain tx_stats {
    type filter hook output priority 0; policy accept;
    meta skuid $uid udp sport $lp counter
  }
}
EOF
}

_nft_apply() {
  local ranges="$1" fam rs
  for fam in inet ip; do
    rs="$(_nft_ruleset "$fam" "$ranges")"
    if nft -c -f /dev/stdin <<<"$rs" >/dev/null 2>&1 && nft -f /dev/stdin <<<"$rs" 2>/dev/null; then
      fw_state_set NFT_FAMILY "$fam"
      # Without a NAT-capable inet family (old kernels) the IPv6 side is skipped.
      return 0
    fi
  done
  return 1
}

_nft_remove() {
  local fam
  for fam in inet ip ip6; do
    nft list table "$fam" "$NFT_TABLE" >/dev/null 2>&1 && nft delete table "$fam" "$NFT_TABLE" 2>/dev/null || true
  done
}

_nft_present() {
  local fam
  for fam in inet ip; do
    nft list table "$fam" "$NFT_TABLE" >/dev/null 2>&1 && return 0
  done
  return 1
}

# --------------------------------------------------------------- iptables --
_ipt_apply() {
  local ranges="$1" b r lo hi lp uid
  lp="$(cfg_get UDP_LISTEN_PORT)"
  uid="$(_svc_uid)"
  for b in $(ipt_bins); do
    "$b" -w -t nat -N "$IPT_PRE" 2>/dev/null || "$b" -w -t nat -F "$IPT_PRE"
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      lo="${r%-*}"
      hi="${r#*-}"
      "$b" -w -t nat -A "$IPT_PRE" -p udp --dport "$lo:$hi" -j REDIRECT --to-ports "$lp"
    done <<<"$ranges"
    "$b" -w -t nat -C PREROUTING ! -i lo -j "$IPT_PRE" 2>/dev/null ||
      "$b" -w -t nat -I PREROUTING 1 ! -i lo -j "$IPT_PRE"
    # INPUT accept for the listen port and a TX counter, both in our own chains.
    "$b" -w -N "$IPT_IN" 2>/dev/null || "$b" -w -F "$IPT_IN"
    "$b" -w -A "$IPT_IN" -p udp --dport "$lp" -j ACCEPT
    "$b" -w -C INPUT -j "$IPT_IN" 2>/dev/null || "$b" -w -I INPUT 1 -j "$IPT_IN"
    "$b" -w -N "$IPT_OUT" 2>/dev/null || "$b" -w -F "$IPT_OUT"
    "$b" -w -A "$IPT_OUT" -p udp --sport "$lp" -m owner --uid-owner "$uid" 2>/dev/null ||
      "$b" -w -A "$IPT_OUT" -p udp --sport "$lp"
    "$b" -w -C OUTPUT -j "$IPT_OUT" 2>/dev/null || "$b" -w -I OUTPUT 1 -j "$IPT_OUT"
  done
  [[ -n "$(ipt_bins)" ]]
}

_ipt_remove() {
  local b
  for b in $(ipt_bins); do
    while "$b" -w -t nat -D PREROUTING ! -i lo -j "$IPT_PRE" 2>/dev/null; do :; done
    "$b" -w -t nat -F "$IPT_PRE" 2>/dev/null && "$b" -w -t nat -X "$IPT_PRE" 2>/dev/null || true
    while "$b" -w -D INPUT -j "$IPT_IN" 2>/dev/null; do :; done
    "$b" -w -F "$IPT_IN" 2>/dev/null && "$b" -w -X "$IPT_IN" 2>/dev/null || true
    while "$b" -w -D OUTPUT -j "$IPT_OUT" 2>/dev/null; do :; done
    "$b" -w -F "$IPT_OUT" 2>/dev/null && "$b" -w -X "$IPT_OUT" 2>/dev/null || true
  done
}

_ipt_present() {
  local b
  for b in $(ipt_bins); do
    "$b" -w -t nat -S "$IPT_PRE" >/dev/null 2>&1 && return 0
  done
  return 1
}

# -------------------------------------------------------------------- UFW --
_ufw_rule_exists() { # is "<port>/udp ALLOW" already present?
  ufw status 2>/dev/null | grep -Eq "^$1/udp[[:space:]]+ALLOW"
}


_ufw_remove() {
  local r
  r="$(fw_state_get UFW_RULE)"
  [[ -n "$r" ]] || return 0
  if [[ "$(fw_state_get UFW_PREEXISTING)" == "no" ]] && have ufw; then
    ufw delete allow "$r" >/dev/null 2>&1 || true
  fi
  fw_state_set UFW_RULE ""
}

# ---------------------------------------------------------------- public ---
# fw_apply: (re)create runtime rules. Safe to run repeatedly.
fw_apply() {
  local backend ranges lp
  mkdir -p "$SSHUDP_STATE_SUB"
  backend="$(fw_backend)"
  lp="$(cfg_get UDP_LISTEN_PORT)"
  ranges="$(fw_effective_ranges)"
  if [[ "$backend" == "none" ]]; then
    log_warn "no usable firewall backend (nft/iptables); range redirect NOT active"
    fw_state_set BACKEND none
    return 0
  fi
  if [[ -z "$ranges" ]]; then
    log_warn "no ports left to redirect after exclusions"
  fi
  # Runtime rules are rebuilt from scratch, but only our own objects.
  fw_remove_runtime
  case "$backend" in
    nft)
      if ! _nft_apply "$ranges"; then
        [[ -n "$(ipt_bins)" ]] || { log_err "could not load nftables rules"; return 1; }
        log_warn "nftables rules could not be loaded here; falling back to iptables"
        backend=iptables
        _ipt_apply "$ranges" || { log_err "could not load iptables rules"; return 1; }
      fi
      ;;
    iptables) _ipt_apply "$ranges" || { log_err "could not load iptables rules"; return 1; } ;;
  esac
  _ufw_apply "$lp" || log_warn "could not add UFW rule for $lp/udp"
  fw_state_set BACKEND "$backend"
  fw_state_set RANGES "$(printf '%s\n' "$ranges" | ports_pretty)"
  fw_state_set LISTEN_PORT "$lp"
  ev "firewall applied: backend=$backend ranges=$(fw_state_get RANGES)"
}

# fw_remove_runtime: remove only the runtime redirect objects (keeps UFW rule).
fw_remove_runtime() {
  if have nft; then _nft_remove; fi
  _ipt_remove
}

# fw_purge: remove everything this project ever added (uninstall/disable).
fw_purge() {
  fw_remove_runtime
  _ufw_remove
  rm -f -- "$FW_STATE_FILE"
  ev "firewall rules removed"
}

fw_rules_present() {
  case "$(fw_state_get BACKEND "$(fw_backend)")" in
    nft) _nft_present ;;
    iptables) _ipt_present ;;
    none) return 0 ;;
    *) return 1 ;;
  esac
}

fw_ufw_rule_present() {
  local r
  ufw_active || return 0
  r="$(fw_state_get UFW_RULE)"
  [[ -n "$r" ]] && _ufw_rule_exists "${r%/udp}"
}

# fw_stats -> "RX_PKTS RX_BYTES TX_PKTS TX_BYTES" since rules were loaded
fw_stats() {
  local backend fam out rx tx
  backend="$(fw_state_get BACKEND)"
  case "$backend" in
    nft)
      fam="$(fw_state_get NFT_FAMILY inet)"
      out="$(nft list table "$fam" "$NFT_TABLE" 2>/dev/null)" || { echo "0 0 0 0"; return; }
      rx="$(awk '/redirect to/ && match($0, /counter packets [0-9]+ bytes [0-9]+/) { split(substr($0, RSTART, RLENGTH), a, " "); print a[3], a[5] }' <<<"$out")"
      tx="$(awk '/skuid/ && match($0, /counter packets [0-9]+ bytes [0-9]+/) { split(substr($0, RSTART, RLENGTH), a, " "); print a[3], a[5] }' <<<"$out")"
      ;;
    iptables)
      rx="$(iptables -w -t nat -L "$IPT_PRE" -v -x -n 2>/dev/null | awk 'NR > 2 { p += $1; b += $2 } END { print p + 0, b + 0 }')"
      tx="$(iptables -w -L "$IPT_OUT" -v -x -n 2>/dev/null | awk 'NR > 2 { p += $1; b += $2 } END { print p + 0, b + 0 }')"
      ;;
    *) echo "0 0 0 0"; return ;;
  esac
  echo "${rx:-0 0} ${tx:-0 0}"
}

fw_describe() { # human readable summary for the Firewall menu
  local backend
  backend="$(fw_state_get BACKEND "$(fw_backend)")"
  printf 'Backend        : %s\n' "$backend"
  printf 'UFW            : %s\n' "$(ufw_active && echo active || echo 'not active')"
  printf 'Listen port    : %s/udp\n' "$(cfg_get UDP_LISTEN_PORT)"
  printf 'Configured     : %s (exclude: %s)\n' "$(cfg_get UDP_PORTS)" "$(cfg_get UDP_EXCLUDE)"
  printf 'Redirected     : %s\n' "$(fw_state_get RANGES '-')"
  printf 'Rules present  : %s\n' "$(fw_rules_present && echo yes || echo NO)"
  printf 'Protected ports: %s (never redirected)\n' "$SSHUDP_PROTECTED_PORTS"
}

# Ensure the UFW allow rule exists. State is only trusted together with reality:
# if an administrator deleted the rule, it is re-created (as ours).
_ufw_apply() {
  local lp="$1"
  ufw_active || return 0
  if _ufw_rule_exists "$lp"; then
    if [[ "$(fw_state_get UFW_RULE)" != "$lp/udp" ]]; then
      fw_state_set UFW_RULE "$lp/udp"
      fw_state_set UFW_PREEXISTING yes # existed before us: never delete it
    fi
    return 0
  fi
  ufw allow "$lp/udp" comment 'ssh-udp-custom' >/dev/null || return 1
  fw_state_set UFW_RULE "$lp/udp"
  fw_state_set UFW_PREEXISTING no
}
