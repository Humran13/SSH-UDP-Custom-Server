#!/usr/bin/env bash
# SSH UDP Custom Server - one-line installer (bootstrap)
#
#   curl -fsSL https://raw.githubusercontent.com/Humran13/SSH-UDP-Custom-Server/main/install.sh | sudo bash
#
# What this does, in order:
#   1. resolves the latest release (or SSHUDP_VERSION) from GitHub Releases over HTTPS,
#   2. downloads the release archive + SHA256SUMS and verifies the checksum,
#   3. checks the archive for unsafe paths, then runs its installer.
# Nothing on the system is modified before step 3, and TLS verification is never disabled.
set -Eeuo pipefail

REPO="Humran13/SSH-UDP-Custom-Server"
BASE="https://github.com/${REPO}/releases"
PROTO="=https"
if [[ "${SSHUDP_TESTING:-}" == "1" ]]; then
  BASE="${SSHUDP_RELEASE_BASE:-$BASE}"
  PROTO="=https,http"
fi

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die() { red "error: $*"; exit 1; }
dl() { curl --proto "$PROTO" --tlsv1.2 -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -o "$2" -- "$1"; }

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && {
  echo "usage: sudo bash install.sh [--quick|--advanced] [--yes]"
  echo "env:   SSHUDP_VERSION=1.2.3  install a specific release"
  exit 0
}
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "please run as root:  curl -fsSL <url> | sudo bash"
for c in curl tar sha256sum awk; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' is required (apt-get install -y curl tar coreutils gawk)"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sshudp-install.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
chmod 0700 "$WORK"

# Testing shortcut: run from a local checkout instead of a release.
if [[ "${SSHUDP_TESTING:-}" == "1" && -n "${SSHUDP_SRC_DIR:-}" ]]; then
  exec "$SSHUDP_SRC_DIR/bin/sshudp" _install "$@"
fi

VERSION="${SSHUDP_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  dl "$BASE/latest/download/VERSION" "$WORK/VERSION" || die "could not determine the latest release (network or GitHub problem)"
  VERSION="$(tr -d '[:space:]' <"$WORK/VERSION")"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version string: $VERSION"

NAME="ssh-udp-custom-server-v${VERSION}"
echo "SSH UDP Custom Server v${VERSION}: downloading and verifying..."
dl "$BASE/download/v${VERSION}/${NAME}.tar.gz" "$WORK/${NAME}.tar.gz" || die "download of the release archive failed"
dl "$BASE/download/v${VERSION}/SHA256SUMS" "$WORK/SHA256SUMS" || die "download of SHA256SUMS failed"

WANT="$(awk -v f="${NAME}.tar.gz" '$2 == f || $2 == "*" f { print $1; exit }' "$WORK/SHA256SUMS")"
[[ "$WANT" =~ ^[0-9a-f]{64}$ ]] || die "no checksum for ${NAME}.tar.gz in SHA256SUMS"
GOT="$(sha256sum "$WORK/${NAME}.tar.gz" | awk '{ print $1 }')"
[[ "$GOT" == "$WANT" ]] || die "checksum mismatch - refusing to continue (expected $WANT, got $GOT)"

while IFS= read -r m; do
  case "$m" in
    /* | *..*) die "unsafe path in archive: $m" ;;
    "$NAME" | "$NAME"/*) ;;
    *) die "unexpected path in archive: $m" ;;
  esac
done < <(tar -tzf "$WORK/${NAME}.tar.gz")
tar -tvzf "$WORK/${NAME}.tar.gz" | cut -c1 | grep -qv '^[-d]$' && die "archive contains links or special files"

tar -xzf "$WORK/${NAME}.tar.gz" -C "$WORK" --no-same-owner --no-same-permissions
[[ -x "$WORK/$NAME/bin/sshudp" ]] || chmod 0755 "$WORK/$NAME/bin/sshudp"
[[ "$(tr -d '[:space:]' <"$WORK/$NAME/VERSION")" == "$VERSION" ]] || die "archive VERSION does not match"

# The installer runs from the verified copy; it installs itself to /usr/local/lib/ssh-udp-custom.
"$WORK/$NAME/bin/sshudp" _install "$@"
