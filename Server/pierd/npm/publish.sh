#!/bin/sh
# usage: publish.sh <out> — publishes what build.sh made: the per-platform packages first, then the launcher.
set -eu
out=$1
for dir in "$out"/pierd-*; do (cd "$dir" && npm publish --access public); done
(cd "$out/pierd" && npm publish --access public)
