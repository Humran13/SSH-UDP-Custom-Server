# shellcheck shell=bash
# monitor.sh - sessions, online users, limits and service-level traffic.
#
# What is (and is not) measurable:
#  * Sessions: yes - one "sshd: USER@notty" process per SSH connection.
#  * Source address: for sessions that arrive through the UDP transport the peer
#    is the local relay (127.0.0.1); the real client address is only known to
#    the closed upstream core and is NOT exposed. Direct TCP sessions show the
#    real address.
#  * Traffic: kernel counters on the redirected UDP range (RX) and on packets
#    the UDP core sends from its listen port (TX). Per-user traffic is not
#    available (see docs/ARCHITECTURE.md), so none is shown.

# sessions_raw -> lines: "USER PID ETIMES"  (one per SSH connection, unprivileged child)

# session_peer PID -> peer address of the TCP connection held by that process
session_peer() {
  local pid="$1"
  ss -H -tnp state established 2>/dev/null | awk -v p="pid=$pid," '
    index($0, p) { print $4; exit }' | sed -e 's/^\[\(.*\)\]:[0-9]*$/\1/' -e 's/:[0-9]*$//'
}

session_count_for() { # managed users only
  local u="$1"
  sessions_raw | awk -v u="$u" '$1 == u { n++ } END { print n + 0 }'
}

sessions_managed() { # sessions_raw restricted to managed users
  local line u
  while IFS= read -r line; do
    u="${line%% *}"
    is_managed_user "$u" && printf '%s\n' "$line"
  done < <(sessions_raw)
}

online_users_count() {
  sessions_managed | awk '{ u[$1] = 1 } END { n = 0; for (k in u) n++; print n }'
}

online_table() {
  local line u pid et peer via n=0
  printf '%-18s %-9s %-10s %-16s %s\n' USERNAME SESSIONS DURATION SOURCE VIA
  while IFS= read -r line; do
    u="${line%% *}"
    pid="$(awk '{print $2}' <<<"$line")"
    et="$(awk '{print $3}' <<<"$line")"
    peer="$(session_peer "$pid")"
    if [[ "$peer" == "127.0.0.1" || "$peer" == "::1" ]]; then
      via="loopback (UDP transport relay or local)"
    else
      via="direct TCP"
    fi
    printf '%-18s %-9s %-10s %-16s %s\n' "$u" "$(session_count_for "$u")" "$(human_duration "$et")" "${peer:--}" "$via"
    n=$((n + 1))
  done < <(sessions_managed | sort)
  ((n)) || echo "(no managed users are connected)"
}

# Enforce per-user simultaneous session limits. Runs every minute from a timer,
# so an excess connection can live for up to ~60 s before it is terminated.
# The NEWEST sessions above the limit are killed (oldest ones stay connected).
enforce_limits() {
  local u lim n killed=0 pid
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    lim="$(meta_get "$u" MAXLOGINS 0)"
    [[ "$lim" =~ ^[0-9]+$ && "$lim" -gt 0 ]] || continue
    is_managed_user "$u" || continue
    n="$(session_count_for "$u")"
    ((n > lim)) || continue
    # sort by elapsed time ascending (newest first), skip nothing, kill first (n-lim)
    while IFS= read -r pid; do
      kill -TERM "$pid" 2>/dev/null && killed=$((killed + 1))
    done < <(sessions_raw | awk -v u="$u" '$1 == u { print $3, $2 }' | sort -n | head -n "$((n - lim))" | awk '{ print $2 }')
    ev "limit enforced for $u: $n sessions > $lim"
  done < <(managed_users)
  ((killed)) && ev "enforce-limits: terminated $killed session(s)"
  return 0
}

traffic_report() {
  local rxp rxb txp txb
  read -r rxp rxb txp txb < <(fw_stats)

  echo "Service-level UDP traffic (kernel counters, since firewall rules were loaded)"
  printf '  Received  (to redirected UDP ports) : %s in %s packets\n' "$(human_bytes "${rxb:-0}")" "${rxp:-0}"
  printf '  Sent      (from UDP core listen port): %s in %s packets\n' "$(human_bytes "${txb:-0}")" "${txp:-0}"
  echo
  printf 'Active SSH sessions (managed users): %s\n' "$(sessions_managed | wc -l)"
  echo "Per-user traffic is not reported: the transport hides it from the kernel"
  echo "(see docs/ARCHITECTURE.md, 'Traffic statistics')."
}

sys_load() { awk '{ print $1 }' /proc/loadavg; }
sys_mem_pct() { awk '/MemTotal/ { t = $2 } /MemAvailable/ { a = $2 } END { if (t) printf "%d", (t - a) * 100 / t; else print 0 }' /proc/meminfo; }
sys_uptime() { human_duration "$(awk '{ printf "%d", $1 }' /proc/uptime)"; }

# sessions_raw -> lines: "USER PID ETIMES"  (one per SSH connection)
# The unprivileged per-connection sshd child is titled "sshd: USER" (OpenSSH 10+: "sshd-session: USER") (forward-only
# sessions) or "sshd: USER@notty|pts/N" and is owned by USER. The root monitor
# process ("sshd: USER [priv]") is deliberately not counted.
sessions_raw() {
  ps -eo pid=,user:32=,etimes=,args= 2>/dev/null | awk '
    { pid = $1; usr = $2; et = $3; $1 = ""; $2 = ""; $3 = ""; sub(/^ +/, "", $0)
      if ($0 ~ /^sshd(-session)?: [^ ]+(@(notty|pts\/[0-9]+))?$/) {
        split($0, a, " "); n = a[2]; sub(/@.*/, "", n)
        if (n == usr) print n, pid, et } }'
}
