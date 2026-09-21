# shellcheck shell=bash
# platform.sh - OS / architecture detection and the support matrix.
#
# A release is only listed in SSHUDP_TESTED_UBUNTU after the automated
# integration suite passed on it (see docs/TESTING.md). Anything else is refused
# unless SSHUDP_FORCE_UNSUPPORTED=1 is set (at the administrator's own risk).

SSHUDP_TESTED_UBUNTU="20.04 22.04 24.04 26.04"
SSHUDP_KNOWN_UNSUPPORTED="18.04 16.04 14.04"

_os_release_file() { printf '%s' "${SSHUDP_OS_RELEASE:-/etc/os-release}"; }

os_field() { # os_field ID|VERSION_ID|PRETTY_NAME (parsed, not sourced)
  local f v
  f="$(_os_release_file)"
  [[ -r "$f" ]] || return 1
  v="$(awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' "$f")"
  printf '%s' "$v"
}

os_id() { os_field ID; }
os_version() { os_field VERSION_ID; }
os_pretty() { os_field PRETTY_NAME; }

# platform_check -> 0 ok, 1 unsupported (message on stderr)
platform_check() {
  local id ver arch
  id="$(os_id)"
  ver="$(os_version)"
  arch="$(uname -m)"
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    log_err "unsupported CPU architecture '$arch': the upstream UDP Custom core is only published for x86_64/amd64."
    return 1
  fi
  if [[ "$id" != "ubuntu" ]]; then
    log_err "unsupported operating system '${id:-unknown}': this project targets Ubuntu LTS."
    [[ "${SSHUDP_FORCE_UNSUPPORTED:-0}" == "1" ]] && { log_warn "continuing because SSHUDP_FORCE_UNSUPPORTED=1"; return 0; }
    return 1
  fi
  if [[ " $SSHUDP_TESTED_UBUNTU " == *" $ver "* ]]; then
    return 0
  fi
  if [[ " $SSHUDP_KNOWN_UNSUPPORTED " == *" $ver "* ]]; then
    log_err "Ubuntu $ver is end-of-life / not supported by this project (tested: $SSHUDP_TESTED_UBUNTU)."
  else
    log_err "Ubuntu ${ver:-unknown} has not been tested with this project (tested: $SSHUDP_TESTED_UBUNTU)."
  fi
  if [[ "${SSHUDP_FORCE_UNSUPPORTED:-0}" == "1" ]]; then
    log_warn "continuing because SSHUDP_FORCE_UNSUPPORTED=1 (unsupported, at your own risk)"
    return 0
  fi
  log_err "set SSHUDP_FORCE_UNSUPPORTED=1 to try anyway."
  return 1
}
