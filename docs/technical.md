# CommandBloom technical reference

CommandBloom is a standalone native Swift project that implements an MX Master 4 Sense Panel
replacement for macOS. It owns the mouse's Sense Panel button, resolves a
cardinal action layout for the application that was frontmost at invocation,
and exposes configuration, diagnostics, simulation, and event streams through
the `logi-liquid` CLI.

**Status:** the standalone backend and native Liquid Glass overlay are
implemented and verified end to end with a physical MX Master 4. The signed
production daemon and the overlay each run as their own per-user LaunchAgent,
both installed by `service install`.

The backend currently:

- connects directly to the MX Master 4 over its Logitech HID++ vendor
  interface;
- temporarily diverts the Sense Panel button and its held-button raw movement,
  then hands movement to a freshly baselined system-pointer sampler after
  release so click-release-move remains continuous;
- relies on the Sense Panel's built-in physical click haptic during normal
  invocation, while retaining explicit firmware-haptic playback in the CLI for
  diagnostics;
- hides the pointer while the interaction is active, holds it through the
  terminal overlay animation, and restores only its own balanced hide on
  commit, dismissal, or shutdown;
- keeps the menu open after button release, latches when at least 35% of the
  moving bubble's area overlaps a target, fires the action and completion haptic
  once at latch, dismisses on a primary click before latch, and toggles closed
  on a second Sense Panel press;
- executes shortcut, application, URL, executable, and Spotify Play actions;
- snapshots the frontmost application's bundle ID once per invocation and uses
  it to resolve an application-specific bottom zone; and
- emits stable JSON on normal CLI commands and NDJSON on follow streams.

The visual surface is isolated in `LogiLiquidUI`; `LogiLiquidOverlay` contains
only native AppKit window and control-socket glue. Configuration and diagnostics
remain CLI-only.

## Requirements and build

The package requires macOS 26 and Swift 6.2. Build the CLI and its sibling
daemon from the repository root:

```sh
cd ~/projects/logi-mx-master-gorgeous-action-ring
swift build -c release
swift test
```

The resulting executables are:

```text
.build/release/logi-liquid
.build/release/logi-liquid-daemon
.build/release/logi-liquid-overlay
```

The examples below assume the current directory is the project root.

### Stable local signing

Input Monitoring and Accessibility grants are tied to the installed daemon's
code-signing identity. SwiftPM's ad-hoc signature changes between builds, so
sign the release daemon before every install.

List existing identities:

```sh
security find-identity -v -p codesigning
```

If none exist, open **Keychain Access → Certificate Assistant → Create a
Certificate**, select **Self Signed Root** and **Code Signing**, and give it a
stable name such as `CommandBloom Local`. Then sign:

```sh
codesign --force --sign "CommandBloom Local" \
  --identifier com.logiliquid.controls.daemon --options runtime \
  .build/release/logi-liquid-daemon
```

## Default layout

The first daemon start seeds this layout only when no configuration file
exists. Existing configuration is never overwritten.

| Zone | Role | Default actions |
| --- | --- | --- |
| Top | Entertainment | `Play Spotify` |
| Right | Common applications | `Telegram`, `ChatGPT Quick Chat` |
| Bottom | Frontmost-application actions | Empty placeholder |
| Left | Utilities | `Aqua Voice`, `CleanShot Capture`, `CleanShot Record` |

The action implementations are exact:

- `Play Spotify` launches Spotify when necessary and sends its native Play
  Apple Event.
- `Telegram` opens bundle ID `ru.keepcoder.Telegram`.
- `ChatGPT Quick Chat` sends Option-Space.
- `Aqua Voice` sends two Fn presses, 80 ms apart, for hands-free recording.
- `CleanShot Capture` opens `cleanshot://capture-area`.
- `CleanShot Record` opens `cleanshot://record-screen`.

Only populated actions become targets. The bottom zone remains present in the
resolved model when empty, but has no selectable action until the frontmost app
has one configured.

The ChatGPT target uses the package's bundled monochrome OpenAI/ChatGPT mark so
it reads like the surrounding SF Symbols instead of nesting the full app badge
inside a glass circle. Production and Jim render the same self-contained asset;
no installed-app resource path is consulted.

## Logi Options+ ownership

Logi Options+ and CommandBloom must not manage Sense Panel reporting at the same
time. Disable and unload only the Options+ device-manager job before installing
or starting CommandBloom:

```sh
launchctl disable "gui/$(id -u)/com.logi.cp-dev-mgr"
launchctl bootout "gui/$(id -u)/com.logi.cp-dev-mgr" 2>/dev/null || true
```

This does not touch the unrelated LogiRightSight webcam service and does not
delete Options+, its settings, or its database.

To return control to Options+, stop CommandBloom first, re-enable the job, and launch
the app:

```sh
./.build/release/logi-liquid service stop
launchctl enable "gui/$(id -u)/com.logi.cp-dev-mgr"
open /Applications/logioptionsplus.app
```

## Install and operate the services

`service install` copies the sibling release daemon and overlay into the
user's Application Support directory, writes a per-user LaunchAgent for each
(`com.logiliquid.controls.daemon` and `com.logiliquid.controls.overlay`), and
starts both immediately. Both agents use `KeepAlive`, so they restart after a
crash and start at login:

```sh
./.build/release/logi-liquid service install
```

Manage both LaunchAgents together and inspect lifecycle state and the running
daemon separately. `service status` reports `daemonLoaded` and `overlayLoaded`
individually:

```sh
./.build/release/logi-liquid service status
./.build/release/logi-liquid service start
./.build/release/logi-liquid service stop
./.build/release/logi-liquid service restart

./.build/release/logi-liquid status
./.build/release/logi-liquid doctor
./.build/release/logi-liquid device inspect
```

`service uninstall` stops both LaunchAgents and removes the installed
executables and plists. It deliberately preserves the action configuration and
logs, and it does not re-enable Logi Options+ automatically:

```sh
./.build/release/logi-liquid service uninstall
```

### Logs and the missing-overlay failure mode

Both services log through launchd into one directory:

| Log | Path |
| --- | --- |
| Daemon | `~/Library/Application Support/Logi Liquid Controls/logs/daemon.log`, `daemon.error.log` |
| Overlay | `~/Library/Application Support/Logi Liquid Controls/logs/overlay.log`, `overlay.error.log` |

The overlay logs its lifecycle with timestamps: startup, connection to the
daemon event stream, disconnects, and a `presenting ring at (x, y)` line for
every invocation it renders. If the cursor hides on a Sense Panel press but no
ring appears, the daemon is healthy and the overlay is not: check
`service status` for `overlayLoaded: false`, read `overlay.error.log`, and run
`service restart`.

Every non-streaming command writes one JSON object to stdout. Diagnostics go to
stderr, and failure classes have distinct nonzero exit codes, making the CLI
suitable for agent automation.

Follow streams use a bounded writer queue per client. A client that stops
reading is disconnected instead of blocking HID input, interaction state, or
daemon shutdown.

## Configure actions

Inspect the durable configuration or resolve the exact view for an application:

```sh
./.build/release/logi-liquid actions list
./.build/release/logi-liquid actions resolve
./.build/release/logi-liquid actions resolve --app com.apple.dt.Xcode
```

Create or replace globally placed actions:

```sh
./.build/release/logi-liquid actions put-spotify-play "Play Spotify" --zone top
./.build/release/logi-liquid actions put-application "Telegram" ru.keepcoder.Telegram --zone right
./.build/release/logi-liquid actions put-shortcut "ChatGPT Quick Chat" space --modifiers option --zone right
./.build/release/logi-liquid actions put-url "CleanShot Capture" cleanshot://capture-area --zone left
./.build/release/logi-liquid actions put-command "Open Notes Folder" /usr/bin/open --zone left -- /tmp/notes
```

`--zone` defaults to `top` when omitted. A put creates or replaces the named
action and gives it an ordered placement. Application-specific placement is
allowed only in the bottom zone. For example, these actions replace the empty
bottom area while Xcode is frontmost:

```sh
./.build/release/logi-liquid actions put-shortcut "Xcode Build" b --modifiers command --zone bottom --when-app com.apple.dt.Xcode
./.build/release/logi-liquid actions put-shortcut "Xcode Test" u --modifiers command --zone bottom --when-app com.apple.dt.Xcode
./.build/release/logi-liquid actions resolve --app com.apple.dt.Xcode
```

Reorder or remove only one application placement without deleting its shared
action payload or global references. Clearing persists an explicit empty
override, so Xcode does not fall back to the global bottom zone:

```sh
./.build/release/logi-liquid actions move "Xcode Test" 0 --zone bottom --when-app com.apple.dt.Xcode
./.build/release/logi-liquid actions remove "Xcode Test" --zone bottom --when-app com.apple.dt.Xcode
./.build/release/logi-liquid actions clear --zone bottom --when-app com.apple.dt.Xcode
```

`actions remove "Xcode Test"` without a scope retains its original destructive
meaning: it deletes the payload and every global/application reference.

The complete command grammar is available without contacting the daemon:

```sh
./.build/release/logi-liquid help
```

## Simulate and observe

Follow semantic events or raw HID++ reports as NDJSON. These commands stay open
until interrupted:

```sh
./.build/release/logi-liquid events follow
./.build/release/logi-liquid reports follow
```

Drive an interaction without touching the physical Sense Panel:

```sh
./.build/release/logi-liquid simulate invoke 800 450 --app com.apple.dt.Xcode
./.build/release/logi-liquid simulate release
./.build/release/logi-liquid simulate move 0 -90
```

Release is intentionally non-terminal. Movement latches a target at exactly
35% moving-bubble overlap; both physical and simulated input auto-complete after
the suction dwell. `simulate complete` remains an idempotent deterministic
control for scripts that need to advance immediately. A primary `click`
dismisses before latch and is ignored after latch. Explicit terminal controls
are:

```sh
./.build/release/logi-liquid simulate complete
./.build/release/logi-liquid simulate dismiss
./.build/release/logi-liquid simulate cancel
```

For deterministic automation, `simulate play FILE` accepts either a JSON array
or newline-delimited `RingInput` records; use `-` to read the scenario from
stdin. Firmware haptics can be tested independently with waveform IDs from 0
through 255:

```sh
./.build/release/logi-liquid simulate play scenario.ndjson
./.build/release/logi-liquid haptic play
./.build/release/logi-liquid haptic play 0
```

## Jim visual snapshots

Jim renders the real native overlay in representative interaction states and
captures deterministic PNG baselines:

```sh
./.build/release/jim list
./.build/release/jim render --state targeting --output /tmp/jim-targeting.png
./.build/release/jim record --directory jim/Snapshots
./.build/release/jim verify --directory jim/Snapshots
```

The checked-in states are `invoked`, `targeting`, `latched-suction-threshold`, and
`committed`. See [`jim/README.md`](../jim/README.md) for dimensions, comparison
tolerances, and the manifest contract.

Use `--socket /absolute/path.sock` before any daemon command to target an
isolated fixture or alternate daemon. The option does not apply to local
`service` lifecycle commands.

## Permissions

Shortcut actions synthesize keyboard events and therefore require macOS
Accessibility permission. Grant it to the installed daemon at:

```text
~/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-daemon
```

The relevant control is in **System Settings > Privacy & Security >
Accessibility**. `doctor` reports `permission.accessibility: false` until this
is granted. Application launches, URL actions, and Spotify playback do not use
the shortcut event path. Spotify's direct Apple Event may separately appear in
macOS's Automation privacy controls; `doctor` does not currently preflight that
consent.

Opening the MX Master 4 HID++ interface also requires **System Settings >
Privacy & Security > Input Monitoring** for that same installed daemon path.

## Files and recovery

The production service uses these per-user paths:

| Purpose | Path |
| --- | --- |
| Configuration | `~/Library/Application Support/Logi Liquid Controls/config.json` |
| Diversion recovery journal | `~/Library/Application Support/Logi Liquid Controls/sense-panel-diversion.json` |
| Installed daemon | `~/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-daemon` |
| Installed overlay | `~/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-overlay` |
| Daemon logs | `~/Library/Application Support/Logi Liquid Controls/logs/daemon.log` and `daemon.error.log` |
| Overlay logs | `~/Library/Application Support/Logi Liquid Controls/logs/overlay.log` and `overlay.error.log` |
| Control socket | `~/.logi-liquid-controls/run/mouse-control.sock` |
| Daemon LaunchAgent | `~/Library/LaunchAgents/com.logiliquid.controls.daemon.plist` |
| Overlay LaunchAgent | `~/Library/LaunchAgents/com.logiliquid.controls.overlay.plist` |

The Application Support and socket directories are private (`0700`); the
configuration, journal, and socket are user-only (`0600` where applicable).
Symlinks, hard-linked files, and paths owned by another user are rejected.

Before changing Sense Panel reporting, the daemon reads the complete original
state and durably writes it to `sense-panel-diversion.json`. A clean stop
restores and verifies that state before deleting the journal. After a crash,
the next start uses a one-way physical-device fingerprint to find the same
mouse even if macOS assigned a new IORegistry entry ID, restores it, and only
then takes ownership again. A different same-model mouse is refused. Legacy
version-1 journals have no fingerprint and recover only when their original
registry entry ID still matches. Do not manually delete an existing journal
before recovery.

A terminal HID read failure or device disconnect ends only the device session,
not the process: the daemon restores what it can, keeps the control socket up,
and retries bring-up in-process with capped backoff (1 s doubling to 10 s),
logging state transitions instead of every attempt. While the ring is active
it also probes the Sense Panel reporting state every 30 seconds — and
immediately after a detected system sleep — and silently re-applies the
diversion if the mouse dropped it, which otherwise leaves a working cursor
with a dead ring after wake. The LaunchAgent's `KeepAlive` policy remains the
safety net for crashes and non-recoverable errors (wrong physical mouse,
invalid configuration), which still exit.

See [PROTOCOL.md](../PROTOCOL.md) for the device IDs, HID++ feature discovery,
report formats, diversion transaction, and haptic protocol notes.
