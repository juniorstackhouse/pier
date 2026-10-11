#!/bin/sh
# usage: review.sh <video> <out.png> <t,t,…> — frames of the rendered film at those seconds, on one sheet
set -eu
here=$(cd "$(dirname "$0")" && pwd)
F=$(cd "$here" && node -e 'console.log(require("ffmpeg-static"))')
dir=$(mktemp -d)
for t in $(echo "$3" | tr ',' ' '); do
  "$F" -hide_banner -loglevel error -y -ss "$t" -i "$1" -frames:v 1 -vf scale=960:-1 "$dir/t$(printf '%06.2f' "$t").png"
done
node "$here/render.mjs" sheet "$2" 4 470 "$dir"/*.png
rm -rf "$dir"
