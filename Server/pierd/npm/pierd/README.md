# pierd

The server each of your machines runs for [Pier](https://wagnerfnds.github.io/pier/), the app that shows and drives
your coding agents (Claude Code, Codex) from iPhone, iPad and Mac. Open source: [github.com/wagnerfnds/pier](https://github.com/wagnerfnds/pier).

```sh
npm install -g pierd
pierd setup
```

`pierd setup` runs pierd as a user service (systemd on Linux, launchd on a Mac), installs the agents' hooks, adds the
git repositories it finds in `~/code`, `~/Projects`… as projects, and prints a pairing link with its QR code. On a Mac
at its own screen the Pier app pairs with it by itself.

Linux and macOS, on x64 and arm64. Other ways to install: `curl -fsSL https://wagnerfnds.github.io/pier/install.sh | sh`
or `brew install wagnerfnds/tap/pierd`.
