#!/usr/bin/env bash
# Builds the open-source Hysteria v1.3.5 (MIT) client used ONLY as a test fixture
# (tests/fixtures/hy-client). It is not part of the product and is git-ignored.
set -Eeuo pipefail
cd "$(dirname "$0")"
if command -v go >/dev/null 2>&1 && go version | grep -q 'go1\.2[0-3]'; then
  T="$(mktemp -d)"
  git clone -q --depth 1 --branch v1.3.5 https://github.com/apernet/hysteria.git "$T/h"
  ( cd "$T/h/app" && CGO_ENABLED=0 go build -o "$PWD/../../hy-client-built" ./cmd ) || true
  mv "$T/hy-client-built" hy-client 2>/dev/null || true
fi
if [[ ! -x hy-client ]]; then
  docker run --rm -v "$PWD:/out" golang:1.20 bash -c '
    set -e; git clone -q --depth 1 --branch v1.3.5 https://github.com/apernet/hysteria.git /h
    cd /h/app && CGO_ENABLED=0 go build -o /out/hy-client ./cmd && chmod 755 /out/hy-client'
fi
chmod +x hy-client 2>/dev/null || true
ls -l hy-client
