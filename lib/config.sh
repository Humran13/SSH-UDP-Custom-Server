# shellcheck shell=bash
# config.sh - project configuration (/etc/ssh-udp-custom/config.conf).
# The file is parsed as plain KEY=VALUE data. It is never sourced or eval'd.

# Keys and defaults. Adding a key requires an entry here AND in cfg_validate.
declare -gA CFG_DEFAULTS=(
  [SERVER_HOST]=""
  [SERVER_IP]=""
  [SSH_PORT]="22"
  [UDP_LISTEN_PORT]="36712"
  [UDP_PORTS]="20000-50000"
  [UDP_EXCLUDE]="53,123"
  [STREAM_BUFFER]="33554432"
  [RECEIVE_BUFFER]="83886080"
  [RUN_AS]="sshudp"
  [FIREWALL_MODE]="auto"
  [UDPGW_ENABLED]="no"
  [UDPGW_PORT]="7300"
  [DEFAULT_MAXLOGINS]="0"
  [INSTALLED_VERSION]=""
  [INSTALL_MODE]="quick"
)

# Ports that are never redirected, whatever the administrator asks for:
# DNS, DHCP, TFTP, NTP, NetBIOS, SNMP, HTTPS/QUIC, IKE, DoT/DoQ, OpenVPN,
# L2TP, IPsec NAT-T, mDNS, WireGuard.
SSHUDP_PROTECTED_PORTS="53,67,68,69,123,137,138,161,443,500,853,1194,1701,4500,5353,51820"

cfg_validate() { # cfg_validate KEY VALUE
  local k="$1" v="$2"
  case "$k" in
    SERVER_HOST) [[ -z "$v" ]] || valid_hostname "$v" || valid_ipv4 "$v" || valid_ipv6 "$v" ;;
    SERVER_IP) [[ -z "$v" ]] || valid_ipv4 "$v" || valid_ipv6 "$v" ;;
    SSH_PORT | UDP_LISTEN_PORT | UDPGW_PORT) valid_port "$v" ;;
    UDP_PORTS) valid_port_spec "$v" ;;
    UDP_EXCLUDE) [[ -z "$v" ]] || valid_port_spec "$v" ;;
    STREAM_BUFFER | RECEIVE_BUFFER) valid_int "$v" 65536 1073741824 ;;
    RUN_AS) valid_choice "$v" sshudp root ;;
    FIREWALL_MODE) valid_choice "$v" auto nft iptables none ;;
    UDPGW_ENABLED) valid_choice "$v" yes no ;;
    DEFAULT_MAXLOGINS) valid_maxlogins "$v" ;;
    INSTALLED_VERSION) [[ -z "$v" || "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ;;
    INSTALL_MODE) valid_choice "$v" quick advanced ;;
    *) return 1 ;;
  esac
}

cfg_get() { # cfg_get KEY -> value (falls back to the built-in default)
  local k="$1" v
  [[ -n "${CFG_DEFAULTS[$k]+x}" ]] || return 1
  v="$(kv_get "$SSHUDP_CONF_FILE" "$k" "${CFG_DEFAULTS[$k]}")"
  # A damaged/hostile file must never inject an invalid value.
  if cfg_validate "$k" "$v"; then
    printf '%s' "$v"
  else
    printf '%s' "${CFG_DEFAULTS[$k]}"
  fi
}

cfg_set() { # cfg_set KEY VALUE (validated, atomic)
  local k="$1" v="$2"
  if [[ -z "${CFG_DEFAULTS[$k]+x}" ]]; then
    log_err "unknown setting: $k"
    return 1
  fi
  if ! cfg_validate "$k" "$v"; then
    log_err "invalid value for $k"
    return 1
  fi
  kv_set "$SSHUDP_CONF_FILE" "$k" "$v"
}

# cfg_file_ok FILE -> 0 if every non-comment line is a known, valid KEY=VALUE
cfg_file_ok() {
  local f="$1" line k v
  [[ -r "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || return 1
    k="${line%%=*}"
    v="${line#*=}"
    [[ -n "${CFG_DEFAULTS[$k]+x}" ]] || return 1
    cfg_validate "$k" "$v" || return 1
  done <"$f"
  return 0
}

cfg_write_defaults() { # write a complete config file (used by installer)
  local k
  {
    echo "# SSH UDP Custom Server Manager - managed by 'sshudp config'."
    echo "# Plain KEY=VALUE data; this file is never executed."
    for k in SERVER_HOST SERVER_IP SSH_PORT UDP_LISTEN_PORT UDP_PORTS UDP_EXCLUDE \
      STREAM_BUFFER RECEIVE_BUFFER RUN_AS FIREWALL_MODE UDPGW_ENABLED UDPGW_PORT \
      DEFAULT_MAXLOGINS INSTALLED_VERSION INSTALL_MODE; do
      printf '%s=%s\n' "$k" "${CFG_DEFAULTS[$k]}"
    done
  } | atomic_write "$SSHUDP_CONF_FILE" 0644 root:root
}

# Generate the JSON consumed by the upstream core from validated settings only.
core_json_render() {
  local port sb rb
  port="$(cfg_get UDP_LISTEN_PORT)"
  sb="$(cfg_get STREAM_BUFFER)"
  rb="$(cfg_get RECEIVE_BUFFER)"
  printf '{\n  "listen": ":%s",\n  "stream_buffer": %s,\n  "receive_buffer": %s,\n  "auth": {\n    "mode": "passwords"\n  }\n}\n' \
    "$port" "$sb" "$rb"
}

core_json_write() {
  core_json_render | atomic_write "$SSHUDP_CORE_JSON" 0644 root:root
}

# ---------------------------------------------------------------------------
# Server address discovery: several independent endpoints, first valid answer.
# ---------------------------------------------------------------------------
detect_public_ipv4() {
  local eps ep ip
  if [[ -n "${SSHUDP_IP_ENDPOINTS:-}" ]]; then
    eps="$SSHUDP_IP_ENDPOINTS"
  else
    eps="https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://checkip.amazonaws.com https://ipv4.wtfismyip.com/text"
  fi
  for ep in $eps; do
    ip="$(curl -4 -fsS --max-time 5 --proto "$(_curl_proto)" "$ep" 2>/dev/null | tr -d '[:space:]')" || continue
    if valid_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  # Last resort: the address of the default route (may be private behind NAT).
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  if valid_ipv4 "$ip"; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

detect_public_ipv6() {
  local ip
  ip="$(curl -6 -fsS --max-time 4 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')" || return 1
  valid_ipv6 "$ip" && printf '%s' "$ip"
}

is_private_ipv4() {
  [[ "$1" =~ ^(10\.|192\.168\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]
}

# The address clients should use: hostname if set, else configured/detected IP.
server_address() {
  local h ip
  h="$(cfg_get SERVER_HOST)"
  ip="$(cfg_get SERVER_IP)"
  if [[ -n "$h" ]]; then
    printf '%s' "$h"
  elif [[ -n "$ip" ]]; then
    printf '%s' "$ip"
  else
    detect_public_ipv4 || printf '%s' "YOUR_SERVER_IP"
  fi
}
