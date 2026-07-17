# Gym

Gym is CommandBloom's deterministic native snapshot harness. It renders
the production `OverlayView` through SwiftUI inside a real, deterministically
positioned AppKit window, then captures that specific window with
ScreenCaptureKit. The window-backed path is deliberate: native Liquid Glass
needs a resolved `NSView`/window environment and cannot be covered faithfully
by model assertions alone.

Gym uses the real `RingInteractionMachine` to produce four representative
states:

| State | Core state represented |
| --- | --- |
| `invoked` | Open ring, no selected target |
| `targeting` | Top target selected, 0.25 merge progress |
| `latched-suction-threshold` | Exact configured moving-bubble overlap, then Core's `latched` suction frame |
| `committed` | Terminal committed frame with cursor restore and no repeated action |

The production reducer normally hides a committed frame. Gym intentionally
renders it so terminal model changes remain snapshot-testable. The latch
scenario solves Core's exact circle-intersection threshold and renders the
post-threshold suction frame where the action/haptic fire; `committed` is the
subsequent cursor-restoring terminal transition.

## Build and inspect states

```sh
swift build -c release --product gym
.build/release/gym list
```

Every successful command except `help` prints one stable JSON object to stdout;
diagnostics go to stderr and failures return nonzero. Render one state with
explicit logical dimensions and pixel scale:

```sh
.build/release/gym render \
  --state latched-suction-threshold \
  --output /tmp/gym-latched.png \
  --width 720 \
  --height 520 \
  --scale 2
```

That produces a 1440x1040 PNG. Gym waits for the production presentation spring
to settle, fixes a dark appearance, and supplies an in-window wallpaper so
translucent glass has deterministic content to refract rather than depending on
the user's desktop.

## Record and verify snapshots

Record all four baselines. The default destination is `gym/visual/Snapshots`:

```sh
.build/release/gym record
# Equivalent explicit form:
.build/release/gym record --directory gym/visual/Snapshots --width 720 --height 520 --scale 2
```

The directory contains four PNGs and a deterministic `manifest.json` recording
their state, dimensions, and byte counts. Verify by re-rendering every state and
performing a canonical RGBA comparison:

```sh
.build/release/gym verify --directory gym/visual/Snapshots
```

Verification allows a three-level per-channel tolerance and at most 0.1% of
pixels outside that tolerance, accommodating tiny compositor rounding without
masking structural changes. The JSON result contains per-state maximum channel
delta, changed-pixel ratio, baseline path, and pass/fail status. A snapshot
mismatch exits with status 2; usage errors exit with status 64.

## Render the demo video

Gym also renders the public demo: an H.264 MP4 of the production `OverlayView`
composited over a deterministic macOS-style wallpaper, plus an optional poster
still for the README:

```sh
.build/release/gym demo \
  --output docs/assets/command-bloom-demo.mp4 \
  --poster docs/assets/command-bloom-demo-poster.png
```

The default is 1280×800 at 60 frames per second and 2.8 seconds. The timeline
opens on the wallpaper with the standard macOS pointer, shakes it with haptic
ripples for the Sense Panel press, blooms the ring, travels to Core's exact
latch-overlap boundary, performs the 160 ms suction, pulses the committed
target, and dismisses back to the desktop so the video loops cleanly. The
poster is the mid-suction frame. Every frame is captured from Gym's dedicated
AppKit window; desktop content is never included. Grant Screen Recording
access to the `gym` executable when macOS requests it.

## Tests

```sh
swift test --filter LogiLiquidGymTests
```

The focused tests prove that scenarios use real Core transitions, hosted PNGs
have exact output dimensions and nonempty pixel variation, the fixed backdrop
reaches all four edges without cropped/black margins, record/verify works end to
end, the demo video is valid H.264 with the wallpaper covering every corner,
and the agent-facing `list` response remains stable JSON.
