import Darwin
import Foundation

public final class UnixControlServer: @unchecked Sendable {
  public typealias Handler = @Sendable (ControlRequest) throws -> JSONValue

  static let defaultMaximumPendingStreamFrames = 64

  public let socketURL: URL
  public let maximumFrameBytes: Int

  private let handler: Handler
  private let beforeStreamSend: @Sendable () -> Void
  private let maximumPendingStreamFrames: Int
  private let handlerQueue = DispatchQueue(label: "com.logiliquid.controls.control.handler")
  private let stateLock = NSLock()
  private var listener: Int32 = -1
  private var boundSocketIdentity: SocketIdentity?
  private var connections: [UUID: ServerConnection] = [:]

  public convenience init(
    socketURL: URL = LogiLiquidControlProtocol.defaultSocketURL,
    maximumFrameBytes: Int = LogiLiquidControlProtocol.defaultMaximumFrameBytes,
    handler: @escaping Handler
  ) {
    self.init(
      socketURL: socketURL,
      maximumFrameBytes: maximumFrameBytes,
      maximumPendingStreamFrames: Self.defaultMaximumPendingStreamFrames,
      beforeStreamSend: {},
      handler: handler
    )
  }

  init(
    socketURL: URL,
    maximumFrameBytes: Int,
    maximumPendingStreamFrames: Int,
    beforeStreamSend: @escaping @Sendable () -> Void,
    handler: @escaping Handler
  ) {
    precondition(
      maximumPendingStreamFrames > 0,
      "maximumPendingStreamFrames must be positive"
    )
    self.socketURL = socketURL
    self.maximumFrameBytes = maximumFrameBytes
    self.maximumPendingStreamFrames = maximumPendingStreamFrames
    self.beforeStreamSend = beforeStreamSend
    self.handler = handler
  }

  deinit {
    stop()
  }

  public var isRunning: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return listener >= 0
  }

  public var activeConnectionCount: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return connections.count
  }

  public var activeSubscriptionCount: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return connections.values.reduce(into: 0) { count, connection in
      count += connection.subscriptionCount
    }
  }

  public func start() throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard listener < 0 else { return }

    let path = socketURL.path
    try preparePrivateSocketDirectory(for: socketURL)
    try removeStaleSocketIfNeeded(at: path)

    let newListener = try createUnixSocket()
    do {
      try bindUnixSocket(newListener, path: path)
      guard chmod(path, 0o600) == 0 else { throw posixError("chmod") }
      guard Darwin.listen(newListener, 16) == 0 else { throw posixError("listen") }
      let identity = try socketIdentity(at: path)
      listener = newListener
      boundSocketIdentity = identity
    } catch {
      Darwin.close(newListener)
      _ = unlink(path)
      throw error
    }

    Thread.detachNewThread { [weak self] in
      self?.acceptLoop(fileDescriptor: newListener)
    }
  }

  public func stop() {
    let listenerToClose: Int32
    let identity: SocketIdentity?
    let connectionsToClose: [ServerConnection]

    stateLock.lock()
    listenerToClose = listener
    identity = boundSocketIdentity
    listener = -1
    boundSocketIdentity = nil
    connectionsToClose = Array(connections.values)
    stateLock.unlock()

    if listenerToClose >= 0 {
      Darwin.shutdown(listenerToClose, SHUT_RDWR)
      Darwin.close(listenerToClose)
    }
    for connection in connectionsToClose {
      connection.stop()
    }
    if let identity {
      unlinkSocketIfMatching(path: socketURL.path, identity: identity)
    }
  }

  /// Enqueues one NDJSON event frame for each current subscriber of `stream`.
  /// Publishing never performs socket I/O. Each connection has a bounded,
  /// serial writer lane; a subscriber that falls behind is closed instead of
  /// applying backpressure to the daemon or other subscribers.
  public func publish(
    stream: ControlStream,
    event: String,
    payload: JSONValue = .null
  ) {
    let subscribers: [(ServerConnection, String)]
    stateLock.lock()
    subscribers = connections.values.compactMap { connection in
      connection.requestID(for: stream).map { (connection, $0) }
    }
    stateLock.unlock()

    for (connection, requestID) in subscribers {
      connection.enqueue(
        ControlEvent(requestID: requestID, event: event, payload: payload)
      )
    }
  }

  private func acceptLoop(fileDescriptor: Int32) {
    while true {
      let accepted = Darwin.accept(fileDescriptor, nil, nil)
      if accepted < 0 {
        if errno == EINTR { continue }
        return
      }

      do {
        let io = try SocketFrameIO(
          fileDescriptor: accepted,
          maximumFrameBytes: maximumFrameBytes
        )
        let connection = ServerConnection(
          io: io,
          server: self,
          maximumPendingStreamFrames: maximumPendingStreamFrames,
          beforeStreamSend: beforeStreamSend
        )

        stateLock.lock()
        let shouldStart = listener == fileDescriptor
        if shouldStart {
          connections[connection.id] = connection
        }
        stateLock.unlock()

        if shouldStart {
          connection.start()
        } else {
          connection.stop()
        }
      } catch {
        Darwin.close(accepted)
      }
    }
  }

  fileprivate func process(_ request: ControlRequest, on connection: ServerConnection) {
    guard request.schemaVersion == LogiLiquidControlProtocol.schemaVersion else {
      connection.sendOrStop(
        .failure(
          requestID: request.requestID,
          error: .init(
            code: "unsupported_schema",
            message: "Unsupported control protocol schema version",
            data: .object([
              "expected": .integer(Int64(LogiLiquidControlProtocol.schemaVersion)),
              "received": .integer(Int64(request.schemaVersion)),
            ])
          )
        )
      )
      return
    }
    guard !request.requestID.isEmpty else {
      connection.sendOrStop(
        .failure(
          requestID: "",
          error: .init(code: "invalid_request", message: "requestID must not be empty")
        )
      )
      return
    }

    let outcome: Result<JSONValue, any Error> = handlerQueue.sync {
      Result { try handler(request) }
    }

    switch outcome {
    case .success(let result):
      let response = ControlResponse.success(requestID: request.requestID, result: result)
      if let stream = request.method.stream {
        register(stream: stream, requestID: request.requestID, on: connection, response: response)
      } else {
        connection.sendOrStop(response)
      }

    case .failure(let failure as ControlRequestFailure):
      connection.sendOrStop(
        .failure(requestID: request.requestID, error: failure.wireError)
      )

    case .failure:
      connection.sendOrStop(
        .failure(
          requestID: request.requestID,
          error: .init(
            code: "internal_error",
            message: "The control request could not be completed"
          )
        )
      )
    }
  }

  private func register(
    stream: ControlStream,
    requestID: String,
    on connection: ServerConnection,
    response: ControlResponse
  ) {
    // Keep registration and acknowledgement ordered against `publish` so
    // an event can neither be lost nor precede the successful response.
    stateLock.lock()
    guard connections[connection.id] === connection else {
      stateLock.unlock()
      return
    }
    connection.setSubscription(requestID: requestID, for: stream)
    do {
      try connection.send(response)
      stateLock.unlock()
    } catch {
      stateLock.unlock()
      connection.stop()
    }
  }

  fileprivate func remove(_ connection: ServerConnection) {
    stateLock.lock()
    if connections[connection.id] === connection {
      connections.removeValue(forKey: connection.id)
    }
    stateLock.unlock()
  }
}

private final class ServerConnection: @unchecked Sendable {
  let id = UUID()
  private let io: SocketFrameIO
  private weak var server: UnixControlServer?
  private let maximumPendingStreamFrames: Int
  private let beforeStreamSend: @Sendable () -> Void
  private let streamWriterQueue: DispatchQueue
  private let streamWriterLock = NSLock()
  private var pendingStreamFrames = 0
  private var streamWriterStopped = false
  private var subscriptions: [ControlStream: String] = [:]

  init(
    io: SocketFrameIO,
    server: UnixControlServer,
    maximumPendingStreamFrames: Int,
    beforeStreamSend: @escaping @Sendable () -> Void
  ) {
    self.io = io
    self.server = server
    self.maximumPendingStreamFrames = maximumPendingStreamFrames
    self.beforeStreamSend = beforeStreamSend
    self.streamWriterQueue = DispatchQueue(
      label: "com.logiliquid.controls.control.stream-writer.\(id.uuidString)"
    )
  }

  var subscriptionCount: Int { subscriptions.count }

  func requestID(for stream: ControlStream) -> String? {
    subscriptions[stream]
  }

  func setSubscription(requestID: String, for stream: ControlStream) {
    subscriptions[stream] = requestID
  }

  func start() {
    Thread.detachNewThread { [weak self] in
      self?.run()
    }
  }

  func stop() {
    streamWriterLock.lock()
    streamWriterStopped = true
    streamWriterLock.unlock()
    io.close()
  }

  func enqueue(_ event: ControlEvent) {
    streamWriterLock.lock()
    guard !streamWriterStopped,
      pendingStreamFrames < maximumPendingStreamFrames
    else {
      streamWriterLock.unlock()
      stop()
      return
    }
    pendingStreamFrames += 1
    streamWriterLock.unlock()

    streamWriterQueue.async { [weak self] in
      self?.sendStreamEvent(event)
    }
  }

  func send<T: Encodable>(_ frame: T) throws {
    try io.send(frame)
  }

  func sendOrStop(_ response: ControlResponse) {
    do {
      try send(response)
    } catch {
      stop()
    }
  }

  private func sendStreamEvent(_ event: ControlEvent) {
    beforeStreamSend()

    streamWriterLock.lock()
    let shouldSend = !streamWriterStopped
    streamWriterLock.unlock()

    if shouldSend {
      do {
        try io.send(event)
      } catch {
        stop()
      }
    }

    streamWriterLock.lock()
    pendingStreamFrames -= 1
    streamWriterLock.unlock()
  }

  private func run() {
    defer {
      io.close()
      server?.remove(self)
    }

    let decoder = JSONDecoder()
    while true {
      do {
        guard let frame = try io.readFrame() else { return }
        do {
          let request = try decoder.decode(ControlRequest.self, from: frame)
          server?.process(request, on: self)
        } catch {
          sendOrStop(
            .failure(
              requestID: "",
              error: .init(
                code: "invalid_request",
                message: "Frame is not a valid control request"
              )
            )
          )
        }
      } catch ControlTransportError.frameTooLarge {
        sendOrStop(
          .failure(
            requestID: "",
            error: .init(
              code: "frame_too_large",
              message: "Control frame exceeds the configured size limit"
            )
          )
        )
        return
      } catch ControlTransportError.malformedFrame {
        sendOrStop(
          .failure(
            requestID: "",
            error: .init(code: "invalid_request", message: "Incomplete control frame")
          )
        )
        return
      } catch {
        return
      }
    }
  }
}
