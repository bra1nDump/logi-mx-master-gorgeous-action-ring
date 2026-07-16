import AppKit
import CoreGraphics
import Foundation
import ImageIO

public struct JimSnapshotManifest: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public struct Entry: Codable, Equatable, Sendable {
    public let state: JimSnapshotState
    public let file: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
  }

  public let schemaVersion: Int
  public let configuration: JimRenderConfiguration
  public let snapshots: [Entry]
}

public struct JimSnapshotDifference: Codable, Equatable, Sendable {
  public let state: JimSnapshotState
  public let baseline: String
  public let maximumChannelDelta: Int
  public let differentPixelRatio: Double
  public let passed: Bool
}

@MainActor
public final class JimSnapshotWorkflow {
  public static let manifestFileName = "manifest.json"
  public static let channelTolerance = 3
  public static let maximumDifferentPixelRatio = 0.001

  private let renderer: JimRenderer

  public init(renderer: JimRenderer = JimRenderer()) {
    self.renderer = renderer
  }

  @discardableResult
  public func record(
    directory: URL,
    configuration: JimRenderConfiguration = .default
  ) async throws -> JimSnapshotManifest {
    try configuration.validate()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    var entries: [JimSnapshotManifest.Entry] = []
    for state in JimSnapshotState.allCases {
      let image = try await renderer.render(state: state, configuration: configuration)
      let output = directory.appending(path: state.fileName, directoryHint: .notDirectory)
      try image.pngData.write(to: output, options: .atomic)
      entries.append(
        JimSnapshotManifest.Entry(
          state: state,
          file: state.fileName,
          pixelWidth: image.pixelWidth,
          pixelHeight: image.pixelHeight,
          byteCount: image.pngData.count
        )
      )
    }

    let manifest = JimSnapshotManifest(
      schemaVersion: JimSnapshotManifest.currentSchemaVersion,
      configuration: configuration,
      snapshots: entries
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var manifestData = try encoder.encode(manifest)
    manifestData.append(0x0A)
    try manifestData.write(
      to: directory.appending(path: Self.manifestFileName, directoryHint: .notDirectory),
      options: .atomic
    )
    return manifest
  }

  public func verify(directory: URL) async throws -> [JimSnapshotDifference] {
    let manifestURL = directory.appending(
      path: Self.manifestFileName,
      directoryHint: .notDirectory
    )
    let manifest = try JSONDecoder().decode(
      JimSnapshotManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    guard manifest.schemaVersion == JimSnapshotManifest.currentSchemaVersion else {
      throw JimError.unsupportedManifestVersion(manifest.schemaVersion)
    }
    try manifest.configuration.validate()

    var differences: [JimSnapshotDifference] = []
    for entry in manifest.snapshots {
      let baselineURL = directory.appending(path: entry.file, directoryHint: .notDirectory)
      let baselineData = try Data(contentsOf: baselineURL)
      let current = try await renderer.render(
        state: entry.state,
        configuration: manifest.configuration
      )
      let metrics = try Self.compare(
        baseline: baselineData,
        current: current.pngData,
        expectedWidth: entry.pixelWidth,
        expectedHeight: entry.pixelHeight
      )
      differences.append(
        JimSnapshotDifference(
          state: entry.state,
          baseline: baselineURL.path,
          maximumChannelDelta: metrics.maximumChannelDelta,
          differentPixelRatio: metrics.differentPixelRatio,
          passed: metrics.maximumChannelDelta <= Self.channelTolerance
            || metrics.differentPixelRatio <= Self.maximumDifferentPixelRatio
        )
      )
    }
    return differences
  }

  private static func compare(
    baseline: Data,
    current: Data,
    expectedWidth: Int,
    expectedHeight: Int
  ) throws -> (maximumChannelDelta: Int, differentPixelRatio: Double) {
    let baselinePixels = try rgbaPixels(
      pngData: baseline,
      expectedWidth: expectedWidth,
      expectedHeight: expectedHeight
    )
    let currentPixels = try rgbaPixels(
      pngData: current,
      expectedWidth: expectedWidth,
      expectedHeight: expectedHeight
    )
    guard baselinePixels.count == currentPixels.count else {
      throw JimError.pixelBufferMismatch
    }

    var maximumChannelDelta = 0
    var differentPixels = 0
    let pixelCount = expectedWidth * expectedHeight
    for pixel in 0..<pixelCount {
      var pixelDiffers = false
      for channel in 0..<4 {
        let index = pixel * 4 + channel
        let delta = abs(Int(baselinePixels[index]) - Int(currentPixels[index]))
        maximumChannelDelta = max(maximumChannelDelta, delta)
        if delta > channelTolerance {
          pixelDiffers = true
        }
      }
      if pixelDiffers {
        differentPixels += 1
      }
    }

    return (
      maximumChannelDelta,
      Double(differentPixels) / Double(pixelCount)
    )
  }

  private static func rgbaPixels(
    pngData: Data,
    expectedWidth: Int,
    expectedHeight: Int
  ) throws -> [UInt8] {
    guard
      let source = CGImageSourceCreateWithData(pngData as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == expectedWidth,
      image.height == expectedHeight
    else {
      throw JimError.invalidPNGDimensions(
        expectedWidth: expectedWidth,
        expectedHeight: expectedHeight
      )
    }

    var bytes = [UInt8](repeating: 0, count: expectedWidth * expectedHeight * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer in
      guard
        let baseAddress = buffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: expectedWidth,
          height: expectedHeight,
          bitsPerComponent: 8,
          bytesPerRow: expectedWidth * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: expectedWidth, height: expectedHeight)
      )
      return true
    }
    guard rendered else { throw JimError.bitmapAllocationFailed }
    return bytes
  }
}

public enum JimError: LocalizedError, Equatable {
  case invalidDimension(name: String, value: Int)
  case invalidScale(Int)
  case bitmapAllocationFailed
  case pngEncodingFailed
  case hostedWindowUnavailable(Int)
  case hostedWindowFrameMismatch(
    expectedWidth: Int,
    expectedHeight: Int,
    actualWidth: Double,
    actualHeight: Double
  )
  case invalidPNGDimensions(expectedWidth: Int, expectedHeight: Int)
  case pixelBufferMismatch
  case unsupportedManifestVersion(Int)
  case invalidFrameRate(Int)
  case invalidDuration(Double)
  case invalidDemoScenario
  case videoWriterCreationFailed(String)
  case videoEncodingFailed(String)
  case invalidVideo
  case demoBackgroundMissing
  case pixelBufferCreationFailed
  case usage(String)

  public var errorDescription: String? {
    switch self {
    case .invalidDimension(let name, let value):
      "Invalid \(name) \(value); expected 320...4096."
    case .invalidScale(let scale):
      "Invalid scale \(scale); expected 1...4."
    case .bitmapAllocationFailed:
      "Could not allocate the snapshot bitmap."
    case .pngEncodingFailed:
      "Could not encode the rendered snapshot as PNG."
    case .hostedWindowUnavailable(let windowNumber):
      "Hosted AppKit window \(windowNumber) was unavailable to ScreenCaptureKit."
    case .hostedWindowFrameMismatch(
      let expectedWidth,
      let expectedHeight,
      let actualWidth,
      let actualHeight
    ):
      "Hosted AppKit window was \(actualWidth)x\(actualHeight); expected \(expectedWidth)x\(expectedHeight)."
    case .invalidPNGDimensions(let expectedWidth, let expectedHeight):
      "Snapshot is not a valid \(expectedWidth)x\(expectedHeight) PNG."
    case .pixelBufferMismatch:
      "Snapshot pixel buffers do not have matching sizes."
    case .unsupportedManifestVersion(let version):
      "Unsupported Jim manifest schema version \(version)."
    case .invalidFrameRate(let framesPerSecond):
      "Invalid frame rate \(framesPerSecond); expected 12...60."
    case .invalidDuration(let duration):
      "Invalid demo duration \(duration); expected 2...8 seconds."
    case .invalidDemoScenario:
      "The CommandBloom demo scenario could not resolve its top target or latch frame."
    case .videoWriterCreationFailed(let reason):
      "Could not create the demo video writer: \(reason)."
    case .videoEncodingFailed(let reason):
      "Could not encode the demo video: \(reason)."
    case .invalidVideo:
      "The generated demo video failed structural validation."
    case .demoBackgroundMissing:
      "The demo wallpaper does not cover every frame corner."
    case .pixelBufferCreationFailed:
      "Could not allocate a video pixel buffer."
    case .usage(let message):
      message
    }
  }
}
