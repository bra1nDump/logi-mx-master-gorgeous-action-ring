import Foundation
import LogiLiquidControl

public enum CLIExitCode: Int32, Equatable {
  case success = 0
  case usage = 2
  case transport = 3
  case daemon = 4
  case software = 5
  case service = 6
}

public protocol CLIControlEventStream: AnyObject {
  func next() throws -> ControlEvent?
}

public protocol CLIControlTransport {
  func request(_ request: ControlRequest) throws -> ControlResponse
  func subscribe(_ request: ControlRequest) throws -> any CLIControlEventStream
}

public final class UnixCLIControlEventStream: CLIControlEventStream {
  private let subscription: UnixControlSubscription

  public init(subscription: UnixControlSubscription) {
    self.subscription = subscription
  }

  public func next() throws -> ControlEvent? {
    try subscription.next()
  }
}

public final class UnixCLIControlTransport: CLIControlTransport {
  private let client: UnixControlClient

  public init(socketURL: URL) {
    client = UnixControlClient(socketURL: socketURL)
  }

  public func request(_ request: ControlRequest) throws -> ControlResponse {
    try client.request(request)
  }

  public func subscribe(_ request: ControlRequest) throws -> any CLIControlEventStream {
    UnixCLIControlEventStream(subscription: try client.subscribe(request))
  }
}

public struct CLIIO {
  public var writeStandardOutput: (Data) -> Void
  public var writeStandardError: (Data) -> Void

  public init(
    writeStandardOutput: @escaping (Data) -> Void,
    writeStandardError: @escaping (Data) -> Void
  ) {
    self.writeStandardOutput = writeStandardOutput
    self.writeStandardError = writeStandardError
  }

  public static var standard: CLIIO {
    CLIIO(
      writeStandardOutput: { FileHandle.standardOutput.write($0) },
      writeStandardError: { FileHandle.standardError.write($0) }
    )
  }
}

/// Testable command runner. Every command is a single request except follow
/// streams, which emit one complete ControlEvent JSON value per output line.
public struct LogiLiquidCLI {
  public typealias TransportFactory = (URL) -> any CLIControlTransport
  public typealias RequestIDFactory = () -> String

  private let parser: CLIArgumentParser
  private let makeTransport: TransportFactory
  private let requestID: RequestIDFactory
  private let io: CLIIO
  private let serviceLifecycle: any ServiceLifecycleControlling

  public init(
    parser: CLIArgumentParser = CLIArgumentParser(),
    makeTransport: @escaping TransportFactory = { UnixCLIControlTransport(socketURL: $0) },
    requestID: @escaping RequestIDFactory = { UUID().uuidString },
    io: CLIIO = .standard,
    serviceLifecycle: any ServiceLifecycleControlling = ServiceLifecycleController()
  ) {
    self.parser = parser
    self.makeTransport = makeTransport
    self.requestID = requestID
    self.io = io
    self.serviceLifecycle = serviceLifecycle
  }

  @discardableResult
  public func run(arguments: [String]) -> CLIExitCode {
    do {
      let invocation = try parser.parse(arguments: arguments)
      switch invocation.command {
      case .help:
        writeStandardOutput(CLIArgumentParser.usage)
        return .success

      case .service(let command):
        try writeJSONLine(serviceLifecycle.perform(command))
        return .success

      case .request(let method, let params):
        let request = ControlRequest(
          requestID: requestID(),
          method: method,
          params: params
        )
        let response = try makeTransport(invocation.socketURL).request(request)
        try writeJSONLine(response)
        if let error = response.error {
          writeStandardError("daemon error [\(error.code)]: \(error.message)\n")
          return .daemon
        }
        return .success

      case .follow(let method, let params):
        let request = ControlRequest(
          requestID: requestID(),
          method: method,
          params: params
        )
        let stream = try makeTransport(invocation.socketURL).subscribe(request)
        while let event = try stream.next() {
          try writeJSONLine(event)
        }
        return .success
      }
    } catch let error as CLIUsageError {
      writeStandardError("error: \(error.message)\n\n\(CLIArgumentParser.usage)\n")
      return .usage
    } catch let error as ControlWireError {
      writeStandardError("daemon error [\(error.code)]: \(error.message)\n")
      return .daemon
    } catch let error as ControlTransportError {
      writeStandardError("transport error: \(describe(error))\n")
      return .transport
    } catch let error as ServiceLifecycleError {
      writeStandardError("service error [\(error.code)]: \(error.localizedDescription)\n")
      return .service
    } catch {
      writeStandardError("internal error: \(error.localizedDescription)\n")
      return .software
    }
  }

  private func writeJSONLine<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    io.writeStandardOutput(data)
  }

  private func writeStandardOutput(_ value: String) {
    io.writeStandardOutput(Data(value.utf8))
  }

  private func writeStandardError(_ value: String) {
    io.writeStandardError(Data(value.utf8))
  }

  private func describe(_ error: ControlTransportError) -> String {
    switch error {
    case .invalidSocketPath(let path):
      "invalid socket path \(path.debugDescription)"
    case .insecureSocketDirectory(let path):
      "insecure socket directory \(path.debugDescription)"
    case .socketAlreadyInUse(let path):
      "socket already in use at \(path.debugDescription)"
    case .systemCall(let operation, let code):
      "\(operation) failed with errno \(code)"
    case .connectionClosed:
      "connection closed"
    case .frameTooLarge(let limit):
      "control frame exceeds \(limit) bytes"
    case .malformedFrame:
      "daemon returned malformed JSON"
    case .protocolMismatch(let expected, let received):
      "protocol mismatch: expected \(expected), received \(received)"
    case .responseRequestIDMismatch(let expected, let received):
      "request ID mismatch: expected \(expected.debugDescription), received \(received.debugDescription)"
    case .notAStreamingMethod(let method):
      "\(method.rawValue) is not a streaming method"
    }
  }
}
