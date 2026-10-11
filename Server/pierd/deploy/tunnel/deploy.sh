#!/bin/sh
# usage: deploy.sh root@HOST [VERSION] — installs (or updates) the Pier tunnel on a fresh Ubuntu/Debian server: the
# pierd release for its CPU (checked against the release's checksums) in /usr/local/bin, a "pier" user, the
# pier-tunnel service on port 443 and a firewall that lets in SSH and 443 only. Run it again to update.
# DNS: t.<domain> and *.t.<domain> point at the server (DNS only, no proxy); pierd's relay.Official names t.<domain>:443.
set -eu
target=$1 version=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
scp -q "$here/pier-tunnel.service" "$target:/tmp/pier-tunnel.service"
ssh "$target" PIERD_VERSION="$version" sh -s <<'REMOTE'
set -eu
case $(uname -m) in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported CPU $(uname -m)"; exit 1 ;; esac
repo=wagnerfnds/pier
version=${PIERD_VERSION:-}
if [ -z "$version" ]; then
  version=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=30" | sed -n 's/.*"tag_name": *"pierd-v\([^"]*\)".*/\1/p' | head -n 1)
fi
name=pierd-v$version-linux-$arch
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=https://github.com/$repo/releases/download/pierd-v$version
curl -fsSL "$base/$name.tar.gz" -o "$tmp/$name.tar.gz"
curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt"
want=$(sed -n "s/^\([0-9a-f]\{64\}\)  $name\.tar\.gz\$/\1/p" "$tmp/checksums.txt")
got=$(sha256sum "$tmp/$name.tar.gz" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "checksum mismatch"; exit 1; }
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
install -m 755 "$tmp/$name/pierd" /usr/local/bin/pierd.new && mv /usr/local/bin/pierd.new /usr/local/bin/pierd
id pier >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pier --shell /usr/sbin/nologin pier
install -m 644 /tmp/pier-tunnel.service /etc/systemd/system/pier-tunnel.service
systemctl daemon-reload
systemctl enable --now pier-tunnel >/dev/null 2>&1
systemctl restart pier-tunnel
if command -v ufw >/dev/null 2>&1; then
  ufw allow OpenSSH >/dev/null; ufw allow 443/tcp >/dev/null; ufw --force enable >/dev/null
fi
sleep 1
systemctl is-active pier-tunnel
/usr/local/bin/pierd version
REMOTE
