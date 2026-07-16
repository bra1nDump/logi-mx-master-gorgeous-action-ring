import CoreGraphics
import Foundation

public protocol PrimaryMouseButtonStateProviding: Sendable {
  func isPrimaryButtonPressed() throws -> Bool
}

public struct SystemPrimaryMouseButtonStateProvider:
  PrimaryMouseButtonStateProviding, Sendable
{
  public init() {}

  public func isPrimaryButtonPressed() throws -> Bool {
    CGEventSource.buttonState(.combinedSessionState, button: .left)
  }
}

/// Permission-free polling of the primary mouse button's state. This avoids a
/// global event tap (and its Input Monitoring permission) while still turning
/// one physical down edge into exactly one ring click. Pointer movement has its
/// own raw-HID/system-position handoff and is never sampled here.
public final class SystemPrimaryClickMonitor:
  MouseDaemonPrimaryClickMonitoring, @unchecked Sendable
{
  private let stateProvider: any PrimaryMouseButtonStateProviding
  private let interval: TimeInterval
  private let condition = NSCondition()

  private var handler: (@Sendable (MouseDaemonPrimaryClickEvent) -> Void)?
  private var running = false
  private var stopping = false
  private var tracking = false
  private var trackingGeneration: UInt64 = 0

  public init(
    stateProvider: any PrimaryMouseButtonStateProviding =
      SystemPrimaryMouseButtonStateProvider(),
    samplesPerSecond: Double = 120
  ) throws {
    guard samplesPerSecond.isFinite, samplesPerSecond > 0 else {
      throw MouseDaemonError.invalidParameter(
        "Primary-click sampling frequency must be positive."
      )
    }
    self.stateProvider = stateProvider
    self.interval = 1 / samplesPerSecond
  }

  deinit {
    stop()
  }

  public func start(
    eventHandler: @escaping @Sendable (MouseDaemonPrimaryClickEvent) -> Void
  ) throws {
    condition.lock()
    guard !running else {
      condition.unlock()
      throw MouseDaemonError.alreadyRunning
    }
    handler = eventHandler
    running = true
    stopping = false
    tracking = false
    condition.unlock()

    Thread.detachNewThread { [self] in
      run()
    }
  }

  public func setTracking(_ tracking: Bool) {
    condition.lock()
    if self.tracking != tracking {
      trackingGeneration &+= 1
    }
    self.tracking = tracking
    condition.broadcast()
    condition.unlock()
  }

  public func stop() {
    condition.lock()
    guard running else {
      condition.unlock()
      return
    }
    stopping = true
    tracking = false
    condition.broadcast()
    while running {
      condition.wait()
    }
    handler = nil
    condition.unlock()
  }

  private func run() {
    var previousButtonState: Bool?
    var observedGeneration: UInt64?

    while true {
      condition.lock()
      while !stopping && !tracking {
        previousButtonState = nil
        condition.wait()
      }
      if stopping {
        running = false
        condition.broadcast()
        condition.unlock()
        return
      }
      let handler = handler
      let generation = trackingGeneration
      condition.unlock()

      if observedGeneration != generation {
        previousButtonState = nil
        observedGeneration = generation
      }

      do {
        let currentButtonState = try stateProvider.isPrimaryButtonPressed()
        if previousButtonState == false, currentButtonState {
          handler?(.primaryClick)
        }
        previousButtonState = currentButtonState
      } catch {
        handler?(.terminated(message: error.localizedDescription))
        setTracking(false)
      }

      condition.lock()
      if tracking && !stopping {
        _ = condition.wait(until: Date(timeIntervalSinceNow: interval))
      }
      condition.unlock()
    }
  }
}
