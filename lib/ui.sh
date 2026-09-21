# shellcheck shell=bash
# ui.sh - terminal dashboard and interactive menus.

UI_W=50 # box width including borders

_ui_line() { # _ui_line PLAIN [COLORED]  (pads using the plain text width)
  local plain="$1" col="${2:-$1}" inner=$((UI_W - 2)) vt='║'
  _box_ascii && vt='|'
  ((${#plain} > inner - 2)) && { plain="${plain:0:$((inner - 2))}"; col="$plain"; }
  printf '%s %s%*s%s\n' "$vt" "$col" "$((inner - 1 - ${#plain}))" "" "$vt"
}

_ui_bar() { # _ui_bar top|mid|bot
  local l r i s="" hz='═' inner=$((UI_W - 2))
  case "$1" in top) l='╔'; r='╗' ;; mid) l='╠'; r='╣' ;; *) l='╚'; r='╝' ;; esac
  if _box_ascii; then l='+'; r='+'; hz='-'; fi
  for ((i = 0; i < inner; i++)); do s+="$hz"; done
  printf '%s%s%s\n' "$l" "$s" "$r"
}

_ui_title() {
  local t="$1" inner=$((UI_W - 2)) pad vt='║'
  _box_ascii && vt='|'
  pad=$(((inner - ${#t}) / 2))
  printf '%s%*s%s%*s%s\n' "$vt" "$pad" "" "$t" "$((inner - pad - ${#t}))" "" "$vt"
}

_dot() { # _dot up|down -> "● ONLINE"
  local d='●'
  _box_ascii && d='*'
  if [[ "$1" == up ]]; then printf '%s' "$d ONLINE"; else printf '%s' "$d OFFLINE"; fi
}

_ui_status_row() { # label state(up|down)
  local plain col
  plain="$(printf '%-15s: %s' "$1" "$(_dot "$2")")"
  if [[ "$2" == up ]]; then col="$(printf '%-15s: %s%s%s' "$1" "$C_GRN" "$(_dot up)" "$C_RST")"
  else col="$(printf '%-15s: %s%s%s' "$1" "$C_RED" "$(_dot down)" "$C_RST")"; fi
  _ui_line "$plain" "$col"
}

ui_dashboard() {
  local ip host sn udp ssh
  ip="$(cfg_get SERVER_IP)"
  [[ -n "$ip" ]] || ip="$(detect_public_ipv4 2>/dev/null || echo '?')"
  host="$(cfg_get SERVER_HOST)"
  svc_is_active "$SVC_UDP" && udp=up || udp=down
  sn="$(sshd_service_name)"
  if systemctl is-active --quiet "$sn" 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then ssh=up; else ssh=down; fi
  _ui_bar top
  _ui_title "SSH UDP CUSTOM MANAGER  v$(sshudp_version)"
  _ui_bar mid
  _ui_line "$(printf '%-15s: %s' 'Server IP' "$ip")"
  _ui_line "$(printf '%-15s: %s' 'Hostname' "${host:-(not set)}")"
  _ui_line "$(printf '%-15s: %s' 'SSH Port' "$(cfg_get SSH_PORT)")"
  _ui_line "$(printf '%-15s: %s' 'UDP Ports' "$(cfg_get UDP_PORTS)")"
  _ui_status_row 'UDP Service' "$udp"
  _ui_status_row 'SSH Service' "$ssh"
  _ui_line "$(printf '%-15s: %s' 'Users' "$(count_users)")"
  _ui_line "$(printf '%-15s: %s' 'Online' "$(online_users_count)")"
  _ui_line "$(printf '%-15s: %s' 'Expired' "$(count_expired)")"
  _ui_line "$(printf '%-15s: %s' 'Server Load' "$(sys_load)")"
  _ui_line "$(printf '%-15s: %s%%' 'RAM' "$(sys_mem_pct)")"
  _ui_line "$(printf '%-15s: %s' 'Uptime' "$(sys_uptime)")"
  _ui_bar mid
  local i=0 item
  for item in "User Manager" "Online Users" "UDP Configuration" "Client Configuration" \
    "Traffic / Sessions" "Server Settings" "Firewall" "Logs" "Backup / Restore" \
    "Diagnostics" "Update" "Repair" "Uninstall"; do
    i=$((i + 1))
    _ui_line "$(printf '%2d. %s' "$i" "$item")"
  done
  _ui_line " 0. Exit"
  _ui_bar bot
}

_pause() { local _x; read -r -p "Press Enter to continue..." _x || true; }

# --------------------------------------------------------------- prompts ----
prompt_username() { # prompt_username VAR
  local __v="$1" n
  while :; do
    ask n "Username"
    [[ -z "$n" ]] && { log_warn "cancelled"; return 1; }
    valid_username "$n" && break
    log_warn "invalid: 3-32 chars, a-z 0-9 _ - (start with a letter or _)"
  done
  printf -v "$__v" '%s' "$n"
}

prompt_existing_user() {
  local __v="$1" n
  users_table | head -20
  ask n "Username"
  [[ -n "$n" ]] || return 1
  printf -v "$__v" '%s' "$n"
}

cmd_create_user_interactive() {
  local name pw pw2 span choice
  prompt_username name || return 1
  echo "Password:  1) generate a secure password   2) enter my own"
  ask choice "Choice" "1"
  if [[ "$choice" == "2" ]]; then
    while :; do
      ask_secret pw "Password (8-64 chars)"
      ask_secret pw2 "Repeat password"
      [[ "$pw" == "$pw2" ]] && valid_password "$pw" && break
      log_warn "passwords differ or invalid (allowed: A-Z a-z 0-9 ! # % + , . = ^ _ ~ -)"
    done
  else
    pw="$(gen_password)"
  fi
  while :; do
    ask span "Validity in days (1-3650) or expiry date (YYYY-MM-DD)" "30"
    valid_days "$span" || valid_date "$span" && break
    log_warn "invalid validity"
  done
  local lim
  ask lim "Max simultaneous logins (0 = unlimited)" "$(cfg_get DEFAULT_MAXLOGINS)"
  valid_maxlogins "$lim" || lim=0
  if user_create "$name" "$pw" "$span" "$lim"; then
    echo
    client_show "$name" "$pw"
  fi
}

# ----------------------------------------------------------------- menus ----
ui_user_menu() {
  local c u
  while :; do
    clear 2>/dev/null || true
    echo "${C_BLD}User Manager${C_RST}"
    echo " 1) Create user        6) List users"
    echo " 2) Delete user        7) Search user"
    echo " 3) Renew user         8) Account details"
    echo " 4) Lock user          9) Reset password"
    echo " 5) Unlock user       10) Cleanup expired"
    echo " 0) Back"
    ask c "Choice"
    case "$c" in
      1) cmd_create_user_interactive; _pause ;;
      2) prompt_existing_user u && confirm "Delete '$u' permanently?" n && user_delete "$u" && log_ok "deleted"; _pause ;;
      3) prompt_existing_user u && { local d; ask d "Extend by days (or new date)" "30"; user_renew "$u" "$d" && log_ok "new expiry: $USER_CREATED_EXPIRES"; }; _pause ;;
      4) prompt_existing_user u && user_lock "$u" && log_ok "locked"; _pause ;;
      5) prompt_existing_user u && user_unlock "$u" && log_ok "unlocked"; _pause ;;
      6) users_table; _pause ;;
      7) ask u "Search text"; users_table "$u"; _pause ;;
      8) prompt_existing_user u && user_details "$u"; _pause ;;
      9) prompt_existing_user u && { local p; p="$(gen_password)"; user_set_password "$u" "$p" && { echo; client_show "$u" "$p"; }; }; _pause ;;
      10) cleanup_expired; _pause ;;
      0 | "") return 0 ;;
    esac
  done
}

ui_udp_menu() {
  local c v
  while :; do
    clear 2>/dev/null || true
    echo "${C_BLD}UDP Configuration${C_RST}"
    printf ' Listen port : %s/udp\n Range       : %s\n Excluded    : %s\n Effective   : %s\n\n' \
      "$(cfg_get UDP_LISTEN_PORT)" "$(cfg_get UDP_PORTS)" "$(cfg_get UDP_EXCLUDE)" "$(fw_state_get RANGES -)"
    echo " 1) Change UDP range   2) Change exclusions   3) Change listen port"
    echo " 4) Restart UDP service  0) Back"
    ask c "Choice"
    case "$c" in
      1) ask v "New range (e.g. 20000-50000 or 20000-30000,40000-50000)" "$(cfg_get UDP_PORTS)"; cmd_config udp-ports "$v"; _pause ;;
      2) ask v "Excluded ports (comma list, or 'none')" "$(cfg_get UDP_EXCLUDE)"; cmd_config udp-exclude "$v"; _pause ;;
      3) ask v "New listen port" "$(cfg_get UDP_LISTEN_PORT)"; cmd_config udp-port "$v"; _pause ;;
      4) svc_restart "$SVC_UDP" && log_ok "restarted"; _pause ;;
      0 | "") return 0 ;;
    esac
  done
}

ui_settings_menu() {
  local c v
  while :; do
    clear 2>/dev/null || true
    echo "${C_BLD}Server Settings${C_RST}"
    cmd_config show
    echo
    echo " 1) Server hostname   2) Server IP   3) SSH port   4) Default login limit"
    echo " 5) UDPGW (optional)  6) Fail2ban (optional)  0) Back"
    ask c "Choice"
    case "$c" in
      1) ask v "Hostname (blank to clear)" "$(cfg_get SERVER_HOST)"; cmd_config server-host "${v:--}"; _pause ;;
      2) ask v "Public IP (blank = auto-detect)" "$(cfg_get SERVER_IP)"; cmd_config server-ip "${v:-auto}"; _pause ;;
      3) ask v "SSH port" "$(cfg_get SSH_PORT)"; cmd_config ssh-port "$v"; _pause ;;
      4) ask v "Default max logins per new user (0 = unlimited)" "$(cfg_get DEFAULT_MAXLOGINS)"; cmd_config default-maxlogins "$v"; _pause ;;
      5) udpgw_status; ask v "enable / disable" ""; case "$v" in enable) udpgw_enable ;; disable) udpgw_disable ;; esac; _pause ;;
      6) fail2ban_status; ask v "enable / disable" ""; case "$v" in enable) fail2ban_enable ;; disable) fail2ban_disable ;; esac; _pause ;;
      0 | "") return 0 ;;
    esac
  done
}

ui_logs_menu() {
  local c
  clear 2>/dev/null || true
  echo " 1) UDP service (last 50)   2) Expiry runs   3) Manager events"
  echo " 4) Follow UDP service live   0) Back"
  ask c "Choice"
  case "$c" in
    1) cmd_logs udp; _pause ;;
    2) cmd_logs expiry; _pause ;;
    3) cmd_logs events; _pause ;;
    4) cmd_logs udp -f ;;
  esac
}

ui_backup_menu() {
  local c f
  clear 2>/dev/null || true
  echo " 1) Create backup   2) Create backup WITH password hashes (sensitive)"
  echo " 3) List backups    4) Restore a backup   0) Back"
  ask c "Choice"
  case "$c" in
    1) backup_create && true; _pause ;;
    2) log_warn "This archive will contain password hashes of tunnel users. Keep it private."
       confirm "Continue?" n && backup_create --with-hashes; _pause ;;
    3) backup_list; _pause ;;
    4) backup_list; ask f "Backup file name"; [[ -n "$f" ]] && restore_run "$f" && apply_runtime; _pause ;;
  esac
}

ui_main_menu() {
  local c
  while :; do
    clear 2>/dev/null || true
    ui_dashboard
    ask c "Select"
    case "$c" in
      1) ui_user_menu ;;
      2) online_table; _pause ;;
      3) ui_udp_menu ;;
      4) local u; if prompt_existing_user u; then client_show "$u"; fi; _pause ;;
      5) traffic_report; echo; online_table; _pause ;;
      6) ui_settings_menu ;;
      7) fw_describe; echo; local a; ask a "1) re-apply rules  0) back" "0"; [[ "$a" == 1 ]] && fw_apply; _pause ;;
      8) ui_logs_menu ;;
      9) ui_backup_menu ;;
      10) doctor_run || true; _pause ;;
      11) update_run || true; _pause ;;
      12) repair_run || true; _pause ;;
      13) uninstall_run && return 0; _pause ;;
      0 | q | Q | "") return 0 ;;
      *) log_warn "unknown option" ;;
    esac
  done
}
