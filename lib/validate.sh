# shellcheck shell=bash
# validate.sh - strict input validation. Every function is silent and returns
# 0 (valid) or 1 (invalid). Nothing here ever evaluates user input.

_no_ctl() { # no control characters, DEL or newlines at all
  [[ "$1" != *[[:cntrl:]]* ]]
}

# Reserved names that must never be created as tunnel accounts.
_RESERVED_USERS=" root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody admin administrator ubuntu debian sshd sshudp systemd-network systemd-resolve systemd-timesync messagebus syslog postgres mysql ftp git "

valid_username() {
  local u="${1-}"
  _no_ctl "$u" || return 1
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{2,31}$ ]] || return 1
  [[ "$_RESERVED_USERS" != *" $u "* ]] || return 1
  return 0
}

# Characters chosen so that the password survives shell, chpasswd and the
# "host:ports@user:pass" client string without any escaping.
valid_password() {
  local p="${1-}"
  local re='^[A-Za-z0-9!#%+,.=^_~-]{8,64}$'
  _no_ctl "$p" || return 1
  [[ "$p" =~ $re ]]
}

valid_int() { # valid_int VALUE MIN MAX
  local v="${1-}" min="$2" max="$3"
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || return 1
  ((10#$v >= min && 10#$v <= max))
}

valid_port() { valid_int "${1-}" 1 65535; }
valid_days() { valid_int "${1-}" 1 3650; }
valid_maxlogins() { valid_int "${1-}" 0 1000; }

# One port item: "N" or "A-B" (A <= B)
_valid_port_item() {
  local it="$1" a b
  if [[ "$it" =~ ^[0-9]{1,5}$ ]]; then
    valid_port "$it"
    return
  fi
  if [[ "$it" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    a="${BASH_REMATCH[1]}"
    b="${BASH_REMATCH[2]}"
    valid_port "$a" && valid_port "$b" && ((10#$a <= 10#$b))
    return
  fi
  return 1
}

# Comma separated list of ports and ranges: "53,123,20000-30000"
valid_port_spec() {
  local spec="${1-}" it n=0
  _no_ctl "$spec" || return 1
  [[ -n "$spec" && "$spec" =~ ^[0-9,-]+$ ]] || return 1
  [[ "$spec" != ,* && "$spec" != *, && "$spec" != *,,* ]] || return 1
  local IFS=,
  for it in $spec; do
    _valid_port_item "$it" || return 1
    n=$((n + 1))
  done
  ((n >= 1 && n <= 64))
}

valid_date() { # YYYY-MM-DD, real calendar date, 2000..2100
  local d="${1-}"
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  [[ "$(date -u -d "$d" +%F 2>/dev/null)" == "$d" ]] || return 1
  [[ "${d:0:4}" -ge 2000 && "${d:0:4}" -le 2100 ]]
}

valid_ipv4() {
  local o='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  [[ "${1-}" =~ ^$o\.$o\.$o\.$o$ ]]
}

valid_ipv6() {
  local v="${1-}"
  [[ ${#v} -ge 2 && ${#v} -le 45 && "$v" =~ ^[0-9A-Fa-f:.]+$ && "$v" == *:*:* ]]
}

valid_hostname() {
  local h="${1-}"
  local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
  ((${#h} >= 1 && ${#h} <= 253)) || return 1
  _no_ctl "$h" || return 1
  [[ "$h" =~ ^($label\.)*$label$ ]]
}

valid_host_or_ip() { valid_ipv4 "$1" || valid_ipv6 "$1" || valid_hostname "$1"; }

# Only bare backup file names produced by this project are accepted.
valid_backup_name() {
  local n="${1-}"
  [[ "$n" =~ ^sshudp-backup-[0-9]{8}-[0-9]{6}(-[a-z0-9]{1,16})?\.tar\.gz$ ]]
}

valid_choice() { # valid_choice VALUE a b c
  local v="${1-}" c
  shift
  for c in "$@"; do [[ "$v" == "$c" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Port range arithmetic (pure awk/sort; input must already be validated).
# ---------------------------------------------------------------------------
# ports_normalize SPEC -> merged, sorted, disjoint "a-b" lines
ports_normalize() {
  local spec="$1" it
  local IFS=,
  for it in $spec; do
    if [[ "$it" == *-* ]]; then
      printf '%s %s\n' "${it%-*}" "${it#*-}"
    else
      printf '%s %s\n' "$it" "$it"
    fi
  done | sort -n -k1,1 -k2,2 | awk '
    { lo = $1 + 0; hi = $2 + 0
      if (NR == 1) { cl = lo; ch = hi; next }
      if (lo <= ch + 1) { if (hi > ch) ch = hi } else { print cl "-" ch; cl = lo; ch = hi } }
    END { if (NR) print cl "-" ch }'
}

# ports_subtract INCLUDE_LINES EXCLUDE_LINES (both output of ports_normalize)
ports_subtract() {
  awk -v inc="$1" -v exc="$2" '
    BEGIN {
      ni = split(inc, I, "\n"); ne = split(exc, E, "\n")
      for (j = 1; j <= ne; j++) { split(E[j], p, "-"); elo[j] = p[1] + 0; ehi[j] = p[2] + 0 }
      for (i = 1; i <= ni; i++) {
        if (I[i] == "") continue
        split(I[i], q, "-"); cur = q[1] + 0; b = q[2] + 0
        for (j = 1; j <= ne && cur <= b; j++) {
          if (ehi[j] < cur) continue
          if (elo[j] > b) break
          if (elo[j] > cur) print cur "-" (elo[j] - 1)
          cur = ehi[j] + 1
        }
        if (cur <= b) print cur "-" b
      }
    }'
}

# ports_pretty LINES -> "20000-30000,40000-50000" ("53" for single ports)
ports_pretty() {
  awk -F- '{ if ($1 == $2) printf "%s%s", (n++ ? "," : ""), $1; else printf "%s%s-%s", (n++ ? "," : ""), $1, $2 }'
}

# ports_count LINES -> number of ports covered
ports_count() {
  awk -F- '{ n += $2 - $1 + 1 } END { print n + 0 }'
}

# port_in_lines PORT LINES -> 0 if covered
port_in_lines() {
  local p="$1" lines="$2"
  awk -F- -v p="$p" '$1 <= p && p <= $2 { f = 1 } END { exit f ? 0 : 1 }' <<<"$lines"
}
