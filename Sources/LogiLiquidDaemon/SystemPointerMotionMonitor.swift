import Foundation
import LogiLiquidCore
import LogiLiquidService

/// Permission-free pointer sampling used after Sense Panel release. Each
/// tracking session takes a new baseline before publishing relative movement,
/// preventing the hidden cursor's prior position from becoming a jump.
public final class SystemPointerMotionMonitor:
  MouseDaemonPointerMotionMonitoring, @unchecked Sendable
{
  private let positionProvider: any CursorPositionProviding
  private let interval: TimeInterval
  private let condition = NSCondition()

  private var handler: (@Sendable (MouseDaemonPointerMotionEvent) -> Void)?
  private var running = false
  private var stopping = false
  private var tracking = false
  private var trackingGeneration: UInt64 = 0

  public init(
    positionProvider: any CursorPositionProviding = SystemCursorPositionProvider(),
    samplesPerSecond: Double = 120
  ) throws {
    guard samplesPerSecond.isFinite, samplesPerSecond > 0 else {
      throw MouseDaemonError.invalidParameter(
        "Pointer sampling frequency must be positive."
      )
    }
    self.positionProvider = positionProvider
    self.interval = 1 / samplesPerSecond
  }

  deinit {
    stop()
  }

  public func start(
    eventHandler: @escaping @Sendable (MouseDaemonPointerMotionEvent) -> Void
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
    var previousPosition: Vector2?
    var observedGeneration: UInt64?

    while true {
      condition.lock()
      while !stopping && !tracking {
        previousPosition = nil
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
        previousPosition = nil
        observedGeneration = generation
      }

      do {
        let currentPosition = try positionProvider.currentPosition()
        if let previousPosition {
          let delta = Vector2(
            x: currentPosition.x - previousPosition.x,
            y: currentPosition.y - previousPosition.y
          )
          if delta != .zero {
            handler?(.pointerDelta(delta))
          }
        }
        previousPosition = currentPosition
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
