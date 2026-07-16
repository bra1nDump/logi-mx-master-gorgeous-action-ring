import Darwin
import Foundation

public final class UnixControlClient: Sendable {
  public let socketURL: URL
  public let maximumFrameBytes: Int

  public init(
    socketURL: URL = LogiLiquidControlProtocol.defaultSocketURL,
    maximumFrameBytes: Int = LogiLiquidControlProtocol.defaultMaximumFrameBytes
  ) {
    self.socketURL = socketURL
    self.maximumFrameBytes = maximumFrameBytes
  }

  public func request(
    method: ControlMethod,
    params: JSONValue = .object([:]),
    requestID: String = UUID().uuidString
  ) throws -> ControlResponse {
    try request(
      ControlRequest(requestID: requestID, method: method, params: params)
    )
  }

  public func request(_ request: ControlRequest) throws -> ControlResponse {
    let io = try connect()
    defer { io.close() }
    try io.send(request)
    guard let frame = try io.readFrame() else {
      throw ControlTransportError.connectionClosed
    }
    let response: ControlResponse
    do {
      response = try JSONDecoder().decode(ControlResponse.self, from: frame)
    } catch {
      throw ControlTransportError.malformedFrame
    }
    try validate(response, for: request)
    return response
  }

  public func subscribe(
    method: ControlMethod,
    params: JSONValue = .object([:]),
    requestID: String = UUID().uuidString
  ) throws -> UnixControlSubscription {
    try subscribe(
      ControlRequest(requestID: requestID, method: method, params: params)
    )
  }

  public func subscribe(_ request: ControlRequest) throws -> UnixControlSubscription {
    guard request.method.stream != nil else {
      throw ControlTransportError.notAStreamingMethod(request.method)
    }

    let io = try connect()
    do {
      try io.send(request)
      guard let frame = try io.readFrame() else {
        throw ControlTransportError.connectionClosed
      }
      let acknowledgement: ControlResponse
      do {
        acknowledgement = try JSONDecoder().decode(ControlResponse.self, from: frame)
      } catch {
        throw ControlTransportError.malformedFrame
      }
      try validate(acknowledgement, for: request)
      if let error = acknowledgement.error {
        throw error
      }
      return UnixControlSubscription(
        io: io,
        requestID: request.requestID,
        acknowledgement: acknowledgement
      )
    } catch {
      io.close()
      throw error
    }
  }

  private func connect() throws -> SocketFrameIO {
    let fileDescriptor = try createUnixSocket()
    do {
      try connectUnixSocket(fileDescriptor, path: socketURL.path)
      return try SocketFrameIO(
        fileDescriptor: fileDescriptor,
        maximumFrameBytes: maximumFrameBytes
      )
    } catch {
      Darwin.close(fileDescriptor)
      throw error
    }
  }

  private func validate(_ response: ControlResponse, for request: ControlRequest) throws {
    guard response.schemaVersion == LogiLiquidControlProtocol.schemaVersion else {
      throw ControlTransportError.protocolMismatch(
        expected: LogiLiquidControlProtocol.schemaVersion,
        received: response.schemaVersion
      )
    }
    guard response.requestID == request.requestID else {
      throw ControlTransportError.responseRequestIDMismatch(
        expected: request.requestID,
        received: response.requestID
      )
    }
  }
}

public final class UnixControlSubscription: @unchecked Sendable {
  public let requestID: String
  public let acknowledgement: ControlResponse

  private let io: SocketFrameIO

  fileprivate init(
    io: SocketFrameIO,
    requestID: String,
    acknowledgement: ControlResponse
  ) {
    self.io = io
    self.requestID = requestID
    self.acknowledgement = acknowledgement
  }

  deinit {
    cancel()
  }

  /// Blocks until the next NDJSON event arrives or the server cleanly closes
  /// the subscription. Use one reader per subscription.
  public func next() throws -> ControlEvent? {
    guard let frame = try io.readFrame() else { return nil }
    let event: ControlEvent
    do {
      event = try JSONDecoder().decode(ControlEvent.self, from: frame)
    } catch {
      throw ControlTransportError.malformedFrame
    }
    guard event.schemaVersion == LogiLiquidControlProtocol.schemaVersion else {
      throw ControlTransportError.protocolMismatch(
        expected: LogiLiquidControlProtocol.schemaVersion,
        received: event.schemaVersion
      )
    }
    guard event.requestID == requestID else {
      throw ControlTransportError.responseRequestIDMismatch(
        expected: requestID,
        received: event.requestID
      )
    }
    return event
  }

  public func cancel() {
    io.close()
  }
}
