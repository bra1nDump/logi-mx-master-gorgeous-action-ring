import Foundation

/// Versioned wire constants shared by the daemon and every CLI client.
public enum LogiLiquidControlProtocol {
  public static let schemaVersion = 1
  public static let defaultMaximumFrameBytes = 64 * 1024

  /// The private, per-user default endpoint. Callers may supply another path
  /// (for example, a temporary path in tests).
  public static var defaultSocketURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".logi-liquid-controls", directoryHint: .isDirectory)
      .appending(path: "run", directoryHint: .isDirectory)
      .appending(path: "mouse-control.sock", directoryHint: .notDirectory)
  }
}

/// The complete, deliberately small RPC surface. Raw values are the stable
/// command names used on the wire and by the native CLI.
public enum ControlMethod: String, Codable, CaseIterable, Sendable {
  case status
  case doctor
  case deviceInspect = "device.inspect"
  case eventsFollow = "events.follow"
  case reportsFollow = "reports.follow"
  case actionsList = "actions.list"
  case actionsResolve = "actions.resolve"
  case actionsPut = "actions.put"
  case actionsRemove = "actions.remove"
  case actionsClear = "actions.clear"
  case actionsMove = "actions.move"
  case hapticPlay = "haptic.play"
  case simulateInvoke = "simulate.invoke"
  case simulateMove = "simulate.move"
  case simulateRelease = "simulate.release"
  case simulateClick = "simulate.click"
  case simulateComplete = "simulate.complete"
  case simulateDismiss = "simulate.dismiss"
  case simulateCancel = "simulate.cancel"
  case simulatePlay = "simulate.play"

  public var stream: ControlStream? {
    switch self {
    case .eventsFollow: .events
    case .reportsFollow: .reports
    default: nil
    }
  }
}

public enum ControlStream: String, Codable, CaseIterable, Sendable {
  case events
  case reports
}

/// A JSON value without a dependency on a third-party dynamic-value package.
/// Integers are kept losslessly instead of being coerced through `Double`.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(key: String) -> JSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .number(let value):
      guard value.isFinite else {
        throw EncodingError.invalidValue(
          value,
          .init(
            codingPath: container.codingPath,
            debugDescription: "JSON numbers must be finite"
          )
        )
      }
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

extension JSONValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}

public struct ControlRequest: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var requestID: String
  public var method: ControlMethod
  public var params: JSONValue

  public init(
    schemaVersion: Int = LogiLiquidControlProtocol.schemaVersion,
    requestID: String = UUID().uuidString,
    method: ControlMethod,
    params: JSONValue = .object([:])
  ) {
    self.schemaVersion = schemaVersion
    self.requestID = requestID
    self.method = method
    self.params = params
  }
}

public struct ControlWireError: Error, Codable, Equatable, Sendable {
  public var code: String
  public var message: String
  public var data: JSONValue

  public init(code: String, message: String, data: JSONValue = .null) {
    self.code = code
    self.message = message
    self.data = data
  }
}

public struct ControlResponse: Equatable, Sendable {
  public var schemaVersion: Int
  public var requestID: String
  public var result: JSONValue
  public var error: ControlWireError?

  public init(
    schemaVersion: Int = LogiLiquidControlProtocol.schemaVersion,
    requestID: String,
    result: JSONValue = .null,
    error: ControlWireError? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.requestID = requestID
    self.result = result
    self.error = error
  }

  public static func success(requestID: String, result: JSONValue) -> Self {
    .init(requestID: requestID, result: result)
  }

  public static func failure(requestID: String, error: ControlWireError) -> Self {
    .init(requestID: requestID, error: error)
  }
}

extension ControlResponse: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case requestID
    case result
    case error
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    requestID = try container.decode(String.self, forKey: .requestID)
    result = try container.decode(JSONValue.self, forKey: .result)
    error =
      try container.decodeNil(forKey: .error)
      ? nil
      : try container.decode(ControlWireError.self, forKey: .error)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(result, forKey: .result)
    if let error {
      try container.encode(error, forKey: .error)
    } else {
      try container.encodeNil(forKey: .error)
    }
  }
}

/// Subsequent frames on a successful `*.follow` connection. `requestID`
/// identifies the subscription request, allowing multiple streams to share a
/// stable envelope shape.
public struct ControlEvent: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var requestID: String
  public var event: String
  public var payload: JSONValue

  public init(
    schemaVersion: Int = LogiLiquidControlProtocol.schemaVersion,
    requestID: String,
    event: String,
    payload: JSONValue = .null
  ) {
    self.schemaVersion = schemaVersion
    self.requestID = requestID
    self.event = event
    self.payload = payload
  }
}

/// Throw this from a server handler to return an intentional, structured error
/// without exposing implementation-specific error descriptions on the wire.
public struct ControlRequestFailure: Error, Equatable, Sendable {
  public let wireError: ControlWireError

  public init(code: String, message: String, data: JSONValue = .null) {
    wireError = .init(code: code, message: message, data: data)
  }
}

public enum ControlTransportError: Error, Equatable, Sendable {
  case invalidSocketPath(String)
  case insecureSocketDirectory(String)
  case socketAlreadyInUse(String)
  case systemCall(operation: String, code: Int32)
  case connectionClosed
  case frameTooLarge(limit: Int)
  case malformedFrame
  case protocolMismatch(expected: Int, received: Int)
  case responseRequestIDMismatch(expected: String, received: String)
  case notAStreamingMethod(ControlMethod)
}
