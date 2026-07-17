# Gym

All of CommandBloom's out-of-process test harnesses live here. (The visual
wing was originally a separate top-level directory named `jim` — a pun on
"gym" — before both were consolidated.)

## `agent/` — black-box agent harness (TypeScript)

Spawns the real `logi-liquid` CLI against the `logi-liquid-daemon-fixture`
(production control and runtime boundaries with fake HID/action adapters) on a
private Unix socket, and drives the entire agent-facing surface from the
outside: actions configuration, resolution, streams, and simulation.

```sh
cd gym/agent
npm test
```

## `visual/` — native visual snapshots (Swift)

Checked-in pixel baselines for the production overlay, rendered and verified
by the `gym` executable (`Sources/LogiLiquidGym`). It also renders the public
demo video. See [visual/README.md](visual/README.md) for the full contract:

```sh
swift build -c release --product gym
.build/release/gym record --directory gym/visual/Snapshots
.build/release/gym verify --directory gym/visual/Snapshots
.build/release/gym demo --output docs/assets/command-bloom-demo.mp4 \
  --poster docs/assets/command-bloom-demo-poster.png
```
