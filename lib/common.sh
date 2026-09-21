# shellcheck shell=bash
# common.sh - shared helpers for SSH UDP Custom Server Manager.
# Sourced by bin/sshudp, install.sh and the other lib/*.sh files. Never executed.

# ---------------------------------------------------------------------------
# Paths. Overrides are honoured ONLY when SSHUDP_TESTING=1 so that a stray
# environment variable can never redirect a root-run manager.
# ---------------------------------------------------------------------------
if [[ "${SSHUDP_TESTING:-}" != "1" ]]; then
  unset SSHUDP_CONF_DIR SSHUDP_STATE_DIR SSHUDP_INSTALL_DIR SSHUDP_BACKUP_DIR \
    SSHUDP_BIN_LINK SSHUDP_SYSTEMD_DIR SSHUDP_SSHD_DROPIN_DIR SSHUDP_TODAY \
    SSHUDP_OS_RELEASE SSHUDP_IP_ENDPOINTS SSHUDP_CORE_URL SSHUDP_CORE_SHA256 \
    SSHUDP_RELEASE_BASE SSHUDP_FAIL_AT SSHUDP_SRC_DIR SSHUDP_NO_SYSTEMD
fi

SSHUDP_CONF_DIR="${SSHUDP_CONF_DIR:-/etc/ssh-udp-custom}"
SSHUDP_STATE_DIR="${SSHUDP_STATE_DIR:-/var/lib/ssh-udp-custom}"
SSHUDP_INSTALL_DIR="${SSHUDP_INSTALL_DIR:-/usr/local/lib/ssh-udp-custom}"
SSHUDP_BACKUP_DIR="${SSHUDP_BACKUP_DIR:-/var/backups/ssh-udp-custom}"
SSHUDP_BIN_LINK="${SSHUDP_BIN_LINK:-/usr/local/bin/sshudp}"
SSHUDP_SYSTEMD_DIR="${SSHUDP_SYSTEMD_DIR:-/etc/systemd/system}"
SSHUDP_SSHD_DROPIN_DIR="${SSHUDP_SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"

SSHUDP_CONF_FILE="$SSHUDP_CONF_DIR/config.conf"
SSHUDP_CORE_JSON="$SSHUDP_CONF_DIR/udp-custom.json"
SSHUDP_USERS_DIR="$SSHUDP_STATE_DIR/users"
SSHUDP_RUN_DIR="/run/ssh-udp-custom"
SSHUDP_STATE_SUB="$SSHUDP_STATE_DIR/state"
SSHUDP_LOCKFILE="$SSHUDP_STATE_DIR/.lock"

SVC_UDP="ssh-udp-custom.service"
SVC_FW="ssh-udp-custom-firewall.service"
SVC_EXPIRY="ssh-udp-custom-expiry"
SVC_LIMITER="ssh-udp-custom-limiter"
SVC_UDPGW="ssh-udp-custom-udpgw.service"
SSHUDP_GROUP="sshudp-users"
SSHUDP_SVC_USER="sshudp"
SSHUDP_DROPIN_NAME="90-ssh-udp-custom.conf"
SSHUDP_SYSCTL_FILE="/etc/sysctl.d/90-ssh-udp-custom.conf"
SSHUDP_REPO="Humran13/SSH-UDP-Custom-Server"

sshudp_version() {
  local f
  for f in "$SSHUDP_INSTALL_DIR/VERSION" "${SSHUDP_LIB_HOME:-/nonexistent}/../VERSION"; do
    if [[ -r "$f" ]]; then
      tr -d '[:space:]' <"$f"
      return 0
    fi
  done
  printf 'unknown'
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'
  C_DIM=$'\033[2m'
  C_BLD=$'\033[1m'
  C_RST=$'\033[0m'
else
  C_RED="" C_GRN="" C_YEL="" C_BLU="" C_DIM="" C_BLD="" C_RST=""
fi

log_info() { printf '%s\n' "${C_BLU}[info]${C_RST} $*"; }
log_ok() { printf '%s\n' "${C_GRN}[ ok ]${C_RST} $*"; }
log_warn() { printf '%s\n' "${C_YEL}[warn]${C_RST} $*" >&2; }
log_err() { printf '%s\n' "${C_RED}[fail]${C_RST} $*" >&2; }
die() {
  log_err "$*"
  exit 1
}

# Record an event in the journal (tag "sshudp"). Never pass secrets here.
ev() {
  if command -v logger >/dev/null 2>&1; then
    logger -t sshudp -p daemon.info -- "$*" 2>/dev/null || true
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "this command must be run as root (try: sudo sshudp ...)"
  fi
}

# Date helpers. SSHUDP_TODAY is honoured only in testing mode (see above).
today() { printf '%s' "${SSHUDP_TODAY:-$(date +%F)}"; }
date_add_days() { date -u -d "$1 +$2 days" +%F 2>/dev/null; }
epoch_of() { date -u -d "$1" +%s 2>/dev/null; }

# ---------------------------------------------------------------------------
# Files: atomic writes and strict KEY=VALUE files (never sourced).
# ---------------------------------------------------------------------------
# atomic_write DEST [MODE] [OWNER:GROUP]  -- content on stdin
atomic_write() {
  local dest="$1" mode="${2:-0644}" owner="${3:-root:root}" dir tmp
  dir="$(dirname -- "$dest")"
  if [[ -L "$dest" ]]; then
    log_err "refusing to write through a symlink: $dest"
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    log_err "directory does not exist: $dir"
    return 1
  fi
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod "$mode" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 && "$owner" != "none" ]]; then
    if ! chown "$owner" "$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# kv_get FILE KEY [DEFAULT] - last assignment wins; value is everything after '='.
kv_get() {
  local file="$1" key="$2" def="${3:-}" out
  if [[ ! -r "$file" ]]; then
    printf '%s' "$def"
    return 0
  fi
  out="$(awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    { i = index($0, "="); if (i == 0) next
      if (substr($0, 1, i - 1) == k) { v = substr($0, i + 1); f = 1 } }
    END { if (f) print "F" v }' "$file")"
  if [[ -z "$out" ]]; then
    printf '%s' "$def"
  else
    printf '%s' "${out:1}"
  fi
}

# kv_set FILE KEY VALUE - replace or append; value must be a single line.
kv_set() {
  local file="$1" key="$2" val="$3"
  if [[ "$val" == *$'\n'* || "$val" == *$'\r'* ]]; then
    log_err "refusing multi-line value for $key"
    return 1
  fi
  if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    log_err "invalid key name: $key"
    return 1
  fi
  local mode="0644"
  [[ -e "$file" ]] && mode="$(stat -c '%a' "$file")"
  {
    if [[ -r "$file" ]]; then
      awk -v k="$key" -v v="$val" '
        BEGIN { done = 0 }
        { i = index($0, "=")
          if (i > 0 && substr($0, 1, i - 1) == k) { if (!done) { print k "=" v; done = 1 } ; next }
          print }
        END { if (!done) print k "=" v }' "$file"
    else
      printf '%s=%s\n' "$key" "$val"
    fi
  } | atomic_write "$file" "$mode" root:root
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
lock_acquire() {
  have flock || return 0
  mkdir -p "$SSHUDP_STATE_DIR" 2>/dev/null || true
  exec 9>"$SSHUDP_LOCKFILE" || return 0
  if ! flock -w 30 9; then
    die "another sshudp operation is in progress (lock: $SSHUDP_LOCKFILE)"
  fi
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
confirm() { # confirm "question" [default y|n]
  local q="$1" def="${2:-n}" ans prompt="[y/N]"
  [[ "$def" == "y" ]] && prompt="[Y/n]"
  if [[ "${SSHUDP_ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    [[ "$def" == "y" ]]
    return
  fi
  read -r -p "$q $prompt " ans </dev/tty || return 1
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ask VAR "prompt" "default" - reads from the terminal even when stdin is a pipe.
ask() {
  local __var="$1" prompt="$2" def="${3:-}" ans=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt${def:+ [$def]}: " ans || true
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt${def:+ [$def]}: " ans </dev/tty || true
  fi
  printf -v "$__var" '%s' "${ans:-$def}"
}

ask_secret() { # ask_secret VAR "prompt"
  local __var="$1" prompt="$2" ans=""
  if [[ -t 0 ]]; then
    read -r -s -p "$prompt: " ans || true
    echo
  elif [[ -r /dev/tty ]]; then
    read -r -s -p "$prompt: " ans </dev/tty || true
    echo >/dev/tty
  fi
  printf -v "$__var" '%s' "$ans"
}

human_bytes() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i] }'
}

human_duration() { # seconds -> 3d 07h / 2h 15m / 42s
  local s="${1:-0}" d h m
  d=$((s / 86400))
  h=$(((s % 86400) / 3600))
  m=$(((s % 3600) / 60))
  if ((d > 0)); then
    printf '%dd %02dh' "$d" "$h"
  elif ((h > 0)); then
    printf '%dh %02dm' "$h" "$m"
  elif ((m > 0)); then
    printf '%dm %02ds' "$m" "$((s % 60))"
  else
    printf '%ds' "$s"
  fi
}

# systemd available and running as PID 1?
have_systemd() {
  [[ "${SSHUDP_NO_SYSTEMD:-0}" == "1" ]] && return 1
  [[ -d /run/systemd/system ]] && have systemctl
}

sshd_service_name() {
  local n
  for n in ssh sshd; do
    if systemctl list-unit-files "$n.service" 2>/dev/null | grep -q "^$n.service"; then
      printf '%s' "$n"
      return 0
    fi
  done
  printf 'ssh'
}

# curl protocol allow-list: HTTPS only. Plain http is permitted solely in the
# automated test-suite (SSHUDP_TESTING=1) to talk to a local mock server.
_curl_proto() { if [[ "${SSHUDP_TESTING:-}" == "1" ]]; then echo '=https,http'; else echo '=https'; fi; }

# rm_project_path PATH... - recursive delete with a guard against catastrophic paths.
rm_project_path() {
  local p
  for p in "$@"; do
    case "$p" in
      "" | / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /usr/local | /usr/local/lib | /usr/local/bin | /var | /var/lib | /var/backups)
        log_err "refusing to delete protected path: '$p'"
        return 1
        ;;
    esac
    rm -rf -- "$p"
  done
}
