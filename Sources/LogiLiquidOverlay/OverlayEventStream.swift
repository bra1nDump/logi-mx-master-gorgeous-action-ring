import Foundation
import LogiLiquidControl
import LogiLiquidCore

/// A decoded event the overlay reacts to.
enum OverlayStreamEvent: Sendable {
  case transition(RingFrame)
  case disconnected
}

/// Subscribes to the daemon's `events.follow` stream over the private Unix
/// socket, decodes `ring.transition` frames, and delivers them to the
/// controller. It owns reconnection: if the daemon is not yet running, or the
/// stream drops, it reports a disconnect and retries with a steady backoff so a
/// per-user LaunchAgent can start before or after the daemon in any order.
final class OverlayEventStream: @unchecked Sendable {
  private let client: UnixControlClient
  private let retryInterval: TimeInterval
  private let onEvent: @Sendable (OverlayStreamEvent) -> Void

  private let queue = DispatchQueue(label: "com.logiliquid.controls.overlay.events")
  private let lock = NSLock()
  private var running = false
  private var subscription: UnixControlSubscription?

  init(
    client: UnixControlClient = UnixControlClient(),
    retryInterval: TimeInterval = 1.0,
    onEvent: @escaping @Sendable (OverlayStreamEvent) -> Void
  ) {
    self.client = client
    self.retryInterval = retryInterval
    self.onEvent = onEvent
  }

  func start() {
    lock.lock()
    guard !running else {
      lock.unlock()
      return
    }
    running = true
    lock.unlock()
    queue.async { [weak self] in self?.runLoop() }
  }

  func stop() {
    lock.lock()
    running = false
    let subscription = self.subscription
    self.subscription = nil
    lock.unlock()
    subscription?.cancel()
  }

  private var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  private func runLoop() {
    while isRunning {
      do {
        let subscription = try client.subscribe(method: .eventsFollow)
        lock.lock()
        self.subscription = subscription
        lock.unlock()

        while isRunning, let event = try subscription.next() {
          handle(event)
        }
      } catch {
        // The daemon is not up yet, or the stream faulted. Fall through to retry.
      }

      lock.lock()
      subscription = nil
      lock.unlock()

      guard isRunning else { break }
      onEvent(.disconnected)
      Thread.sleep(forTimeInterval: retryInterval)
    }
  }

  private func handle(_ event: ControlEvent) {
    switch event.event {
    case "ring.transition":
      do {
        let frame = try Self.decodeFrame(from: event.payload)
        onEvent(.transition(frame))
      } catch {
        let message = "logi-liquid-overlay: invalid ring.transition payload: \(error)\n"
        FileHandle.standardError.write(Data(message.utf8))
      }
    case "daemon.device-error":
      // The device dropped; the interaction is over. Treat as a disconnect so
      // the overlay hides even though the socket may stay open.
      onEvent(.disconnected)
    default:
      break
    }
  }

  /// Decodes the `RingTransition` payload and returns only its frame. Cursor,
  /// haptic, and action intents are intentionally discarded — the UI never acts
  /// on them.
  private static func decodeFrame(from payload: JSONValue) throws -> RingFrame {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(RingTransition.self, from: data).frame
  }
}
