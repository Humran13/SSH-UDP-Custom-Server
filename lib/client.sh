# shellcheck shell=bash
# client.sh - account card / client configuration helper.
#
# Only fields that are genuinely part of the setup are shown. We do NOT invent
# share URIs or import files: none is documented for HTTP Custom's UDP mode, so
# none is generated. See docs/CLIENT-SETUP.md.

_box_ascii() { [[ "${SSHUDP_ASCII:-0}" == "1" ]] || ! locale charmap 2>/dev/null | grep -qi 'utf-8'; }

# card TITLE  then "label|value" lines on stdin
card() {
  local title="$1" line label value w=50 inner i
  local tl='╔' tr='╗' bl='╚' br='╝' hz='═' vt='║' ml='╠' mr='╣'
  if _box_ascii; then tl='+' tr='+' bl='+' br='+' hz='-' vt='|' ml='+' mr='+'; fi
  inner=$((w - 2))
  local bar=""
  for ((i = 0; i < inner; i++)); do bar+="$hz"; done
  printf '%s%s%s\n' "$tl" "$bar" "$tr"
  local pad=$(((inner - ${#title}) / 2))
  printf '%s%*s%s%*s%s\n' "$vt" "$pad" "" "$title" "$((inner - pad - ${#title}))" "" "$vt"
  printf '%s%s%s\n' "$ml" "$bar" "$mr"
  while IFS= read -r line; do
    label="${line%%|*}"
    value="${line#*|}"
    local text
    text=" $(printf '%-11s: %s' "$label" "$value")"
    if ((${#text} > inner - 1)); then text="${text:0:$((inner - 2))}…"; _box_ascii && text="${text:0:$((inner - 3))}..."; fi
    printf '%s%s%*s%s\n' "$vt" "$text" "$((inner - ${#text}))" "" "$vt"
  done
  printf '%s%s%s\n' "$bl" "$bar" "$br"
}

# client_show USERNAME [PASSWORD]
#   PASSWORD is only ever passed right after creation/reset; otherwise a placeholder is shown.
client_show() {
  local u="$1" pw="${2:-}" host ip ports exp shown_pw
  local ssh_port udpgw
  user_require_managed "$u" || return 1
  host="$(cfg_get SERVER_HOST)"
  ip="$(cfg_get SERVER_IP)"
  [[ -n "$ip" ]] || ip="$(detect_public_ipv4 || echo '')"
  ports="$(cfg_get UDP_PORTS)"
  exp="$(meta_get "$u" EXPIRES)"
  ssh_port="$(cfg_get SSH_PORT)"
  shown_pw="${pw:-(not stored - use reset to set a new one)}"
  {
    printf 'Server|%s\n' "${host:-$ip}"
    [[ -n "$host" && -n "$ip" ]] && printf 'Server IP|%s\n' "$ip"
    printf 'Username|%s\n' "$u"
    printf 'Password|%s\n' "$shown_pw"
    printf 'SSH Port|%s\n' "$ssh_port"
    printf 'UDP Ports|%s\n' "$ports"
    printf 'Expires|%s\n' "$exp"
    [[ "$(meta_get "$u" MAXLOGINS 0)" != 0 ]] && printf 'Max logins|%s\n' "$(meta_get "$u" MAXLOGINS)"
  } | card "SSH UDP CUSTOM ACCOUNT"
  udpgw=""
  [[ "$(cfg_get UDPGW_ENABLED)" == "yes" ]] && udpgw="127.0.0.1:$(cfg_get UDPGW_PORT)"
  echo
  echo "Client setup (HTTP Custom / UDP Custom compatible apps):"
  echo "  Tunnel type : SSH  +  UDP Custom"
  printf '  Account line: %s:%s@%s:%s\n' "${host:-$ip}" "$ports" "$u" "${pw:-PASSWORD}"
  echo "                (format used in public HTTP Custom guides - see docs/CLIENT-SETUP.md)"
  [[ -n "$udpgw" ]] && echo "  UDPGW       : $udpgw (only if the app's UDPGW option is enabled)"
  echo "  Note        : UDP buffer/RX/TX values in the app are client tuning, not server settings."
  [[ -z "$pw" ]] || echo "  ${C_YEL}Save the password now - it is not stored on the server.${C_RST}"
}
