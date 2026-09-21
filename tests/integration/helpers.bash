# Helpers for the integration suite. These tests run INSIDE a systemd-booted
# Ubuntu container (see tests/run-matrix.sh) and exercise the real installer,
# real systemd units, real sshd and real firewalls.

export SSHUDP_TESTING=1
export NO_COLOR=1
export TERM=dumb
REL_DIR=/srv/rel
REL_URL=http://127.0.0.1:8000
SRC=/src
SO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

# Run a long-lived helper without inheriting bats' file descriptors.
bg() { "$@" >/dev/null 2>&1 3>&- 4>&- & }

mock_release() { bash "$SRC/tests/integration/mock-release.sh" "$SRC" "$REL_DIR" "$@" >/dev/null; }

install_quick() { SSHUDP_RELEASE_BASE="$REL_URL" bash "$SRC/install.sh" --quick "$@"; }

is_installed() { [ -d /usr/local/lib/ssh-udp-custom ] || [ -e /etc/systemd/system/ssh-udp-custom.service ]; }

# Remove everything a previous test may have left (uses the project's own uninstaller first).
clean_slate() {
  if command -v sshudp >/dev/null 2>&1; then
    sshudp uninstall --yes --purge --remove-users >/dev/null 2>&1 || true
  fi
  systemctl stop ssh-udp-custom.service ssh-udp-custom-firewall.service >/dev/null 2>&1 || true
  rm -rf /usr/local/lib/ssh-udp-custom* /etc/ssh-udp-custom /var/lib/ssh-udp-custom /var/backups/ssh-udp-custom \
    /usr/local/bin/sshudp /etc/systemd/system/ssh-udp-custom* /etc/ssh/sshd_config.d/90-ssh-udp-custom.conf \
    /etc/sysctl.d/90-ssh-udp-custom.conf
  systemctl daemon-reload >/dev/null 2>&1 || true
  local u
  for u in demo lim1 stdin1 exp1 keep1 gen1 admin1 alice bob; do
    userdel "$u" >/dev/null 2>&1 || true
  done
  getent passwd sshudp >/dev/null && userdel sshudp >/dev/null 2>&1 || true
  getent group sshudp-users >/dev/null && groupdel sshudp-users >/dev/null 2>&1 || true
  nft delete table inet sshudp >/dev/null 2>&1 || true
  nft delete table inet unrelated >/dev/null 2>&1 || true
  return 0
}

# Extract the generated/shown password from a client card.
pw_from_card() { grep -m1 'Password ' | sed -E 's/^.*Password +: ([^ ]+) .*$/\1/'; }

ensure_web() {
  mkdir -p /tmp/web
  echo SSH_UDP_TEST_OK >/tmp/web/probe.txt
  [ -s /tmp/web/blob.bin ] || head -c 2000000 /dev/urandom >/tmp/web/blob.bin
  if ! curl -fs http://127.0.0.1:8080/probe.txt >/dev/null 2>&1; then
    ( cd /tmp/web && exec python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 3>&- 4>&- ) &
    for _ in $(seq 20); do curl -fs http://127.0.0.1:8080/probe.txt >/dev/null 2>&1 && break; sleep 0.3; done
  fi
}

# tunnel_ok USER PASSWORD [LOCAL_PORT] - password login + TCP forward + data check.
tunnel_ok() {
  local u="$1" p="$2" port="${3:-18081}" pid want got i=0
  ensure_web
  # shellcheck disable=SC2086
  sshpass -p "$p" ssh $SO -N -L "$port:127.0.0.1:8080" "$u@127.0.0.1" 3>&- &
  pid=$!
  for i in $(seq 25); do
    curl -fs "http://127.0.0.1:$port/probe.txt" 2>/dev/null | grep -q SSH_UDP_TEST_OK && break
    sleep 0.4
  done
  want="$(sha256sum /tmp/web/blob.bin | cut -d' ' -f1)"
  got="$(curl -fs "http://127.0.0.1:$port/blob.bin" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$want" = "$got" ]
}

login_fails() { # login_fails USER PASSWORD
  ! sshpass -p "$2" ssh $SO -o NumberOfPasswordPrompts=1 "$1@127.0.0.1" true >/dev/null 2>&1
}

udp_listening() { ss -H -lun | awk -v p=":$1" '$4 ~ p"$" { f = 1 } END { exit f ? 0 : 1 }'; }

wait_for() { # wait_for SECONDS COMMAND...
  local n="$1" i
  shift
  for i in $(seq "$n"); do
    "$@" && return 0
    sleep 1
  done
  return 1
}

make_admin() { # normal, non-managed administrator account used to prove isolation
  id "${1:-admin1}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${1:-admin1}"
  echo "${1:-admin1}:AdminPass123" | chpasswd
}
