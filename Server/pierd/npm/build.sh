#!/bin/sh
# usage: build.sh <version> <dist> <out> — the npm packages for a pierd release, from its tarballs
# (dist/pierd-v<version>-<os>-<arch>.tar.gz): out/pierd-<os>-<cpu>/ with the binary, and out/pierd/, the launcher
# that depends on them, all at <version>.
set -eu
version=$1 dist=$2 out=$3
here=$(cd "$(dirname "$0")" && pwd)
rm -rf "$out" && mkdir -p "$out"
for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64; do
  os=${target%/*} arch=${target#*/}
  cpu=$arch; [ "$arch" = amd64 ] && cpu=x64
  name=pierd-$os-$cpu dir=$out/$name
  mkdir -p "$dir/bin"
  tar -xzf "$dist/pierd-v$version-$os-$arch.tar.gz" -C "$dir"
  mv "$dir/pierd-v$version-$os-$arch/pierd" "$dir/bin/pierd" && rm -rf "$dir/pierd-v$version-$os-$arch"
  chmod 755 "$dir/bin/pierd"
  cat > "$dir/package.json" <<JSON
{
  "name": "$name",
  "version": "$version",
  "description": "pierd for $os/$cpu: the binary the pierd package runs.",
  "homepage": "https://wagnerfnds.github.io/pier/",
  "repository": { "type": "git", "url": "git+https://github.com/wagnerfnds/pier.git", "directory": "Server/pierd" },
  "license": "MIT",
  "os": ["$os"],
  "cpu": ["$cpu"],
  "files": ["bin/pierd"]
}
JSON
done
cp -R "$here/pierd" "$out/pierd"
node -e '
  const fs = require("fs"), path = process.argv[1], v = process.argv[2];
  const p = JSON.parse(fs.readFileSync(path, "utf8"));
  p.version = v;
  for (const k of Object.keys(p.optionalDependencies)) p.optionalDependencies[k] = v;
  fs.writeFileSync(path, JSON.stringify(p, null, 2) + "\n");
' "$out/pierd/package.json" "$version"
echo "npm packages for pierd $version in $out"
