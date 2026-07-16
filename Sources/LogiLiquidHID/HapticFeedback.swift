import Foundation

public enum HapticFeedback {
  public static let featureID = HIDPPFeatureID.hapticFeedback

  /// Builds feature `0x19B0`, function 4 (`playWaveform`). Building this
  /// packet has no side effects; it is sent only when a caller transacts it.
  public static func playWaveformRequest(
    featureIndex: UInt8,
    waveformID: UInt8,
    deviceIndex: UInt8 = HIDPPPacket.directBluetoothDeviceIndex,
    softwareID: UInt8 = HIDPPPacket.defaultSoftwareID
  ) throws -> HIDPPPacket {
    try HIDPPPacket(
      deviceIndex: deviceIndex,
      featureIndex: featureIndex,
      functionID: 0x04,
      softwareID: softwareID,
      parameters: [waveformID]
    )
  }
}

extension HIDPPDeviceSession {
  /// Plays one firmware waveform. This is an explicit mutating operation and
  /// is never called by enumeration or discovery.
  public func playHapticWaveform(
    _ waveformID: UInt8,
    featureIndex: UInt8,
    timeoutMilliseconds: Int32 = 1_000
  ) throws {
    let request = try HapticFeedback.playWaveformRequest(
      featureIndex: featureIndex,
      waveformID: waveformID
    )
    let response = try transact(
      request,
      timeoutMilliseconds: timeoutMilliseconds
    )
    try response.requireSuccess()
  }
}
