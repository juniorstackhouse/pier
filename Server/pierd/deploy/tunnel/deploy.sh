#!/bin/sh
# usage: deploy.sh USER@HOST [VERSION] [--cloudflared] — installs (or updates) the Pier tunnel on an Ubuntu/Debian
# server, as root or
# as a user with sudo: the pierd release for its CPU (checked against the release's checksums) in /usr/local/bin, a
# "pier" user and the pier-tunnel service on port 443. When ufw is on, it lets 443 in; it never turns a firewall on
# (a machine with other services keeps them). Run it again to update.
# Straight to the internet: DNS t.<domain> points at the server (DNS only) and pierd's relay.Official names
# t.<domain>:443; behind a router, forward TCP 443 to the server. With --cloudflared the tunnel listens on
# 127.0.0.1:7443 only and a Cloudflare Tunnel on the same machine brings https://t.<domain> to it (a public hostname,
# service http://localhost:7443): relay.Official is then wss://t.<domain>, and nothing listens to the internet.
# --share-domain D also serves boxes' public links at https://p-<name>.D (docs/PROTOCOL.md §10.1): the Cloudflare Tunnel
# then needs a public hostname *.D (service http://localhost:7443) with its DNS wildcard *.D on the tunnel; the
# hostnames already there (t, www, the apex) keep their own records. *.D is a first-level wildcard, which Cloudflare's
# Universal SSL certificate covers.
set -eu
target=$1
shift
version="" args="--listen :443 --public" share=""
want_share=""
for a in "$@"; do
  if [ -n "$want_share" ]; then share=$a; want_share=""; continue; fi
  case $a in
    --cloudflared) args="--listen 127.0.0.1:7443 --public --behind-proxy" ;;
    --share-domain) want_share=1 ;;
    --share-domain=*) share=${a#--share-domain=} ;;
    *) version=$a ;;
  esac
done
if [ -n "$share" ]; then args="$args --share-domain $share"; fi
here=$(cd "$(dirname "$0")" && pwd)
# SSH_OPTS="-i ~/.ssh/key" for a key ssh does not pick by itself.
o=${SSH_OPTS:-}
scp $o -q "$here/pier-tunnel.service" "$target:/tmp/pier-tunnel.service"
# PIERD_BINARY=path installs that build (a test before a release) instead of downloading one.
if [ -n "${PIERD_BINARY:-}" ]; then scp $o -q "$PIERD_BINARY" "$target:/tmp/pierd.local"; fi
ssh $o "$target" sudo PIERD_VERSION="$version" PIER_TUNNEL_ARGS="'$args'" sh -s <<'REMOTE'
set -eu
case $(uname -m) in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported CPU $(uname -m)"; exit 1 ;; esac
if [ -f /tmp/pierd.local ]; then
  install -m 755 /tmp/pierd.local /usr/local/bin/pierd.new && mv /usr/local/bin/pierd.new /usr/local/bin/pierd && rm -f /tmp/pierd.local
else
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
fi
id pier >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pier --shell /usr/sbin/nologin pier
install -m 644 /tmp/pier-tunnel.service /etc/systemd/system/pier-tunnel.service
printf 'PIER_TUNNEL_ARGS="%s"\n' "$PIER_TUNNEL_ARGS" > /etc/default/pier-tunnel
systemctl daemon-reload
systemctl enable --now pier-tunnel >/dev/null 2>&1
systemctl restart pier-tunnel
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 443/tcp >/dev/null
fi
sleep 1
systemctl is-active pier-tunnel
/usr/local/bin/pierd version
REMOTE
