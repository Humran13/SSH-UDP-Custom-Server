#!/usr/bin/env bash
# public-install-test.sh - runs the EXACT one-line command that end users run
# (installer downloaded from GitHub RAW, NOT a local file), then walks through the
# acceptance checklist: manager, UDP service, SSH still working, user creation,
# expiry, doctor, update, repair, backup/restore, uninstall, reinstall.
#
# Usage (as root, on a disposable Ubuntu machine/container with systemd):
#   bash tests/public-install-test.sh [path/to/local/install.sh]
# It never sets SSHUDP_TESTING: production code paths and HTTPS-only downloads only.
set -uo pipefail

URL="https://raw.githubusercontent.com/Humran13/SSH-UDP-Custom-Server/main/install.sh"
LOCAL="${1:-$(dirname "$0")/../install.sh}"
SO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
FAILS=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@" >/tmp/pit.out 2>&1; then pass "$d"; else fail "$d"; sed 's/^/      | /' /tmp/pit.out | tail -15; fi; }
pw_of() { grep -m1 'Password ' | sed -E 's/^.*Password +: ([^ ]+) .*$/\1/'; }
wait_for() { local n="$1" i; shift; for i in $(seq "$n"); do "$@" && return 0; sleep 1; done; return 1; }
udp_up() { ss -H -lun | awk '$4 ~ /:36712$/ { f = 1 } END { exit f ? 0 : 1 }'; }

tunnel_ok() { # user password port
  local u="$1" p="$2" port="$3" pid want got
  mkdir -p /tmp/pweb && echo SSH_UDP_TEST_OK >/tmp/pweb/probe.txt
  [ -s /tmp/pweb/blob.bin ] || head -c 1500000 /dev/urandom >/tmp/pweb/blob.bin
  curl -fs http://127.0.0.1:8090/probe.txt >/dev/null 2>&1 ||
    { ( cd /tmp/pweb && exec python3 -m http.server 8090 --bind 127.0.0.1 >/dev/null 2>&1 ) & sleep 1; }
  # shellcheck disable=SC2086
  sshpass -p "$p" ssh $SO -N -L "$port:127.0.0.1:8090" "$u@127.0.0.1" &
  pid=$!
  wait_for 20 bash -c "curl -fs http://127.0.0.1:$port/probe.txt | grep -q SSH_UDP_TEST_OK"
  want="$(sha256sum /tmp/pweb/blob.bin | cut -d' ' -f1)"
  got="$(curl -fs "http://127.0.0.1:$port/blob.bin" | sha256sum | cut -d' ' -f1)"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ "$want" = "$got" ]
}

echo "== environment: $(. /etc/os-release && echo "$PRETTY_NAME"), $(uname -m), kernel $(uname -r)"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 2; }
command -v sshpass >/dev/null || apt-get install -y -qq sshpass >/dev/null
command -v python3 >/dev/null || apt-get install -y -qq python3 >/dev/null
useradd -m -s /bin/bash admin1 2>/dev/null; echo 'admin1:AdminPass123' | chpasswd
sha256sum /etc/ssh/sshd_config >/tmp/sshd_config.before

# 1. RAW installer identity ---------------------------------------------------
curl -fsSL "$URL" -o /tmp/raw-install.sh
RAW_SHA="$(sha256sum /tmp/raw-install.sh | cut -d' ' -f1)"
LOC_SHA="$(sha256sum "$LOCAL" | cut -d' ' -f1)"
echo "   raw  install.sh sha256: $RAW_SHA"
echo "   repo install.sh sha256: $LOC_SHA"
[ "$RAW_SHA" = "$LOC_SHA" ] && pass "GitHub RAW installer is byte-identical to the repository file" || fail "GitHub RAW installer differs from the local file (is main pushed?)"

# 2. the public one-liner -----------------------------------------------------
echo "== running: curl -fsSL $URL | sudo bash"
# shellcheck disable=SC2024
if curl -fsSL "$URL" | sudo bash >/tmp/pit-install.log 2>&1; then pass "public one-line installer exits 0"; else fail "public one-line installer"; tail -30 /tmp/pit-install.log; fi
grep -q 'installed successfully' /tmp/pit-install.log && pass "installer reports success" || fail "installer success message"
EXPECT_VER="$(tr -d '[:space:]' <"$(dirname "$LOCAL")/VERSION")"
[ "$(sshudp version | awk '{ print $2 }')" = "$EXPECT_VER" ] && pass "installed version matches repository VERSION ($EXPECT_VER)" || fail "installed version != $EXPECT_VER ($(sshudp version 2>&1))"

# 3. manager, service, ssh ----------------------------------------------------
check "sshudp status works" sshudp status
check "UDP service active + listening" bash -c 'systemctl is-active --quiet ssh-udp-custom.service'
wait_for 15 udp_up && pass "UDP port 36712 listening" || fail "UDP port 36712 listening"
check "sshd config untouched (drop-in only)" sha256sum -c /tmp/sshd_config.before
check "existing SSH login (admin1) still works" bash -c "sshpass -p AdminPass123 ssh $SO admin1@127.0.0.1 'echo ok' | grep -q ok"
check "doctor passes" bash -c 'sshudp doctor | tee /tmp/doc.out | grep -q "0 failed"'
sshudp doctor 2>&1 | sed 's/^/      | /' | grep -E 'FAIL|WARN|Summary' || true

# 4. users --------------------------------------------------------------------
OUT="$(sshudp create-user demo --days 30)"
PW="$(printf '%s\n' "$OUT" | pw_of)"
[ -n "$PW" ] && pass "user created, card shown" || fail "user creation"
check "tunnel account works (login + forward + sha256 of 1.5 MB)" tunnel_ok demo "$PW" 18101
check "tunnel account has no shell" bash -c "! sshpass -p '$PW' ssh $SO demo@127.0.0.1 'echo BAD' 2>&1 | grep -q '^BAD'"

# 5. expiry -------------------------------------------------------------------
sed -i "s/^EXPIRES=.*/EXPIRES=$(date -d yesterday +%F)/" /var/lib/ssh-udp-custom/users/demo.meta
systemctl start ssh-udp-custom-expiry.service
check "expiry timer service locks the expired user" bash -c '[ "$(passwd -S demo | cut -d" " -f2)" = L ]'
check "expired user cannot log in" bash -c "! sshpass -p '$PW' ssh $SO -o NumberOfPasswordPrompts=1 demo@127.0.0.1 true"
check "unrelated admin1 untouched" bash -c '[ "$(passwd -S admin1 | cut -d" " -f2)" = P ]'
sshudp renew-user demo 10 >/dev/null
check "renewed user works again" tunnel_ok demo "$PW" 18102
check "expiry timer is active and scheduled" bash -c 'systemctl is-active --quiet ssh-udp-custom-expiry.timer'

# 6. update / repair / backup / restore ---------------------------------------
check "update --check works against real GitHub" bash -c 'sshudp update --check | grep -Eq "up to date|update available"'
systemctl stop ssh-udp-custom.service; rm -f /etc/ssh-udp-custom/udp-custom.json
check "repair restores a damaged installation" bash -c 'sshudp repair >/dev/null 2>&1'
wait_for 15 udp_up && pass "service listening after repair" || fail "service listening after repair"
BK="$(sshudp backup | sed 's/^backup created: //')"
[ -f "$BK" ] && pass "backup created ($(basename "$BK"))" || fail "backup"
sshudp config udp-exclude 53,123,9999 >/dev/null
check "restore returns the earlier configuration" bash -c "sshudp restore '$(basename "$BK")' >/dev/null 2>&1 && ! grep -q 9999 /etc/ssh-udp-custom/config.conf"
check "doctor passes after restore" bash -c 'sshudp doctor | grep -q "0 failed"'

# 7. uninstall / reinstall -----------------------------------------------------
check "uninstall (users + data removed)" bash -c 'sshudp uninstall --yes --remove-users --purge >/dev/null 2>&1'
check "uninstall left OpenSSH, sshd_config and admin1 alone" bash -c 'sha256sum -c /tmp/sshd_config.before && systemctl is-active --quiet ssh && id admin1 && sshpass -p AdminPass123 ssh '"$SO"' admin1@127.0.0.1 true'
check "uninstall removed our services and firewall table" bash -c '! systemctl list-unit-files | grep -q ssh-udp-custom && ! nft list table inet sshudp && [ ! -e /usr/local/bin/sshudp ]'
echo "== reinstalling with the public one-liner"
# shellcheck disable=SC2024
if curl -fsSL "$URL" | sudo bash >/tmp/pit-reinstall.log 2>&1; then pass "reinstall via public one-liner"; else fail "reinstall"; tail -20 /tmp/pit-reinstall.log; fi
wait_for 15 udp_up && pass "UDP listening after reinstall" || fail "UDP listening after reinstall"
check "doctor passes after reinstall" bash -c 'sshudp doctor | grep -q "0 failed"'
sshudp uninstall --yes --remove-users --purge >/dev/null 2>&1

echo
if ((FAILS == 0)); then echo "ALL CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; fi
exit "$FAILS"
