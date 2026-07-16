import Foundation

/// Timestamped stderr logging for the overlay process. When the overlay runs
/// as the installed LaunchAgent, launchd redirects this stream to
/// `~/Library/Application Support/Logi Liquid Controls/logs/overlay.error.log`,
/// which is the first place to look when the daemon hides the cursor but no
/// ring appears.
enum OverlayLog {
  private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  static func log(_ message: String) {
    let line = "\(Date().formatted(timestampStyle)) logi-liquid-overlay: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}
