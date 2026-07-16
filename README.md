- An open-source Actions Ring alternative for the Logitech MX Master 4 on macOS
- Native and local — talks directly to the mouse, nothing leaves your machine
- No settings UI — your coding agent installs and configures it

<!--
The URL below is a github user-attachments upload of
docs/assets/command-bloom-demo.mp4 — GitHub only plays those inline. If the
demo is regenerated, re-upload it through the README web editor and replace
this URL.
-->

https://github.com/user-attachments/assets/f5f9d8a9-18c9-4357-9433-fe4240b5a7b8

## Install

**Have your coding agent check the code for ill intent or issues first — then
let it clone, build, and walk you through setup.** Copy this to your agent:

```text
Clone https://github.com/bra1nDump/command-bloom and read the source before
running anything: confirm there is nothing malicious or promotional in it.
Then build it and walk me through setup on macOS — code signing, service
install, and permissions — following the "Manual build and setup" section of
README.md.
```

Needs macOS 26, Swift 6.2, and an MX Master 4. Setup takes a few minutes; two
permission toggles in System Settings are the only manual part.

## Make it yours

Once installed, tell your agent what you want on the ring:

> Configure CommandBloom with Spotify on top, Telegram on the right, and
> Command-B in the bottom zone when Xcode is active.

Configuration is durable, local, and CLI-only. The complete command surface is
in the [technical reference](docs/technical.md).

---

## Manual build and setup

Everything below is what your agent follows — or what you run yourself.

### Build and sign

macOS ties Input Monitoring and Accessibility grants to the daemon's
code-signing identity, and SwiftPM's default ad-hoc signature changes on every
build. Sign the release daemon with a stable identity before installing:

```sh
git clone https://github.com/bra1nDump/command-bloom.git
cd command-bloom
swift build -c release
codesign --force --sign "YOUR STABLE SIGNING IDENTITY" \
  --identifier com.logiliquid.controls.daemon --options runtime \
  .build/release/logi-liquid-daemon
```

`security find-identity -v -p codesigning` lists usable identities. If none
exist, create a self-signed **Code Signing** certificate in Keychain Access
(Certificate Assistant → Create a Certificate) and use its name.

### Take over the Sense Panel and install

Logi Options+ cannot own the Sense Panel at the same time. Unload only its
device manager, then install. `service install` sets up two per-user
LaunchAgents — the daemon (device, actions, haptics) and the overlay (the
ring you see) — and starts both:

```sh
launchctl disable "gui/$(id -u)/com.logi.cp-dev-mgr"
launchctl bootout "gui/$(id -u)/com.logi.cp-dev-mgr" 2>/dev/null || true
./.build/release/logi-liquid service install
```

### Grant permissions

In **System Settings → Privacy & Security**, grant **Input Monitoring** and
**Accessibility** to:

```text
~/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-daemon
```

Then restart and verify — every check in `doctor` should be `ok`:

```sh
./.build/release/logi-liquid service restart
./.build/release/logi-liquid doctor
```

### Logs and debugging

Both services log to one place:

| Log | Path |
| --- | --- |
| Daemon | `~/Library/Application Support/Logi Liquid Controls/logs/daemon.log` and `daemon.error.log` |
| Overlay | `~/Library/Application Support/Logi Liquid Controls/logs/overlay.log` and `overlay.error.log` |

If the cursor hides on a Sense Panel press but no ring appears, the daemon is
fine and the overlay is not running or cannot reach it. `logi-liquid service
status` reports `daemonLoaded` and `overlayLoaded` separately, and
`overlay.error.log` logs a `presenting ring at (x, y)` line for every
invocation it actually renders. `logi-liquid service restart` restarts both
services.

To hand the Sense Panel back to Logi Options+, or for the full CLI grammar,
diagnostics, simulation, and recovery paths, see the
[technical reference](docs/technical.md).

---

CommandBloom is an independent, unofficial project. It is not affiliated with,
endorsed by, or sponsored by Logitech. Logitech, Logi, MX Master, and Actions
Ring are trademarks of their respective owners.
