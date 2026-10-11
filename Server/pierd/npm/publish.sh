#!/bin/sh
# usage: publish.sh <out> — publishes what build.sh made: the per-platform packages first, then the launcher. A
# version already on the registry is skipped, so a run that stopped halfway can be run again.
set -eu
out=$1
publish() {
  spec=$(node -p 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); p.name + "@" + p.version' "$1/package.json")
  if [ -n "$(npm view "$spec" version 2>/dev/null)" ]; then
    echo "$spec is already published"
  else
    (cd "$1" && npm publish --access public)
  fi
}
for dir in "$out"/pierd-*; do publish "$dir"; done
publish "$out/pierd"
