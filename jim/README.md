# Jim

Jim is CommandBloom's deterministic native snapshot harness. It renders
the production `OverlayView` through SwiftUI inside a real, deterministically
positioned AppKit window, then captures that specific window with
ScreenCaptureKit. The window-backed path is deliberate: native Liquid Glass
needs a resolved `NSView`/window environment and cannot be covered faithfully
by model assertions alone.

Jim uses the real `RingInteractionMachine` to produce four representative
states:

| State | Core state represented |
| --- | --- |
| `invoked` | Open ring, no selected target |
| `targeting` | Top target selected, 0.25 merge progress |
| `latched-suction-threshold` | Exact configured moving-bubble overlap, then Core's `latched` suction frame |
| `committed` | Terminal committed frame with cursor restore and no repeated action |

The production reducer normally hides a committed frame. Jim intentionally
renders it so terminal model changes remain snapshot-testable. The latch
scenario solves Core's exact circle-intersection threshold and renders the
post-threshold suction frame where the action/haptic fire; `committed` is the
subsequent cursor-restoring terminal transition.

## Build and inspect states

```sh
swift build -c release --product jim
.build/release/jim list
```

Every successful command except `help` prints one stable JSON object to stdout;
diagnostics go to stderr and failures return nonzero. Render one state with
explicit logical dimensions and pixel scale:

```sh
.build/release/jim render \
  --state latched-suction-threshold \
  --output /tmp/jim-latched.png \
  --width 720 \
  --height 520 \
  --scale 2
```

That produces a 1440x1040 PNG. Jim waits for the production presentation spring
to settle, fixes a dark appearance, and supplies an in-window wallpaper so
translucent glass has deterministic content to refract rather than depending on
the user's desktop.

## Record and verify snapshots

Record all four baselines. The default destination is `jim/Snapshots`:

```sh
.build/release/jim record
# Equivalent explicit form:
.build/release/jim record --directory jim/Snapshots --width 720 --height 520 --scale 2
```

The directory contains four PNGs and a deterministic `manifest.json` recording
their state, dimensions, and byte counts. Verify by re-rendering every state and
performing a canonical RGBA comparison:

```sh
.build/release/jim verify --directory jim/Snapshots
```

Verification allows a three-level per-channel tolerance and at most 0.1% of
pixels outside that tolerance, accommodating tiny compositor rounding without
masking structural changes. The JSON result contains per-state maximum channel
delta, changed-pixel ratio, baseline path, and pass/fail status. A snapshot
mismatch exits with status 2; usage errors exit with status 64.

## Render the transparent demo

Jim can also render the production `OverlayView` into the public looping GIF:

```sh
.build/release/jim demo --output docs/assets/command-bloom-demo.gif
```

The default is 1200×800, 60 frames per second, and 3.2 seconds. Every frame is
captured from Jim's dedicated transparent AppKit window; desktop content is
never included. Grant Screen Recording access to the `jim` executable when
macOS requests it.

## Tests

```sh
swift test --filter LogiLiquidJimTests
```

The focused tests prove that scenarios use real Core transitions, hosted PNGs
have exact output dimensions and nonempty pixel variation, the fixed backdrop
reaches all four edges without cropped/black margins, record/verify works end to
end, and the agent-facing `list` response remains stable JSON.
