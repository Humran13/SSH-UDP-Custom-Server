#!/usr/bin/env bash
# Host-side driver: build a systemd Ubuntu container per release and run the whole suite.
#   tests/run-matrix.sh 22.04 24.04            (default: 22.04)
# Needs Docker with --privileged containers. Results: tests/results/ubuntu-<v>.tap
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
VERSIONS=("$@")
((${#VERSIONS[@]})) || VERSIONS=(22.04)
BATS_ARGS="${BATS_ARGS:-tests/unit tests/integration}"
mkdir -p tests/results
overall=0
for v in "${VERSIONS[@]}"; do
  img="sshudp-test:$v"; name="sshudp-t-${v//./}"
  echo "=== Ubuntu $v: building image"
  docker build -q --build-arg UBUNTU_VERSION="$v" -t "$img" tests/docker >/dev/null
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock "$img" >/dev/null
  ok=0
  for _ in $(seq 40); do
    s="$(docker exec "$name" systemctl is-system-running 2>&1 || true)"
    [[ "$s" == running || "$s" == degraded ]] && { ok=1; break; }
    sleep 1
  done
  if ((!ok)); then
    echo "!!! systemd did not boot in the Ubuntu $v container (state: $s) - cannot run integration tests"
    echo "systemd-boot-failed: $s" >"tests/results/ubuntu-$v.tap"
    docker rm -f "$name" >/dev/null 2>&1 || true
    overall=1
    continue
  fi
  echo "=== Ubuntu $v: systemd $(docker exec "$name" systemctl --version | head -1 | cut -d' ' -f2), kernel $(docker exec "$name" uname -r)"
  docker exec "$name" mkdir -p /src
  { tar --exclude=.git --exclude=tests/results -cf - . || [[ $? -eq 1 ]]; } | docker exec -i "$name" tar -xf - -C /src
  rc=0
  docker exec -e BATS_ARGS="$BATS_ARGS" "$name" bash -c 'cd /src && bash tests/integration/entrypoint.sh $BATS_ARGS' >"tests/results/ubuntu-$v.tap" 2>&1 || rc=$?
  passed="$(grep -c '^ok ' "tests/results/ubuntu-$v.tap" || true)"
  failed="$(grep -c '^not ok ' "tests/results/ubuntu-$v.tap" || true)"
  skipped="$(grep -c '^ok .* # skip' "tests/results/ubuntu-$v.tap" || true)"
  echo "=== Ubuntu $v: passed=$passed failed=$failed skipped=$skipped (exit $rc)"
  grep '^not ok ' "tests/results/ubuntu-$v.tap" || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  ((rc == 0)) || overall=1
done
exit "$overall"
