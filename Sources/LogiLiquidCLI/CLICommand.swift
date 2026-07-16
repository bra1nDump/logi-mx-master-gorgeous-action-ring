import Foundation
import LogiLiquidControl
import LogiLiquidCore

public struct CLIInvocation: Equatable {
  public let socketURL: URL
  public let command: CLICommand

  public init(socketURL: URL, command: CLICommand) {
    self.socketURL = socketURL
    self.command = command
  }
}

public enum CLICommand: Equatable {
  case help
  case service(ServiceCommand)
  case request(method: ControlMethod, params: JSONValue)
  case follow(method: ControlMethod, params: JSONValue)
}

private struct ActionPlacement: Equatable {
  let zone: CardinalZone
  let applicationBundleID: String?
}

/// A deliberately dependency-free parser for the noninteractive mouse CLI.
///
/// Global options must precede the command. This keeps `--` available as an
/// unambiguous boundary before arguments passed directly to configured
/// executables.
public struct CLIArgumentParser {
  public typealias ScenarioLoader = (_ path: String) throws -> Data

  public static let usage = """
    usage: logi-liquid [--socket PATH] <command>

      status
      doctor
      service install|start|stop|restart|status|uninstall
      device inspect
      events follow
      reports follow
      actions list
      actions resolve [--app BUNDLE_ID]
      actions put-shortcut NAME KEY [--modifiers LIST] [--press-count COUNT] [PLACEMENT]
      actions put-application NAME BUNDLE_ID [PLACEMENT]
      actions put-url NAME URL [PLACEMENT]
      actions put-spotify-play NAME [PLACEMENT]
      actions put-command NAME ABSOLUTE_EXECUTABLE [PLACEMENT] [-- ARG ...]
      actions remove NAME [--zone bottom --when-app BUNDLE_ID]
      actions clear --zone bottom --when-app BUNDLE_ID
      actions move NAME ZERO_BASED_INDEX [PLACEMENT]
      haptic play [WAVEFORM_ID]
      simulate invoke X Y [--app BUNDLE_ID]
      simulate move DX DY
      simulate release
      simulate click
      simulate complete
      simulate dismiss
      simulate cancel
      simulate play FILE|-

    LIST is a comma-separated subset of command,control,option,shift,function.
    PLACEMENT is `--zone top|right|bottom|left [--when-app BUNDLE_ID]`.
    Application-specific actions must use the bottom zone.
    `simulate play` accepts either a JSON array or NDJSON RingInput records.
    """

  private let defaultSocketURL: URL
  private let loadScenario: ScenarioLoader

  public init(
    defaultSocketURL: URL = LogiLiquidControlProtocol.defaultSocketURL,
    loadScenario: @escaping ScenarioLoader = CLIArgumentParser.readScenario
  ) {
    self.defaultSocketURL = defaultSocketURL
    self.loadScenario = loadScenario
  }

  public func parse(arguments: [String]) throws -> CLIInvocation {
    var arguments = arguments
    var socketURL = defaultSocketURL
    var socketOverridden = false

    if arguments.first == "--socket" {
      guard arguments.count >= 2 else {
        throw CLIUsageError("--socket requires a path")
      }
      socketURL = try parseSocketPath(arguments[1])
      socketOverridden = true
      arguments.removeFirst(2)
    } else if let first = arguments.first, first.hasPrefix("--socket=") {
      socketURL = try parseSocketPath(String(first.dropFirst("--socket=".count)))
      socketOverridden = true
      arguments.removeFirst()
    }

    guard let command = arguments.first else {
      throw CLIUsageError("a command is required")
    }

    if command == "help" || command == "--help" || command == "-h" {
      guard arguments.count == 1 else {
        throw CLIUsageError("help takes no arguments")
      }
      return CLIInvocation(socketURL: socketURL, command: .help)
    }

    if command.hasPrefix("--") {
      throw CLIUsageError("unknown global option \(command.debugDescription)")
    }

    let tail = Array(arguments.dropFirst())
    let parsed: CLICommand
    switch command {
    case "status":
      try requireNoArguments(tail, command: "status")
      parsed = request(.status)
    case "doctor":
      try requireNoArguments(tail, command: "doctor")
      parsed = request(.doctor)
    case "service":
      guard !socketOverridden else {
        throw CLIUsageError("--socket does not apply to local service commands")
      }
      parsed = try parseService(tail)
    case "device":
      guard tail == ["inspect"] else {
        throw CLIUsageError("expected `device inspect`")
      }
      parsed = request(.deviceInspect)
    case "events":
      guard tail == ["follow"] else {
        throw CLIUsageError("expected `events follow`")
      }
      parsed = follow(.eventsFollow)
    case "reports":
      guard tail == ["follow"] else {
        throw CLIUsageError("expected `reports follow`")
      }
      parsed = follow(.reportsFollow)
    case "actions":
      parsed = try parseActions(tail)
    case "haptic":
      parsed = try parseHaptic(tail)
    case "simulate":
      parsed = try parseSimulation(tail)
    default:
      throw CLIUsageError("unknown command \(command.debugDescription)")
    }

    return CLIInvocation(socketURL: socketURL, command: parsed)
  }

  private func parseService(_ arguments: [String]) throws -> CLICommand {
    guard arguments.count == 1,
      let command = arguments.first.flatMap(ServiceCommand.init(rawValue:))
    else {
      throw CLIUsageError(
        "expected `service install|start|stop|restart|status|uninstall`"
      )
    }
    return .service(command)
  }

  private func parseActions(_ arguments: [String]) throws -> CLICommand {
    guard let actionCommand = arguments.first else {
      throw CLIUsageError("an actions subcommand is required")
    }
    let tail = Array(arguments.dropFirst())

    switch actionCommand {
    case "list":
      try requireNoArguments(tail, command: "actions list")
      return request(.actionsList)
    case "resolve":
      let options = try parseValueOptions(
        tail,
        allowed: ["--app"],
        command: "actions resolve [--app BUNDLE_ID]"
      )
      guard let bundleID = options["--app"] else {
        return request(.actionsResolve)
      }
      try validateBundleID(bundleID, option: "--app")
      return request(.actionsResolve, params: ["bundleID": .string(bundleID)])
    case "put-shortcut":
      guard tail.count >= 2 else {
        throw CLIUsageError(
          "expected `actions put-shortcut NAME KEY [--modifiers LIST] [--press-count COUNT] [PLACEMENT]`"
        )
      }
      let name = try parseActionName(tail[0])
      let key = tail[1]
      guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !key.contains("\0")
      else {
        throw CLIUsageError("shortcut key must not be empty")
      }

      let options = try parseValueOptions(
        Array(tail.dropFirst(2)),
        allowed: ["--modifiers", "--press-count", "--zone", "--when-app"],
        command:
          "actions put-shortcut NAME KEY [--modifiers LIST] [--press-count COUNT] [PLACEMENT]"
      )
      let modifiers = try options["--modifiers"].map(parseModifiers) ?? []
      let repeatCount: Int
      if let value = options["--press-count"] {
        guard let parsed = Int(value), parsed > 0 else {
          throw CLIUsageError("shortcut press count must be a positive integer")
        }
        repeatCount = parsed
      } else {
        repeatCount = 1
      }

      return try putAction(
        name: name,
        action: .shortcut(
          ShortcutAction(
            key: key,
            modifiers: modifiers,
            repeatCount: repeatCount
          )
        ),
        placement: try parsePlacement(options)
      )
    case "put-application":
      guard tail.count >= 2 else {
        throw CLIUsageError(
          "expected `actions put-application NAME BUNDLE_ID [PLACEMENT]`"
        )
      }
      let name = try parseActionName(tail[0])
      let bundleID = tail[1]
      try validateBundleID(bundleID, option: "application bundle ID")
      let options = try parseValueOptions(
        Array(tail.dropFirst(2)),
        allowed: ["--zone", "--when-app"],
        command: "actions put-application NAME BUNDLE_ID [PLACEMENT]"
      )
      return try putAction(
        name: name,
        action: .application(ApplicationAction(bundleID: bundleID)),
        placement: try parsePlacement(options)
      )
    case "put-url":
      guard tail.count >= 2 else {
        throw CLIUsageError("expected `actions put-url NAME URL [PLACEMENT]`")
      }
      let name = try parseActionName(tail[0])
      guard let url = URL(string: tail[1]),
        url.scheme != nil,
        url.baseURL == nil,
        !url.absoluteString.contains("\0")
      else {
        throw CLIUsageError("URL action requires an absolute URL with a scheme")
      }
      let options = try parseValueOptions(
        Array(tail.dropFirst(2)),
        allowed: ["--zone", "--when-app"],
        command: "actions put-url NAME URL [PLACEMENT]"
      )
      return try putAction(
        name: name,
        action: .url(URLAction(url: url)),
        placement: try parsePlacement(options)
      )
    case "put-spotify-play":
      guard !tail.isEmpty else {
        throw CLIUsageError("expected `actions put-spotify-play NAME [PLACEMENT]`")
      }
      let name = try parseActionName(tail[0])
      let options = try parseValueOptions(
        Array(tail.dropFirst()),
        allowed: ["--zone", "--when-app"],
        command: "actions put-spotify-play NAME [PLACEMENT]"
      )
      return try putAction(
        name: name,
        action: .spotify(SpotifyAction(playback: .play)),
        placement: try parsePlacement(options)
      )
    case "put-command":
      guard tail.count >= 2 else {
        throw CLIUsageError(
          "expected `actions put-command NAME ABSOLUTE_EXECUTABLE [PLACEMENT] [-- ARG ...]`"
        )
      }
      let name = try parseActionName(tail[0])
      let executable = tail[1]
      guard executable.hasPrefix("/"), !executable.contains("\0") else {
        throw CLIUsageError("command executable must be an absolute path")
      }

      let remaining = Array(tail.dropFirst(2))
      let optionArguments: [String]
      let argv: [String]
      if let separator = remaining.firstIndex(of: "--") {
        optionArguments = Array(remaining[..<separator])
        argv = Array(remaining[remaining.index(after: separator)...])
      } else {
        optionArguments = remaining
        argv = []
      }
      guard argv.allSatisfy({ !$0.contains("\0") }) else {
        throw CLIUsageError("command arguments must not contain null bytes")
      }
      let options = try parseValueOptions(
        optionArguments,
        allowed: ["--zone", "--when-app"],
        command: "actions put-command NAME ABSOLUTE_EXECUTABLE [PLACEMENT] [-- ARG ...]"
      )

      return try putAction(
        name: name,
        action: .executable(
          ExecutableAction(executable: executable, argv: argv)
        ),
        placement: try parsePlacement(options)
      )
    case "remove":
      guard !tail.isEmpty else {
        throw CLIUsageError(
          "expected `actions remove NAME [--zone bottom --when-app BUNDLE_ID]`"
        )
      }
      let name = try parseActionName(tail[0])
      let options = try parseValueOptions(
        Array(tail.dropFirst()),
        allowed: ["--zone", "--when-app"],
        command: "actions remove NAME [--zone bottom --when-app BUNDLE_ID]"
      )
      guard !options.isEmpty else {
        return request(
          .actionsRemove,
          params: ["name": .string(name)]
        )
      }
      let applicationBundleID = try parseApplicationBottomScope(
        options,
        command: "actions remove"
      )
      return request(
        .actionsRemove,
        params: [
          "name": .string(name),
          "zone": .string(CardinalZone.bottom.rawValue),
          "applicationBundleID": .string(applicationBundleID),
        ]
      )
    case "clear":
      let options = try parseValueOptions(
        tail,
        allowed: ["--zone", "--when-app"],
        command: "actions clear --zone bottom --when-app BUNDLE_ID"
      )
      let applicationBundleID = try parseApplicationBottomScope(
        options,
        command: "actions clear"
      )
      return request(
        .actionsClear,
        params: [
          "zone": .string(CardinalZone.bottom.rawValue),
          "applicationBundleID": .string(applicationBundleID),
        ]
      )
    case "move":
      guard tail.count >= 2 else {
        throw CLIUsageError("expected `actions move NAME ZERO_BASED_INDEX [PLACEMENT]`")
      }
      let name = try parseActionName(tail[0])
      guard let index = Int64(tail[1]), index >= 0 else {
        throw CLIUsageError("action index must be a nonnegative integer")
      }
      let options = try parseValueOptions(
        Array(tail.dropFirst(2)),
        allowed: ["--zone", "--when-app"],
        command: "actions move NAME ZERO_BASED_INDEX [PLACEMENT]"
      )
      var params: [String: JSONValue] = [
        "name": .string(name), "index": .integer(index),
      ]
      if let zoneValue = options["--zone"] {
        guard let zone = CardinalZone(rawValue: zoneValue) else {
          throw CLIUsageError("action zone must be top, right, bottom, or left")
        }
        params["zone"] = .string(zone.rawValue)
      }
      if let applicationBundleID = options["--when-app"] {
        try validateBundleID(applicationBundleID, option: "--when-app")
        guard options["--zone"] == CardinalZone.bottom.rawValue else {
          throw CLIUsageError("--when-app requires `--zone bottom`")
        }
        params["applicationBundleID"] = .string(applicationBundleID)
      }
      return request(.actionsMove, params: .object(params))
    default:
      throw CLIUsageError(
        "unknown actions subcommand \(actionCommand.debugDescription)"
      )
    }
  }

  private func parseHaptic(_ arguments: [String]) throws -> CLICommand {
    guard arguments.count == 1 || arguments.count == 2,
      arguments.first == "play"
    else {
      throw CLIUsageError("expected `haptic play [WAVEFORM_ID]`")
    }

    let waveformID: Int64
    if arguments.count == 2 {
      guard let value = Int64(arguments[1]), (0...255).contains(value) else {
        throw CLIUsageError("haptic waveform ID must be between 0 and 255")
      }
      waveformID = value
    } else {
      waveformID = 0
    }
    return request(.hapticPlay, params: ["waveformID": .integer(waveformID)])
  }

  private func parseSimulation(_ arguments: [String]) throws -> CLICommand {
    guard let simulationCommand = arguments.first else {
      throw CLIUsageError("a simulate subcommand is required")
    }
    let tail = Array(arguments.dropFirst())

    switch simulationCommand {
    case "invoke":
      guard tail.count >= 2 else {
        throw CLIUsageError("expected `simulate invoke X Y [--app BUNDLE_ID]`")
      }
      let point = try parseVector(
        Array(tail.prefix(2)),
        command: "simulate invoke X Y [--app BUNDLE_ID]"
      )
      let options = try parseValueOptions(
        Array(tail.dropFirst(2)),
        allowed: ["--app"],
        command: "simulate invoke X Y [--app BUNDLE_ID]"
      )
      var params: [String: JSONValue] = [
        "origin": ["x": .number(point.x), "y": .number(point.y)]
      ]
      if let bundleID = options["--app"] {
        try validateBundleID(bundleID, option: "--app")
        params["bundleID"] = .string(bundleID)
      }
      return request(
        .simulateInvoke,
        params: .object(params)
      )
    case "move":
      let delta = try parseVector(tail, command: "simulate move DX DY")
      return request(
        .simulateMove,
        params: [
          "delta": ["x": .number(delta.x), "y": .number(delta.y)]
        ]
      )
    case "release":
      try requireNoArguments(tail, command: "simulate release")
      return request(.simulateRelease)
    case "click":
      try requireNoArguments(tail, command: "simulate click")
      return request(.simulateClick)
    case "complete":
      try requireNoArguments(tail, command: "simulate complete")
      return request(.simulateComplete)
    case "dismiss":
      try requireNoArguments(tail, command: "simulate dismiss")
      return request(.simulateDismiss)
    case "cancel":
      try requireNoArguments(tail, command: "simulate cancel")
      return request(.simulateCancel)
    case "play":
      guard tail.count == 1 else {
        throw CLIUsageError("expected `simulate play FILE|-`")
      }
      let data: Data
      do {
        data = try loadScenario(tail[0])
      } catch {
        throw CLIUsageError(
          "could not read simulation \(tail[0].debugDescription): \(error.localizedDescription)"
        )
      }
      let inputs = try decodeScenario(data, source: tail[0])
      return request(
        .simulatePlay,
        params: ["inputs": .array(try inputs.map(jsonValue))]
      )
    default:
      throw CLIUsageError(
        "unknown simulate subcommand \(simulationCommand.debugDescription)"
      )
    }
  }

  private func putAction(
    name: String,
    action: ConfiguredAction,
    placement: ActionPlacement
  ) throws -> CLICommand {
    var params: [String: JSONValue] = [
      "name": .string(name),
      "action": try jsonValue(action),
      "zone": .string(placement.zone.rawValue),
    ]
    if let applicationBundleID = placement.applicationBundleID {
      params["applicationBundleID"] = .string(applicationBundleID)
    }
    return request(
      .actionsPut,
      params: .object(params)
    )
  }

  private func parsePlacement(_ options: [String: String]) throws -> ActionPlacement {
    let zone: CardinalZone
    if let value = options["--zone"] {
      guard let parsed = CardinalZone(rawValue: value) else {
        throw CLIUsageError("action zone must be top, right, bottom, or left")
      }
      zone = parsed
    } else {
      zone = .top
    }

    let applicationBundleID = options["--when-app"]
    if let applicationBundleID {
      try validateBundleID(applicationBundleID, option: "--when-app")
      guard zone == .bottom else {
        throw CLIUsageError("--when-app requires `--zone bottom`")
      }
    }
    return ActionPlacement(
      zone: zone,
      applicationBundleID: applicationBundleID
    )
  }

  private func parseApplicationBottomScope(
    _ options: [String: String],
    command: String
  ) throws -> String {
    guard let zoneValue = options["--zone"],
      let applicationBundleID = options["--when-app"]
    else {
      throw CLIUsageError(
        "\(command) requires `--zone bottom --when-app BUNDLE_ID`"
      )
    }
    guard zoneValue == CardinalZone.bottom.rawValue else {
      throw CLIUsageError("--when-app requires `--zone bottom`")
    }
    try validateBundleID(applicationBundleID, option: "--when-app")
    return applicationBundleID
  }

  private func parseValueOptions(
    _ arguments: [String],
    allowed: Set<String>,
    command: String
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      let name: String
      let value: String

      if let equals = argument.firstIndex(of: "=") {
        name = String(argument[..<equals])
        value = String(argument[argument.index(after: equals)...])
        guard !value.isEmpty else {
          throw CLIUsageError("option \(name.debugDescription) requires a value")
        }
        index += 1
      } else {
        name = argument
        guard index + 1 < arguments.count else {
          throw CLIUsageError("option \(name.debugDescription) requires a value")
        }
        value = arguments[index + 1]
        guard !value.hasPrefix("--") else {
          throw CLIUsageError("option \(name.debugDescription) requires a value")
        }
        index += 2
      }

      guard name.hasPrefix("--"), allowed.contains(name) else {
        throw CLIUsageError("expected `\(command)`; unknown option \(name.debugDescription)")
      }
      guard result.updateValue(value, forKey: name) == nil else {
        throw CLIUsageError("option \(name.debugDescription) may only be supplied once")
      }
    }
    return result
  }

  private func validateBundleID(_ value: String, option: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !value.contains("\0")
    else {
      throw CLIUsageError("\(option) must not be empty")
    }
  }

  private func parseActionName(_ name: String) throws -> String {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !name.contains("\0")
    else {
      throw CLIUsageError("action name must not be empty")
    }
    return name
  }

  private func parseModifiers(_ value: String) throws -> [KeyboardModifier] {
    let names = value.split(separator: ",", omittingEmptySubsequences: false)
    guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else {
      throw CLIUsageError("modifier list must not be empty")
    }

    var seen = Set<KeyboardModifier>()
    return try names.map { name in
      guard let modifier = KeyboardModifier(rawValue: String(name)) else {
        throw CLIUsageError("unknown keyboard modifier \(String(name).debugDescription)")
      }
      guard seen.insert(modifier).inserted else {
        throw CLIUsageError("duplicate keyboard modifier \(modifier.rawValue.debugDescription)")
      }
      return modifier
    }
  }

  private func parseVector(_ arguments: [String], command: String) throws -> Vector2 {
    guard arguments.count == 2,
      let x = Double(arguments[0]),
      let y = Double(arguments[1]),
      x.isFinite,
      y.isFinite
    else {
      throw CLIUsageError("expected `\(command)` with finite numbers")
    }
    return Vector2(x: x, y: y)
  }

  private func decodeScenario(_ data: Data, source: String) throws -> [RingInput] {
    let decoder = JSONDecoder()
    if let inputs = try? decoder.decode([RingInput].self, from: data) {
      return inputs
    }

    guard let text = String(data: data, encoding: .utf8) else {
      throw CLIUsageError("simulation \(source.debugDescription) is not UTF-8 JSON")
    }
    let records = text.split(whereSeparator: \Character.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !records.isEmpty else {
      throw CLIUsageError("simulation \(source.debugDescription) is empty")
    }

    do {
      return try records.enumerated().map { index, record in
        do {
          return try decoder.decode(RingInput.self, from: Data(record.utf8))
        } catch {
          throw CLIUsageError(
            "simulation \(source.debugDescription) has invalid JSON at record \(index + 1)"
          )
        }
      }
    } catch let usageError as CLIUsageError {
      throw usageError
    } catch {
      throw CLIUsageError("simulation \(source.debugDescription) is invalid")
    }
  }

  private func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
    do {
      let encoder = JSONEncoder()
      let data = try encoder.encode(value)
      return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw CLIUsageError("could not encode command parameters")
    }
  }

  private func requireNoArguments(_ arguments: [String], command: String) throws {
    guard arguments.isEmpty else {
      throw CLIUsageError("`\(command)` takes no arguments")
    }
  }

  private func request(
    _ method: ControlMethod,
    params: JSONValue = .object([:])
  ) -> CLICommand {
    .request(method: method, params: params)
  }

  private func follow(
    _ method: ControlMethod,
    params: JSONValue = .object([:])
  ) -> CLICommand {
    .follow(method: method, params: params)
  }

  private func parseSocketPath(_ path: String) throws -> URL {
    guard !path.isEmpty else {
      throw CLIUsageError("--socket path must not be empty")
    }
    guard path.hasPrefix("/") else {
      throw CLIUsageError("--socket path must be absolute")
    }
    guard !path.contains("\0") else {
      throw CLIUsageError("--socket path contains a null byte")
    }
    return URL(filePath: path, directoryHint: .notDirectory)
  }

  public static func readScenario(path: String) throws -> Data {
    if path == "-" {
      return FileHandle.standardInput.readDataToEndOfFile()
    }
    return try Data(contentsOf: URL(filePath: path, directoryHint: .notDirectory))
  }
}

public struct CLIUsageError: Error, Equatable, LocalizedError {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}
