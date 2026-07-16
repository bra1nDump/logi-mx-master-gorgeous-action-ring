# MX Master 4 protocol notes

The mouse remains paired to macOS through the normal Bluetooth settings. The
service does not open a CoreBluetooth GATT connection or replace Apple's mouse
driver. It opens the already-paired `IOHIDDevice` non-exclusively and exchanges
Logitech HID++ reports over the device's vendor interface.

## Device boundary

- USB vendor ID: `0x046D` (Logitech)
- MX Master 4 Bluetooth product ID: `0xB042`
- Transport: Bluetooth Low Energy
- Vendor usage page: `0xFF43`
- HID++ long report: report ID `0x11`, 20 bytes
- Direct-Bluetooth device index: `0xFF`

Serial numbers and Bluetooth addresses are intentionally not exposed by the
control protocol or logs.

## HID++ framing

A long request is encoded as:

```text
11 FF FEATURE_INDEX FUNCTION_AND_SOFTWARE_ID PARAMETER_0 ... PARAMETER_15
```

Feature indexes are runtime values and must be discovered through IRoot rather
than hard-coded. On the locally connected mouse, read-only discovery reports
HID++ 4.5 and exposes the features needed here:

- `0x1B04`: Reprogrammable Controls V4
- `0x19B0`: Haptic Feedback
- `0x19C0`: Force Sensing Button

## Sense Panel input

The MX Master 4 Sense Panel is control ID `0x01A0`. Reprogrammable Controls V4
reports that it is divertable and supports raw XY movement.

The service uses these feature functions:

- function 0: read control count
- function 1: read control metadata
- function 2: read current reporting state
- function 3: change reporting state

Unsolicited function-0 notifications carry the currently pressed diverted
control IDs. Unsolicited function-1 notifications carry signed, big-endian
`dx` and `dy` values. Live inspection reports Sense Panel capabilities `0x0531`:
the physical control is divertable and supports raw XY, but does not advertise
forced raw XY. The force-capable virtual gesture control is a distinct control
ID and is not modified by the current diversion lifecycle.

Only volatile diversion and raw-XY reporting are enabled. The service
first captures every reportable field, journals that snapshot, applies the
temporary change, and verifies it by readback. Normal shutdown and crash
recovery restore the complete original state, including any pre-existing
Logitech mapping.

Primary-button clicks are detected separately by polling the system button
state for down edges. This does not require a global event tap or Input
Monitoring permission, and a held button produces only one click transition.

## Haptics

Haptic Feedback feature `0x19B0`, function 4, plays a firmware waveform. The
physical Sense Panel click supplies the invocation feedback; CommandBloom plays
waveform 0 only when an action latches. Discovery and inspection never play a
waveform, and the CLI can request one explicitly for diagnostics.

## Ownership

Logi Options+ and this service must not both manage Sense Panel reporting. The
Options+ device-manager LaunchAgent is stopped before live diversion tests. The
separate LogiRightSight webcam service is unrelated and is left alone.
