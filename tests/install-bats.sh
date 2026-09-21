#!/usr/bin/env bash
# Installs bats-core (pinned) into /usr/local for the test-suite.
set -Eeuo pipefail
V=v1.11.0
command -v bats >/dev/null 2>&1 && exit 0
T="$(mktemp -d)"
git clone -q --depth 1 --branch "$V" https://github.com/bats-core/bats-core.git "$T/bats"
"$T/bats/install.sh" /usr/local >/dev/null
rm -rf "$T"
bats --version
