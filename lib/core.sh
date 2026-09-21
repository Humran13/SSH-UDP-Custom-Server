# shellcheck shell=bash
# core.sh - the upstream UDP Custom binary: pinning, download, verification.
#
# The binary is closed source and has NO license file upstream, so it is never
# stored in this repository or in our release archives. It is downloaded from
# the upstream repository at a pinned commit and verified against a SHA-256
# that is recorded in upstream.conf (see docs/UPSTREAM.md).

CORE_BIN="$SSHUDP_INSTALL_DIR/core/udp-custom"
CORE_INFO="$SSHUDP_INSTALL_DIR/core/core.info"



# http_get URL DEST  (HTTPS only, TLS verification always on)
http_get() {
  local url="$1" dest="$2"
  curl --proto "$(_curl_proto)" --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 300 -o "$dest" -- "$url"
}

upstream_get() { # upstream_get KEY  (reads upstream.conf from the installed/source tree)
  local f="$SSHUDP_INSTALL_DIR/upstream.conf"
  [[ -r "$f" ]] || f="${SSHUDP_LIB_HOME:-.}/../upstream.conf"
  kv_get "$f" "$1" ""
}

core_sha256() { sha256sum -- "$1" | awk '{ print $1 }'; }

core_is_elf_x86_64() {
  # ELF magic + EI_CLASS=2 (64-bit) + e_machine=0x3e (x86-64)
  local h
  h="$(head -c 20 -- "$1" | od -An -tx1 | tr -d ' \n')"
  [[ "${h:0:8}" == "7f454c46" && "${h:8:2}" == "02" && "${h:36:4}" == "3e00" ]]
}

# core_install: download, verify and install the pinned core.
core_install() {
  local url sha size tmp got
  url="$(upstream_get CORE_URL)"
  sha="$(upstream_get CORE_SHA256)"
  size="$(upstream_get CORE_SIZE)"
  if [[ "${SSHUDP_TESTING:-}" == "1" ]]; then
    url="${SSHUDP_CORE_URL:-$url}"
    sha="${SSHUDP_CORE_SHA256:-$sha}"
    size=""
  fi
  [[ -n "$url" && "$sha" =~ ^[0-9a-f]{64}$ ]] || { log_err "upstream.conf is missing or damaged"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/sshudp-core.XXXXXX")" || return 1
  log_info "downloading upstream UDP Custom core (pinned)..."
  if ! http_get "$url" "$tmp"; then
    rm -f -- "$tmp"
    log_err "download of the upstream core failed: $url"
    return 1
  fi
  got="$(core_sha256 "$tmp")"
  if [[ "$got" != "$sha" ]]; then
    rm -f -- "$tmp"
    log_err "SHA-256 mismatch for the upstream core (expected $sha, got $got). Refusing to install."
    return 1
  fi
  if [[ -n "$size" && "$(stat -c %s "$tmp")" != "$size" ]]; then
    rm -f -- "$tmp"
    log_err "unexpected size for the upstream core"
    return 1
  fi
  if ! core_is_elf_x86_64 "$tmp"; then
    rm -f -- "$tmp"
    log_err "downloaded core is not a Linux x86-64 executable"
    return 1
  fi
  mkdir -p "$SSHUDP_INSTALL_DIR/core"
  install -m 0755 -o root -g root "$tmp" "$CORE_BIN.new" 2>/dev/null || install -m 0755 "$tmp" "$CORE_BIN.new"
  mv -f -- "$CORE_BIN.new" "$CORE_BIN"
  rm -f -- "$tmp"
  {
    printf 'CORE_VERSION=%s\n' "$(upstream_get CORE_VERSION)"
    printf 'CORE_SHA256=%s\n' "$sha"
    printf 'CORE_URL=%s\n' "$url"
    printf 'INSTALLED=%s\n' "$(date -u +%FT%TZ)"
  } | atomic_write "$CORE_INFO" 0644 root:root
  ev "core installed: version=$(upstream_get CORE_VERSION) sha256=$sha"
  log_ok "upstream core verified (sha256 ${sha:0:16}...)"
}

core_installed_sha() { kv_get "$CORE_INFO" CORE_SHA256 ""; }
core_installed_version() { kv_get "$CORE_INFO" CORE_VERSION ""; }

core_verify_installed() { # 0 if the binary on disk matches the recorded checksum
  local want
  [[ -x "$CORE_BIN" ]] || return 1
  want="$(core_installed_sha)"
  [[ -n "$want" && "$(core_sha256 "$CORE_BIN")" == "$want" ]]
}
