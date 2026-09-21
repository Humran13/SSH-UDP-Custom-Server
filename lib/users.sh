# shellcheck shell=bash
# users.sh - SSH tunnel account management.
#
# Only accounts created by this project are ever touched. An account is
# "managed" when ALL of these hold:
#   1. a metadata file exists in $SSHUDP_USERS_DIR,
#   2. the OS account exists and its UID matches the recorded UID,
#   3. the OS account's primary group is $SSHUDP_GROUP.
# Passwords are passed to chpasswd on stdin and are never stored or logged.

_meta_file() { printf '%s/%s.meta' "$SSHUDP_USERS_DIR" "$1"; }
meta_get() { kv_get "$(_meta_file "$1")" "$2" "${3:-}"; }

meta_write() { # meta_write USER UID CREATED EXPIRES STATUS MAXLOGINS
  local f
  f="$(_meta_file "$1")"
  printf 'USERNAME=%s\nUID=%s\nCREATED=%s\nEXPIRES=%s\nSTATUS=%s\nMAXLOGINS=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" | atomic_write "$f" 0600 root:root
}

meta_set() { kv_set "$(_meta_file "$1")" "$2" "$3"; }

managed_users() { # names, sorted
  local f n
  [[ -d "$SSHUDP_USERS_DIR" ]] || return 0
  for f in "$SSHUDP_USERS_DIR"/*.meta; do
    [[ -e "$f" ]] || continue
    n="$(basename -- "$f" .meta)"
    valid_username "$n" && printf '%s\n' "$n"
  done | sort
}

os_user_exists() { getent passwd "$1" >/dev/null 2>&1; }
os_user_uid() { getent passwd "$1" | cut -d: -f3; }

is_managed_user() {
  local u="$1" uid rec gid gname
  valid_username "$u" || return 1
  [[ -r "$(_meta_file "$u")" ]] || return 1
  os_user_exists "$u" || return 1
  uid="$(os_user_uid "$u")"
  rec="$(meta_get "$u" UID)"
  [[ -n "$uid" && "$uid" == "$rec" ]] || return 1
  gid="$(getent passwd "$u" | cut -d: -f4)"
  gname="$(getent group "$gid" | cut -d: -f1)"
  [[ "$gname" == "$SSHUDP_GROUP" ]]
}

ensure_group() {
  getent group "$SSHUDP_GROUP" >/dev/null 2>&1 || groupadd --system "$SSHUDP_GROUP"
}

gen_password() {
  local p
  set +o pipefail
  p="$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 14)"
  set -o pipefail
  printf '%s' "$p"
}

# Days remaining (negative = expired ago) for an ISO date.
days_left() {
  local exp="$1" e t
  e="$(epoch_of "$exp")" || return 1
  t="$(epoch_of "$(today)")" || return 1
  printf '%d' $(((e - t) / 86400))
}

user_is_expired() { # expired when today is AFTER the expiry date
  local exp
  exp="$(meta_get "$1" EXPIRES)"
  [[ -n "$exp" && "$(today)" > "$exp" ]]
}

# The OS-level account expiry is one day after our date, as a safety net
# in case the timer is ever missed. PAM/sshd enforce it independently.
_os_expiry() { date_add_days "$1" 1; }

kill_user_sessions() {
  local uid="$1"
  [[ "$uid" =~ ^[0-9]+$ && "$uid" -ge 1000 ]] || return 0
  pkill -KILL -u "$uid" 2>/dev/null || true
}

# user_create NAME PASSWORD DAYS_OR_DATE [MAXLOGINS]   (password on argv only inside this shell)
user_create() {
  local name="$1" pw="$2" span="$3" maxl="${4:-}" exp uid
  valid_username "$name" || {
    log_err "invalid username (3-32 chars: a-z 0-9 _ -, must start with a letter or _)"
    return 1
  }
  valid_password "$pw" || {
    log_err "invalid password (8-64 chars from: A-Z a-z 0-9 ! # % + , . = ^ _ ~ -)"
    return 1
  }
  [[ -n "$maxl" ]] || maxl="$(cfg_get DEFAULT_MAXLOGINS)"
  valid_maxlogins "$maxl" || {
    log_err "invalid login limit (0-1000, 0 = unlimited)"
    return 1
  }
  if valid_date "$span"; then
    exp="$span"
    if [[ ! "$exp" > "$(today)" ]]; then
      log_err "expiry date must be in the future"
      return 1
    fi
  elif valid_days "$span"; then
    exp="$(date_add_days "$(today)" "$span")"
  else
    log_err "validity must be 1-3650 days or a date (YYYY-MM-DD)"
    return 1
  fi
  if os_user_exists "$name" || [[ -e "$(_meta_file "$name")" ]]; then
    log_err "user '$name' already exists"
    return 1
  fi
  ensure_group || return 1
  if ! useradd --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
    --no-user-group --gid "$SSHUDP_GROUP" --expiredate "$(_os_expiry "$exp")" \
    --comment "sshudp managed tunnel account" -- "$name"; then
    log_err "useradd failed"
    return 1
  fi
  if ! printf '%s:%s\n' "$name" "$pw" | chpasswd; then
    userdel -- "$name" >/dev/null 2>&1 || true
    log_err "could not set password"
    return 1
  fi
  uid="$(os_user_uid "$name")"
  if ! meta_write "$name" "$uid" "$(today)" "$exp" active "$maxl"; then
    userdel -- "$name" >/dev/null 2>&1 || true
    return 1
  fi
  ev "user created: $name expires=$exp"
  USER_CREATED_EXPIRES="$exp"
  return 0
}

user_require_managed() {
  local u="$1"
  valid_username "$u" || {
    log_err "invalid username"
    return 1
  }
  if ! is_managed_user "$u"; then
    log_err "'$u' is not a user managed by sshudp"
    return 1
  fi
}

user_delete() {
  local u="$1" uid
  user_require_managed "$u" || return 1
  uid="$(os_user_uid "$u")"
  kill_user_sessions "$uid"
  userdel -- "$u" >/dev/null 2>&1 || {
    log_err "userdel failed"
    return 1
  }
  rm -f -- "$(_meta_file "$u")"
  ev "user deleted: $u"
}

# user_renew NAME DAYS_OR_DATE  -> extends from the later of today / current expiry
user_renew() {
  local u="$1" span="$2" base cur exp
  user_require_managed "$u" || return 1
  cur="$(meta_get "$u" EXPIRES)"
  if valid_date "$span"; then
    exp="$span"
  elif valid_days "$span"; then
    base="$(today)"
    [[ -n "$cur" && "$cur" > "$base" ]] && base="$cur"
    exp="$(date_add_days "$base" "$span")"
  else
    log_err "validity must be 1-3650 days or a date (YYYY-MM-DD)"
    return 1
  fi
  if [[ ! "$exp" > "$(today)" ]]; then
    log_err "new expiry must be in the future"
    return 1
  fi
  usermod --expiredate "$(_os_expiry "$exp")" -- "$u" || return 1
  meta_set "$u" EXPIRES "$exp" || return 1
  if [[ "$(meta_get "$u" STATUS)" == "expired" ]]; then
    usermod -U -- "$u" 2>/dev/null || true
    meta_set "$u" STATUS active
  fi
  USER_CREATED_EXPIRES="$exp"
  ev "user renewed: $u expires=$exp"
}

user_lock() {
  local u="$1"
  user_require_managed "$u" || return 1
  usermod -L -- "$u" || return 1
  kill_user_sessions "$(os_user_uid "$u")"
  meta_set "$u" STATUS locked
  ev "user locked: $u"
}

user_unlock() {
  local u="$1"
  user_require_managed "$u" || return 1
  if user_is_expired "$u"; then
    log_err "'$u' has expired; renew it first (sshudp renew-user $u)"
    return 1
  fi
  usermod -U -- "$u" || return 1
  meta_set "$u" STATUS active
  ev "user unlocked: $u"
}

user_set_password() { # user_set_password NAME PASSWORD
  local u="$1" pw="$2"
  user_require_managed "$u" || return 1
  valid_password "$pw" || {
    log_err "invalid password"
    return 1
  }
  printf '%s:%s\n' "$u" "$pw" | chpasswd || return 1
  ev "password reset: $u"
}

user_set_maxlogins() {
  local u="$1" n="$2"
  user_require_managed "$u" || return 1
  valid_maxlogins "$n" || {
    log_err "invalid login limit"
    return 1
  }
  meta_set "$u" MAXLOGINS "$n"
}

# cleanup_expired [--delete] [--quiet]: lock (or delete) expired managed users.
cleanup_expired() {
  local del=0 quiet=0 u n=0 a
  for a in "$@"; do
    case "$a" in
      --delete) del=1 ;;
      --quiet) quiet=1 ;;
    esac
  done
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    is_managed_user "$u" || continue
    user_is_expired "$u" || continue
    if ((del)); then
      user_delete "$u" && n=$((n + 1))
      ((quiet)) || log_ok "deleted expired user: $u"
    elif [[ "$(meta_get "$u" STATUS)" != "expired" ]]; then
      usermod -L -- "$u" 2>/dev/null || true
      kill_user_sessions "$(os_user_uid "$u")"
      meta_set "$u" STATUS expired
      ev "user expired and locked: $u"
      n=$((n + 1))
      ((quiet)) || log_ok "locked expired user: $u"
    fi
  done < <(managed_users)
  ev "cleanup-expired finished: $n changed"
  ((quiet)) || log_info "expired accounts processed: $n"
  return 0
}

count_users() { managed_users | grep -c . || true; }
count_expired() {
  local u n=0
  while IFS= read -r u; do
    [[ -n "$u" ]] && user_is_expired "$u" && n=$((n + 1))
  done < <(managed_users)
  printf '%d' "$n"
}

# Metadata entries whose OS account is gone (e.g. after restoring on a new host).
orphan_users() {
  local u
  while IFS= read -r u; do
    [[ -n "$u" ]] && ! is_managed_user "$u" && printf '%s\n' "$u"
  done < <(managed_users)
}

user_status_label() {
  local u="$1" st
  st="$(meta_get "$u" STATUS active)"
  if [[ "$st" == "active" ]] && user_is_expired "$u"; then st="expired"; fi
  printf '%s' "$st"
}

users_table() { # users_table [FILTER]
  local filter="${1:-}" u exp left st lim onl
  printf '%-20s %-9s %-11s %-6s %-6s %s\n' USERNAME STATUS EXPIRES LEFT LIMIT ONLINE
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    [[ -z "$filter" || "$u" == *"$filter"* ]] || continue
    exp="$(meta_get "$u" EXPIRES)"
    left="$(days_left "$exp" 2>/dev/null || echo '?')"
    st="$(user_status_label "$u")"
    lim="$(meta_get "$u" MAXLOGINS 0)"
    [[ "$lim" == 0 ]] && lim="-"
    onl="$(session_count_for "$u" 2>/dev/null || echo 0)"
    printf '%-20s %-9s %-11s %-6s %-6s %s\n' "$u" "$st" "$exp" "${left}d" "$lim" "$onl"
  done < <(managed_users)
}

user_details() {
  local u="$1"
  user_require_managed "$u" || return 1
  printf 'Username    : %s\n' "$u"
  printf 'UID         : %s\n' "$(os_user_uid "$u")"
  printf 'Status      : %s\n' "$(user_status_label "$u")"
  printf 'Created     : %s\n' "$(meta_get "$u" CREATED)"
  printf 'Expires     : %s (%sd left)\n' "$(meta_get "$u" EXPIRES)" "$(days_left "$(meta_get "$u" EXPIRES)")"
  printf 'Login limit : %s\n' "$(meta_get "$u" MAXLOGINS 0)"
  printf 'Sessions    : %s\n' "$(session_count_for "$u")"
  printf 'Shell       : %s\n' "$(getent passwd "$u" | cut -d: -f7)"
}
