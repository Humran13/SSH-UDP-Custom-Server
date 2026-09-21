#!/usr/bin/env bash
# Removes SSH UDP Custom Server (project-owned components only).
# Equivalent to: sudo sshudp uninstall
set -Eeuo pipefail
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "error: run as root (sudo bash uninstall.sh)" >&2; exit 1; }
if [[ -x /usr/local/bin/sshudp ]]; then
  exec /usr/local/bin/sshudp uninstall "$@"
fi
echo "SSH UDP Custom Server does not appear to be installed (no /usr/local/bin/sshudp)." >&2
exit 1
