#!/usr/bin/env bash
# mock-release.sh REPO OUTDIR VERSION [--latest]
# Builds a release archive of REPO stamped as VERSION and lays it out like GitHub
# Releases under OUTDIR (download/vX/..., latest/download/VERSION).
set -Eeuo pipefail
repo="$1" out="$2" ver="$3" latest="${4:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -a "$repo/." "$tmp/repo"
rm -rf "$tmp/repo/.git" "$tmp/repo/dist"
printf '%s\n' "$ver" >"$tmp/repo/VERSION"
[[ -n "${MOCK_HOOK:-}" ]] && bash -c "$MOCK_HOOK" _ "$tmp/repo"
bash "$tmp/repo/scripts/build-release.sh" "$tmp/dist" >/dev/null
mkdir -p "$out/download/v$ver"
cp "$tmp/dist/ssh-udp-custom-server-v$ver.tar.gz" "$tmp/dist/SHA256SUMS" "$out/download/v$ver/"
if [[ "$latest" == "--latest" ]]; then
  mkdir -p "$out/latest/download"
  printf '%s\n' "$ver" >"$out/latest/download/VERSION"
fi
echo "mock release v$ver ready in $out"
