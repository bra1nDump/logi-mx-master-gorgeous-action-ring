import Foundation

/// Reads and atomically replaces one JSON configuration at a caller-supplied URL.
public struct ConfigurationStore: Sendable {
  public let url: URL

  public init(url: URL) throws {
    guard url.isFileURL else {
      throw ConfigurationError.nonFileURL(url)
    }
    self.url = url
  }

  public func load() throws -> MouseConfiguration {
    let data = try Data(contentsOf: url)
    let configuration = try JSONDecoder().decode(MouseConfiguration.self, from: data)
    try configuration.validate()
    return configuration
  }

  /// Validates and replaces the file atomically, so readers observe either the
  /// previous complete document or the new complete document, never a partial write.
  public func save(_ configuration: MouseConfiguration) throws {
    try configuration.validate()

    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(configuration)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
  }
}
