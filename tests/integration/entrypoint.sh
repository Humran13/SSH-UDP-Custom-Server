#!/usr/bin/env bash
# Runs INSIDE the test container: prepares a mock release server and runs bats.
set -Eeuo pipefail
cd /src
bash tests/install-bats.sh >/dev/null
chmod +x tests/fixtures/hy-client 2>/dev/null || true
rm -rf /srv/rel && mkdir -p /srv/rel
bash tests/integration/mock-release.sh /src /srv/rel 1.0.0 --latest
( cd /srv/rel && exec python3 -m http.server 8000 --bind 127.0.0.1 >/tmp/mock-http.log 2>&1 3>&- 4>&- ) &
for _ in $(seq 20); do curl -fs http://127.0.0.1:8000/latest/download/VERSION >/dev/null 2>&1 && break; sleep 0.3; done
mkdir -p /results
: >/results/run.tap
# bats can linger when a test left an orphan holding its pipe, so finish as soon as the
# TAP plan (1..N) is complete instead of waiting for EOF.
bats --tap "${@:-tests/unit tests/integration}" >/results/run.tap 2>&1 &
bp=$!
plan=""
while kill -0 "$bp" 2>/dev/null; do
  [[ -n "$plan" ]] || plan="$(sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' /results/run.tap | head -1)"
  if [[ -n "$plan" ]] && (($(grep -cE '^(ok|not ok) ' /results/run.tap) >= plan)); then
    sleep 5
    kill "$bp" 2>/dev/null || true
    break
  fi
  sleep 2
done
wait "$bp" 2>/dev/null || true
cat /results/run.tap
if grep -q '^not ok ' /results/run.tap; then exit 1; fi
[[ -n "$plan" ]] || { echo "no TAP plan - suite did not start"; exit 1; }
exit 0
