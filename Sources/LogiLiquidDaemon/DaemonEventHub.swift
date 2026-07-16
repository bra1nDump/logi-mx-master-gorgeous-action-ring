import Foundation
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidService

public struct MouseDaemonPublishedEvent: Equatable, Sendable {
  public let stream: ControlStream
  public let event: String
  public let payload: JSONValue

  public init(stream: ControlStream, event: String, payload: JSONValue) {
    self.stream = stream
    self.event = event
    self.payload = payload
  }
}

/// Synchronous fan-out keeps state-machine transitions ordered before the next
/// input. Individual sinks are expected to enqueue their own I/O promptly.
public final class MouseDaemonEventHub: RingEventPublishing, @unchecked Sendable {
  public typealias Sink = @Sendable (MouseDaemonPublishedEvent) -> Void

  private let lock = NSLock()
  private var sinks: [UUID: Sink] = [:]

  public init() {}

  @discardableResult
  public func subscribe(_ sink: @escaping Sink) -> UUID {
    let token = UUID()
    lock.lock()
    sinks[token] = sink
    lock.unlock()
    return token
  }

  public func unsubscribe(_ token: UUID) {
    lock.lock()
    sinks.removeValue(forKey: token)
    lock.unlock()
  }

  public func publish(_ transition: RingTransition) {
    do {
      publish(
        stream: .events,
        event: "ring.transition",
        payload: try MouseDaemonJSON.encode(transition)
      )
    } catch {
      publish(
        stream: .events,
        event: "daemon.encoding-error",
        payload: .object(["message": .string(error.localizedDescription)])
      )
    }
  }

  public func publish(
    stream: ControlStream,
    event: String,
    payload: JSONValue = .null
  ) {
    let event = MouseDaemonPublishedEvent(
      stream: stream,
      event: event,
      payload: payload
    )
    lock.lock()
    let currentSinks = Array(sinks.values)
    lock.unlock()
    for sink in currentSinks {
      sink(event)
    }
  }
}
