#!/usr/bin/env bash
# Build the release archive + checksums into ./dist (used by CI and by tests).
set -Eeuo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' <VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad VERSION" >&2; exit 1; }
NAME="ssh-udp-custom-server-v${VERSION}"
OUT="${1:-dist}"
rm -rf "${OUT:?}/$NAME" "${OUT:?}/$NAME.tar.gz" "${OUT:?}/SHA256SUMS" "${OUT:?}/VERSION"
mkdir -p "$OUT/$NAME"
cp -a bin lib scripts systemd VERSION upstream.conf LICENSE uninstall.sh "$OUT/$NAME/"
chmod 0755 "$OUT/$NAME/bin/sshudp" "$OUT/$NAME/uninstall.sh"
# deterministic archive (sorted, fixed owner/mtime)
( cd "$OUT" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2020-01-01 00:00Z' \
    -czf "$NAME.tar.gz" "$NAME" )
rm -rf "${OUT:?}/$NAME"
( cd "$OUT" && sha256sum "$NAME.tar.gz" > SHA256SUMS )
printf '%s\n' "$VERSION" > "$OUT/VERSION"
echo "built $OUT/$NAME.tar.gz"
cat "$OUT/SHA256SUMS"
