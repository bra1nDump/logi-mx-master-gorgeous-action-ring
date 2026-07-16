import AppKit
import ApplicationServices
import CLogiLiquidCursor
import Foundation
import LogiLiquidCore

protocol SystemActionExecutorSystem: Sendable {
  var isAccessibilityTrusted: Bool { get }

  func applicationURL(bundleIdentifier: String) -> URL?
  func applicationURL(toOpen url: URL) -> URL?
  func isApplicationRunning(bundleIdentifier: String) -> Bool
  func openApplication(at url: URL)
  func open(_ url: URL) -> Bool
  func postKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) throws
  func wait(milliseconds: Int)
  func fileExists(atPath path: String) -> Bool
  func isExecutableFile(atPath path: String) -> Bool
  func launch(executable: ExecutableAction) throws
  func sendAppleEvent(
    bundleIdentifier: String,
    eventClass: AEEventClass,
    eventID: AEEventID
  ) throws
}

struct MacOSActionExecutorSystem: SystemActionExecutorSystem {
  var isAccessibilityTrusted: Bool {
    AXIsProcessTrusted()
  }

  func applicationURL(bundleIdentifier: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }

  func applicationURL(toOpen url: URL) -> URL? {
    NSWorkspace.shared.urlForApplication(toOpen: url)
  }

  func isApplicationRunning(bundleIdentifier: String) -> Bool {
    !NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).isEmpty
  }

  func openApplication(at url: URL) {
    NSWorkspace.shared.openApplication(
      at: url,
      configuration: NSWorkspace.OpenConfiguration(),
      completionHandler: nil
    )
  }

  func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }

  func postKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) throws {
    let source = CGEventSource(stateID: .hidSystemState)
    guard
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: keyCode,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: keyCode,
        keyDown: false
      )
    else {
      throw SystemActionExecutorError.keyboardEventCreationFailed
    }

    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
  }

  func wait(milliseconds: Int) {
    Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
  }

  func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  func isExecutableFile(atPath path: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
  }

  func launch(executable: ExecutableAction) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable.executable)
    process.arguments = executable.argv
    try process.run()
  }

  func sendAppleEvent(
    bundleIdentifier: String,
    eventClass: AEEventClass,
    eventID: AEEventID
  ) throws {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
    let event = NSAppleEventDescriptor(
      eventClass: eventClass,
      eventID: eventID,
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    // Play has no useful return value. Spotify's Electron scripting bridge can
    // take several seconds to reply even after it has accepted the command, so
    // enqueue it without blocking the ring interaction on that reply.
    _ = try event.sendEvent(options: .noReply, timeout: 5)
  }
}

public struct SystemCursorPositionProvider: CursorPositionProviding, Sendable {
  public init() {}

  public func currentPosition() throws -> Vector2 {
    guard let event = CGEvent(source: nil) else {
      throw SystemCursorPositionError.positionUnavailable
    }
    return Vector2(x: event.location.x, y: event.location.y)
  }
}

public enum SystemCursorPositionError: Error, Equatable, Sendable {
  case positionUnavailable
}

public struct SystemFrontmostApplicationProvider:
  FrontmostApplicationProviding, Sendable
{
  public init() {}

  public func currentApplication() throws -> FrontmostApplicationContext {
    let application = NSWorkspace.shared.frontmostApplication
    return FrontmostApplicationContext(
      bundleID: application?.bundleIdentifier,
      localizedName: application?.localizedName
    )
  }
}

protocol SystemCursorVisibilitySystem: Sendable {
  func enableBackgroundCursorControl() throws
  func hideCursor() throws
  func showCursor() throws
}

struct MacOSCursorVisibilitySystem: SystemCursorVisibilitySystem {
  func enableBackgroundCursorControl() throws {
    let result = llc_enable_background_cursor_control()
    guard result == LLC_BACKGROUND_CURSOR_OK else {
      throw SystemCursorVisibilityError.backgroundConnection(result)
    }
  }

  func hideCursor() throws {
    let result = CGDisplayHideCursor(CGMainDisplayID())
    guard result == .success else {
      throw SystemCursorVisibilityError.coreGraphics(result.rawValue)
    }
  }

  func showCursor() throws {
    let result = CGDisplayShowCursor(CGMainDisplayID())
    guard result == .success else {
      throw SystemCursorVisibilityError.coreGraphics(result.rawValue)
    }
  }
}

public final class SystemCursorVisibilityController:
  CursorVisibilityControlling, @unchecked Sendable
{
  private let system: any SystemCursorVisibilitySystem
  private let lock = NSLock()
  private var hidden = false

  public convenience init() {
    self.init(system: MacOSCursorVisibilitySystem())
  }

  init(system: any SystemCursorVisibilitySystem) {
    self.system = system
  }

  deinit {
    try? restoreCursor()
  }

  public func hideCursor() throws {
    try lock.withLock {
      guard !hidden else { return }
      // CGDisplayHideCursor alone does not remain authoritative when this
      // LaunchAgent is in the background. Opt this WindowServer connection in
      // on every new hide cycle; the property can be reset as focus changes.
      try system.enableBackgroundCursorControl()
      try system.hideCursor()
      hidden = true
    }
  }

  public func restoreCursor() throws {
    try lock.withLock {
      guard hidden else { return }
      try system.showCursor()
      // A failed show retains ownership so shutdown/deinit or a later
      // interaction can retry without issuing an unbalanced extra show.
      hidden = false
    }
  }
}

public enum SystemCursorVisibilityError: Error, Equatable, Sendable {
  case backgroundConnection(Int32)
  case coreGraphics(CGError.RawValue)
}

extension SystemCursorVisibilityError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .backgroundConnection(let code):
      "Could not enable background cursor control through WindowServer (\(code))."
    case .coreGraphics(let code):
      "CoreGraphics cursor visibility operation failed (\(code))."
    }
  }
}

public struct SystemActionExecutor: ActionExecuting, Sendable {
  private let system: any SystemActionExecutorSystem

  public init() {
    system = MacOSActionExecutorSystem()
  }

  init(system: any SystemActionExecutorSystem) {
    self.system = system
  }

  /// This check never asks macOS to display its Accessibility permission prompt.
  public var isAccessibilityTrusted: Bool {
    system.isAccessibilityTrusted
  }

  /// Validates an invocation without performing it or prompting for permission.
  public func validate(_ invocation: ActionInvocation) throws {
    switch invocation.action {
    case .shortcut(let shortcut):
      _ = try Self.keyCode(for: shortcut.key)
      guard shortcut.repeatCount > 0 else {
        throw SystemActionExecutorError.invalidShortcutRepeatCount(
          shortcut.repeatCount
        )
      }

    case .application(let application):
      guard !application.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !application.bundleID.contains("\0")
      else {
        throw SystemActionExecutorError.invalidApplicationBundleID
      }
      guard
        system.applicationURL(bundleIdentifier: application.bundleID) != nil
      else {
        throw SystemActionExecutorError.applicationNotFound(application.bundleID)
      }

    case .executable(let executable):
      guard executable.executable.hasPrefix("/"),
        !executable.executable.contains("\0")
      else {
        throw SystemActionExecutorError.executablePathMustBeAbsolute(
          executable.executable
        )
      }
      guard executable.argv.allSatisfy({ !$0.contains("\0") }) else {
        throw SystemActionExecutorError.invalidExecutableArgument
      }
      guard system.fileExists(atPath: executable.executable) else {
        throw SystemActionExecutorError.executableNotFound(executable.executable)
      }
      guard system.isExecutableFile(atPath: executable.executable) else {
        throw SystemActionExecutorError.executableNotRunnable(executable.executable)
      }

    case .url(let urlAction):
      let url = urlAction.url
      guard url.scheme != nil,
        url.baseURL == nil,
        !url.absoluteString.contains("\0")
      else {
        throw SystemActionExecutorError.urlMustBeAbsolute(url.absoluteString)
      }
      guard system.applicationURL(toOpen: url) != nil else {
        throw SystemActionExecutorError.urlHandlerNotFound(url.scheme ?? "")
      }

    case .spotify(let spotify):
      switch spotify.playback {
      case .play:
        try validateApplication(bundleIdentifier: Self.spotifyBundleIdentifier)
      }
    }
  }

  public func execute(_ invocation: ActionInvocation) throws {
    try validate(invocation)

    switch invocation.action {
    case .shortcut(let shortcut):
      try execute(shortcut)
    case .application(let application):
      try launch(application)
    case .executable(let executable):
      try launch(executable)
    case .url(let urlAction):
      try open(urlAction)
    case .spotify(let spotify):
      try execute(spotify)
    }
  }

  private func execute(_ shortcut: ShortcutAction) throws {
    guard isAccessibilityTrusted else {
      throw SystemActionExecutorError.accessibilityPermissionRequired
    }

    let keyCode = try Self.keyCode(for: shortcut.key)
    let flags = Self.eventFlags(for: shortcut.modifiers)
    for index in 0..<shortcut.repeatCount {
      try system.postKeyStroke(keyCode: keyCode, flags: flags)
      if index < shortcut.repeatCount - 1 {
        system.wait(
          milliseconds: Int(
            shortcut.interTapDelayMilliseconds ?? Self.defaultInterTapDelayMilliseconds
          )
        )
      }
    }
  }

  private func launch(_ application: ApplicationAction) throws {
    guard
      let url = system.applicationURL(bundleIdentifier: application.bundleID)
    else {
      throw SystemActionExecutorError.applicationNotFound(application.bundleID)
    }

    system.openApplication(at: url)
  }

  private func launch(_ executable: ExecutableAction) throws {
    do {
      try system.launch(executable: executable)
    } catch {
      throw SystemActionExecutorError.processLaunchFailed(
        executable.executable,
        reason: error.localizedDescription
      )
    }
  }

  private func open(_ urlAction: URLAction) throws {
    guard system.open(urlAction.url) else {
      throw SystemActionExecutorError.urlOpenFailed(
        urlAction.url.absoluteString
      )
    }
  }

  private func execute(_ spotify: SpotifyAction) throws {
    switch spotify.playback {
    case .play:
      let bundleIdentifier = Self.spotifyBundleIdentifier
      if !system.isApplicationRunning(bundleIdentifier: bundleIdentifier) {
        guard let applicationURL = system.applicationURL(bundleIdentifier: bundleIdentifier) else {
          throw SystemActionExecutorError.applicationNotFound(bundleIdentifier)
        }
        system.openApplication(at: applicationURL)
        var didStart = false
        for _ in 0..<Self.applicationLaunchPollCount {
          if system.isApplicationRunning(bundleIdentifier: bundleIdentifier) {
            didStart = true
            break
          }
          system.wait(milliseconds: Self.applicationLaunchPollMilliseconds)
        }
        guard didStart else {
          throw SystemActionExecutorError.applicationLaunchTimedOut(
            bundleIdentifier
          )
        }
      }

      do {
        try system.sendAppleEvent(
          bundleIdentifier: bundleIdentifier,
          eventClass: Self.spotifyEventClass,
          eventID: Self.spotifyPlayEventID
        )
      } catch {
        throw SystemActionExecutorError.appleEventFailed(
          bundleIdentifier,
          reason: error.localizedDescription
        )
      }
    }
  }

  private func validateApplication(bundleIdentifier: String) throws {
    guard system.applicationURL(bundleIdentifier: bundleIdentifier) != nil else {
      throw SystemActionExecutorError.applicationNotFound(bundleIdentifier)
    }
  }

  private static func eventFlags(for modifiers: [KeyboardModifier]) -> CGEventFlags {
    modifiers.reduce(into: CGEventFlags()) { flags, modifier in
      switch modifier {
      case .command:
        flags.insert(.maskCommand)
      case .control:
        flags.insert(.maskControl)
      case .option:
        flags.insert(.maskAlternate)
      case .shift:
        flags.insert(.maskShift)
      case .function:
        flags.insert(.maskSecondaryFn)
      }
    }
  }

  private static func keyCode(for key: String) throws -> CGKeyCode {
    let normalized = key.lowercased()
    guard let keyCode = keyCodes[normalized] else {
      throw SystemActionExecutorError.unsupportedShortcutKey(key)
    }
    return keyCode
  }

  private static let defaultInterTapDelayMilliseconds: UInt32 = 80
  private static let applicationLaunchPollCount = 50
  private static let applicationLaunchPollMilliseconds = 100
  private static let spotifyBundleIdentifier = "com.spotify.client"

  // Spotify's scripting definition declares `play` as the `spfy` / `Play`
  // Apple Event. Sending it directly keeps this integration narrow and avoids
  // invoking a shell or a general-purpose script interpreter.
  private static let spotifyEventClass: AEEventClass = 0x7370_6679
  private static let spotifyPlayEventID: AEEventID = 0x506C_6179

  // ANSI key positions used by CGEvent. Uppercase is expressed with the Shift
  // modifier rather than as a separate key name.
  private static let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "equal": 24, "9": 25, "7": 26, "-": 27,
    "minus": 27, "8": 28, "0": 29, "]": 30, "rightbracket": 30, "o": 31,
    "u": 32, "[": 33, "leftbracket": 33, "i": 34, "p": 35, "return": 36,
    "enter": 36, "l": 37, "j": 38, "'": 39, "apostrophe": 39, "k": 40,
    ";": 41, "semicolon": 41, "\\": 42, "backslash": 42, ",": 43,
    "comma": 43, "/": 44, "slash": 44, "n": 45, "m": 46, ".": 47,
    "period": 47, "tab": 48, "space": 49, "`": 50, "grave": 50,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "fn": 63, "function": 63, "f17": 64,
    "decimal": 65, "multiply": 67, "plus": 69, "clear": 71, "divide": 75,
    "enterkeypad": 76, "subtract": 78, "f18": 79, "f19": 80, "f20": 90,
    "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
    "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109,
    "f12": 111, "f15": 113, "help": 114, "home": 115, "pageup": 116,
    "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120,
    "pagedown": 121, "f1": 122, "left": 123, "right": 124, "down": 125,
    "up": 126,
  ]
}

public enum SystemActionExecutorError: Error, Equatable, Sendable {
  case accessibilityPermissionRequired
  case unsupportedShortcutKey(String)
  case invalidShortcutRepeatCount(Int)
  case keyboardEventCreationFailed
  case invalidApplicationBundleID
  case applicationNotFound(String)
  case applicationLaunchTimedOut(String)
  case executablePathMustBeAbsolute(String)
  case invalidExecutableArgument
  case executableNotFound(String)
  case executableNotRunnable(String)
  case processLaunchFailed(String, reason: String)
  case urlMustBeAbsolute(String)
  case urlHandlerNotFound(String)
  case urlOpenFailed(String)
  case appleEventFailed(String, reason: String)
}

extension SystemActionExecutorError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .accessibilityPermissionRequired:
      "Accessibility permission is required to send keyboard shortcuts."
    case .unsupportedShortcutKey(let key):
      "Unsupported shortcut key \(key.debugDescription)."
    case .invalidShortcutRepeatCount(let count):
      "Shortcut repeat count must be positive; got \(count)."
    case .keyboardEventCreationFailed:
      "macOS could not create the shortcut keyboard events."
    case .invalidApplicationBundleID:
      "Application bundle ID must not be empty or contain a null byte."
    case .applicationNotFound(let bundleID):
      "No installed application has bundle ID \(bundleID.debugDescription)."
    case .applicationLaunchTimedOut(let bundleID):
      "Application \(bundleID.debugDescription) did not finish launching in time."
    case .executablePathMustBeAbsolute(let path):
      "Executable path must be absolute: \(path.debugDescription)."
    case .invalidExecutableArgument:
      "Executable argv contains a null byte."
    case .executableNotFound(let path):
      "Executable does not exist: \(path.debugDescription)."
    case .executableNotRunnable(let path):
      "File is not executable: \(path.debugDescription)."
    case .processLaunchFailed(let path, let reason):
      "Could not launch \(path.debugDescription): \(reason)"
    case .urlMustBeAbsolute(let url):
      "URL action must use an absolute URL: \(url.debugDescription)."
    case .urlHandlerNotFound(let scheme):
      "No installed application handles the \(scheme.debugDescription) URL scheme."
    case .urlOpenFailed(let url):
      "macOS could not open URL \(url.debugDescription)."
    case .appleEventFailed(let bundleIdentifier, let reason):
      "Could not send an Apple Event to \(bundleIdentifier.debugDescription): \(reason)"
    }
  }
}
