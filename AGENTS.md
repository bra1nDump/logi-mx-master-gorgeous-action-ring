# Agent Notes

- This is a standalone macOS Swift package. Do not add Rigged, Happy, or
  `happy2` references.
- The public product and repository name is CommandBloom. Keep the existing
  `logi-liquid` executable names, support paths, and signing identifiers stable;
  changing them invalidates installed services and macOS permission grants.
- Before handoff, run `swift format lint --strict --recursive Package.swift Sources Tests`,
  `swift test`, and the relevant release builds.
- The daemon owns HID++, overlap latching, actions, haptics, and balanced cursor
  hide/restore. The overlay only renders daemon events. Never add a haptic on
  menu invocation; fire it once when an action latches.
- Release builds are ad-hoc signed by default. Never install that daemon: it
  invalidates the existing Input Monitoring grant. Sign with the stable identity:

  ```sh
  codesign --force --sign "Developer ID Application: Bulka, LLC (466DQWDR8C)" \
    --identifier com.logiliquid.controls.daemon --options runtime --timestamp \
    .build/release/logi-liquid-daemon
  .build/release/logi-liquid service install
  ```

- `service install` manages two LaunchAgents: the daemon and the overlay. Both
  log to `~/Library/Application Support/Logi Liquid Controls/logs/`. "Cursor
  hides but no ring" means the overlay agent is down — check
  `service status` (`overlayLoaded`) and `overlay.error.log`.

- Verify the installed signature, service, permissions, and device with
  `codesign -dv --verbose=4 ~/Library/Application\ Support/Logi\ Liquid\ Controls/bin/logi-liquid-daemon`,
  `logi-liquid service status`, and `logi-liquid doctor`.
- Re-record and verify Gym after visual or interaction-state changes:
  `gym record --directory gym/visual/Snapshots` then `gym verify --directory gym/visual/Snapshots`.
  Regenerate the public demo with
  `gym demo --output docs/assets/command-bloom-demo.mp4 --poster docs/assets/command-bloom-demo-poster.png`.
- SwiftPM resources such as the bundled OpenAI mark must ship beside the overlay;
  never read another installed app's private assets at runtime.
