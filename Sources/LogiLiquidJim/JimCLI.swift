import Foundation

public struct JimCLIOutput: Codable, Equatable, Sendable {
  public let command: String
  public let ok: Bool
  public let files: [String]
  public let differences: [JimSnapshotDifference]

  public init(
    command: String,
    ok: Bool,
    files: [String] = [],
    differences: [JimSnapshotDifference] = []
  ) {
    self.command = command
    self.ok = ok
    self.files = files
    self.differences = differences
  }
}

@MainActor
public struct JimCLI {
  public static let usage = """
    usage:
      jim list
      jim render --state STATE --output FILE [--width N --height N --scale N]
      jim record [--directory DIR] [--width N --height N --scale N]
      jim verify [--directory DIR]
      jim demo --output FILE [--width N --height N --fps N]

    states: \(JimSnapshotState.allCases.map(\.rawValue).joined(separator: ", "))
    default snapshot directory: jim/Snapshots
    """

  private let renderer: JimRenderer
  private let workflow: JimSnapshotWorkflow
  private let currentDirectory: URL

  public init(
    renderer: JimRenderer = JimRenderer(),
    currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath)
  ) {
    self.renderer = renderer
    self.workflow = JimSnapshotWorkflow(renderer: renderer)
    self.currentDirectory = currentDirectory
  }

  public func run(
    arguments: [String],
    standardOutput: (Data) -> Void = { FileHandle.standardOutput.write($0) },
    standardError: (Data) -> Void = { FileHandle.standardError.write($0) }
  ) async -> Int32 {
    do {
      guard let command = arguments.first else {
        throw JimError.usage(Self.usage)
      }
      switch command {
      case "help", "--help", "-h":
        standardOutput(Data("\(Self.usage)\n".utf8))
        return 0

      case "list":
        guard arguments.count == 1 else {
          throw JimError.usage("list accepts no options")
        }
        return try emit(
          JimCLIOutput(
            command: "list",
            ok: true,
            files: JimSnapshotState.allCases.map(\.rawValue)
          ),
          to: standardOutput
        )

      case "render":
        let options = try ParsedOptions(Array(arguments.dropFirst()))
        guard let rawState = options.value(for: "--state"),
          let state = JimSnapshotState(rawValue: rawState)
        else {
          throw JimError.usage("render requires --state with a known state")
        }
        guard let rawOutput = options.value(for: "--output") else {
          throw JimError.usage("render requires --output FILE")
        }
        try options.rejectUnknown(allowing: [
          "--state", "--output", "--width", "--height", "--scale",
        ])
        let configuration = try options.configuration()
        let output = absoluteURL(rawOutput)
        try FileManager.default.createDirectory(
          at: output.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let image = try await renderer.render(state: state, configuration: configuration)
        try image.pngData.write(to: output, options: .atomic)
        return try emit(
          JimCLIOutput(command: "render", ok: true, files: [output.path]),
          to: standardOutput
        )

      case "record":
        let options = try ParsedOptions(Array(arguments.dropFirst()))
        try options.rejectUnknown(allowing: ["--directory", "--width", "--height", "--scale"])
        let directory = absoluteURL(options.value(for: "--directory") ?? "jim/Snapshots")
        let manifest = try await workflow.record(
          directory: directory,
          configuration: try options.configuration()
        )
        let files =
          manifest.snapshots.map {
            directory.appending(path: $0.file).path
          } + [directory.appending(path: JimSnapshotWorkflow.manifestFileName).path]
        return try emit(
          JimCLIOutput(command: "record", ok: true, files: files),
          to: standardOutput
        )

      case "verify":
        let options = try ParsedOptions(Array(arguments.dropFirst()))
        try options.rejectUnknown(allowing: ["--directory"])
        let directory = absoluteURL(options.value(for: "--directory") ?? "jim/Snapshots")
        let differences = try await workflow.verify(directory: directory)
        let passed = differences.allSatisfy(\.passed)
        _ = try emit(
          JimCLIOutput(command: "verify", ok: passed, differences: differences),
          to: standardOutput
        )
        return passed ? 0 : 2

      case "demo":
        let options = try ParsedOptions(Array(arguments.dropFirst()))
        guard let rawOutput = options.value(for: "--output") else {
          throw JimError.usage("demo requires --output FILE")
        }
        try options.rejectUnknown(allowing: ["--output", "--width", "--height", "--fps"])
        let output = absoluteURL(rawOutput)
        _ = try await JimDemoRenderer().render(
          to: output,
          configuration: try options.demoConfiguration()
        )
        return try emit(
          JimCLIOutput(command: "demo", ok: true, files: [output.path]),
          to: standardOutput
        )

      default:
        throw JimError.usage("unknown command \(command.debugDescription)\n\(Self.usage)")
      }
    } catch {
      standardError(Data("jim: \(error.localizedDescription)\n".utf8))
      return error is JimError ? 64 : 1
    }
  }

  private func emit(_ output: JimCLIOutput, to sink: (Data) -> Void) throws -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(output)
    data.append(0x0A)
    sink(data)
    return output.ok ? 0 : 2
  }

  private func absoluteURL(_ path: String) -> URL {
    if path.hasPrefix("/") {
      return URL(filePath: path, directoryHint: .notDirectory)
    }
    return currentDirectory.appending(path: path, directoryHint: .notDirectory)
  }
}

private struct ParsedOptions {
  private let values: [String: String]

  init(_ arguments: [String]) throws {
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let option = arguments[index]
      guard option.hasPrefix("--") else {
        throw JimError.usage("unexpected argument \(option.debugDescription)")
      }
      guard index + 1 < arguments.count else {
        throw JimError.usage("\(option) requires a value")
      }
      guard values[option] == nil else {
        throw JimError.usage("duplicate option \(option)")
      }
      values[option] = arguments[index + 1]
      index += 2
    }
    self.values = values
  }

  func value(for option: String) -> String? {
    values[option]
  }

  func rejectUnknown(allowing allowed: Set<String>) throws {
    if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw JimError.usage("unknown option \(unknown)")
    }
  }

  func configuration() throws -> JimRenderConfiguration {
    JimRenderConfiguration(
      logicalWidth: try integer(for: "--width") ?? JimRenderConfiguration.default.logicalWidth,
      logicalHeight: try integer(for: "--height") ?? JimRenderConfiguration.default.logicalHeight,
      scale: try integer(for: "--scale") ?? JimRenderConfiguration.default.scale
    )
  }

  func demoConfiguration() throws -> JimDemoConfiguration {
    JimDemoConfiguration(
      pixelWidth: try integer(for: "--width") ?? JimDemoConfiguration.default.pixelWidth,
      pixelHeight: try integer(for: "--height") ?? JimDemoConfiguration.default.pixelHeight,
      framesPerSecond: try integer(for: "--fps")
        ?? JimDemoConfiguration.default.framesPerSecond
    )
  }

  private func integer(for option: String) throws -> Int? {
    guard let raw = values[option] else { return nil }
    guard let value = Int(raw) else {
      throw JimError.usage("\(option) requires an integer")
    }
    return value
  }
}
