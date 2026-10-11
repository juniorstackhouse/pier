#!/bin/sh
# usage: formula.sh <version> [checksums.txt] — prints the Homebrew formula for a pierd release (Formula/pierd.rb in
# github.com/wagnerfnds/homebrew-tap), its sha256s read from the release's checksums.txt (downloaded when not given).
set -eu
v=${1#v} sums=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "$sums" ]; then
  sums=$(mktemp)
  trap 'rm -f "$sums"' EXIT
  curl -fsSL "https://github.com/wagnerfnds/pier/releases/download/pierd-v$v/checksums.txt" -o "$sums"
fi
get() { sed -n "s/^\([0-9a-f]\{64\}\)  pierd-v$v-$1\.tar\.gz\$/\1/p" "$sums"; }
da=$(get darwin-arm64) di=$(get darwin-amd64) la=$(get linux-arm64) li=$(get linux-amd64)
for x in "$da" "$di" "$la" "$li"; do [ ${#x} -eq 64 ] || { echo "formula.sh: a checksum is missing for v$v" >&2; exit 1; }; done
sed -e "s/@VERSION@/$v/g" -e "s/@DARWIN_ARM64@/$da/" -e "s/@DARWIN_AMD64@/$di/" -e "s/@LINUX_ARM64@/$la/" \
  -e "s/@LINUX_AMD64@/$li/" "$here/pierd.rb.tmpl"
