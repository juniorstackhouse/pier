#!/usr/bin/env node
// pierd's npm launcher: runs the binary from the package npm installed for this OS and CPU (pierd-<os>-<cpu>, an
// optional dependency of this one). `pierd install` and `pierd setup` point the service and the agents' hooks at that
// binary itself, so neither goes through Node afterwards.
"use strict";
const { spawnSync } = require("child_process");

const pkg = `pierd-${process.platform}-${process.arch}`;
let bin;
try {
  bin = require.resolve(`${pkg}/bin/pierd`);
} catch {
  console.error(
    `pierd: there is no build for ${process.platform}/${process.arch} (npm did not install ${pkg}).\n` +
      "Builds exist for Linux and macOS, on x64 and arm64."
  );
  process.exit(1);
}
const run = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
if (run.error) {
  console.error(`pierd: ${run.error.message}`);
  process.exit(1);
}
process.exit(run.status === null ? 1 : run.status);
