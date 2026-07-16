<p align="center">
  <img src="docs/assets/command-bloom-mark.svg" alt="CommandBloom" width="112">
</p>

<h1 align="center">CommandBloom</h1>

<p align="center">
  A native, open-source Actions Ring alternative for Logitech MX Master 4 on macOS.
</p>

![CommandBloom running on macOS](docs/assets/command-bloom-demo.gif)

CommandBloom turns the MX Master 4 Haptic Sense Panel into a fast radial
launcher for apps, shortcuts, URLs, commands, and app-specific actions. It runs
locally, talks directly to the mouse, and has no configuration UI: the CLI is
designed to be configured for you by a coding agent.

> Source builds only for now. Requires macOS 26, Swift 6.2, and an MX Master 4.

## Build and install

Build from the repository root, then sign the daemon with a stable code-signing
identity. Do not install SwiftPM's ad-hoc-signed daemon: macOS permissions are
tied to its signature.

```sh
git clone https://github.com/bra1nDump/command-bloom.git
cd command-bloom
swift build -c release
codesign --force --sign "YOUR STABLE SIGNING IDENTITY" \
  --identifier com.logiliquid.controls.daemon --options runtime \
  .build/release/logi-liquid-daemon
```

`security find-identity -v -p codesigning` lists usable identities. A local
self-signed **Code Signing** certificate is sufficient.

Logi Options+ cannot own the Sense Panel at the same time. Release its device
manager, install CommandBloom's per-user service, then run the overlay:

```sh
launchctl disable "gui/$(id -u)/com.logi.cp-dev-mgr"
launchctl bootout "gui/$(id -u)/com.logi.cp-dev-mgr" 2>/dev/null || true
./.build/release/logi-liquid service install
./.build/release/logi-liquid-overlay
```

Grant **Input Monitoring** and **Accessibility** in **System Settings → Privacy
& Security** to:

```text
~/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-daemon
```

Then restart and verify:

```sh
./.build/release/logi-liquid service restart
./.build/release/logi-liquid doctor
```

## Let an agent configure it

Give your coding agent a prompt like this:

> Configure CommandBloom with Spotify on top, Telegram on the right, and
> Command-B in the bottom zone when Xcode is active. Inspect
> `./.build/release/logi-liquid help`, apply the `actions put-*` commands, and
> verify with `actions resolve --app com.apple.dt.Xcode`.

Configuration is durable and CLI-only. See the [technical
reference](docs/technical.md) for every action, diagnostic, recovery path, and
the steps to return Sense Panel ownership to Logi Options+.

CommandBloom is an independent, unofficial project. It is not affiliated with,
endorsed by, or sponsored by Logitech. Logitech, Logi, MX Master, and Actions
Ring are trademarks of their respective owners.
