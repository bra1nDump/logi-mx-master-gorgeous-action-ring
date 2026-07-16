/// A target icon is either a deterministic SF Symbol or the native icon of an
/// installed application, with an SF Symbol fallback.
public enum OverlayTargetIcon: Equatable, Sendable {
  case systemSymbol(String)
  case bundledTemplate(resourceName: String, fallbackSymbol: String)

  public var fallbackSymbolName: String {
    switch self {
    case .systemSymbol(let name): name
    case .bundledTemplate(_, let fallbackSymbol): fallbackSymbol
    }
  }
}

/// How one ring target is drawn: an icon, an accessible label, and whether it
/// is one of the built-in defaults or an agent-configured action.
public struct OverlayTargetPresentation: Equatable, Sendable {
  public let icon: OverlayTargetIcon
  /// The accessible label. It is always the configured action name, so a
  /// VoiceOver user hears exactly what will run.
  public let label: String
  /// `true` for the shipped defaults, `false` for anything the user or an agent
  /// configured, which receives the generic symbol.
  public let isKnownDefault: Bool

  public init(icon: OverlayTargetIcon, label: String, isKnownDefault: Bool) {
    self.icon = icon
    self.label = label
    self.isKnownDefault = isKnownDefault
  }

  /// Compatibility access for callers that only need a deterministic fallback.
  public var symbolName: String { icon.fallbackSymbolName }
}

/// Resolves target presentation from an action name. Known defaults get a
/// purpose-built symbol; everything else gets one shared generic symbol so
/// agent-configured actions read as a coherent, unbranded set.
public enum OverlayTargetSymbols {
  /// The symbol used for any action that is not a shipped default.
  public static let genericSymbol = "sparkles"

  /// Exact-name symbols for the shipped default layout.
  private static let knownIcons: [String: OverlayTargetIcon] = [
    "Play Spotify": .systemSymbol("play.fill"),
    "Telegram": .systemSymbol("paperplane.fill"),
    "ChatGPT Quick Chat": .bundledTemplate(
      resourceName: "OpenAIChatGPTMark",
      fallbackSymbol: "text.bubble.fill"
    ),
    "Aqua Voice": .systemSymbol("mic.fill"),
    "CleanShot Capture": .systemSymbol("camera.viewfinder"),
    "CleanShot Record": .systemSymbol("record.circle"),
  ]

  public static func presentation(forActionNamed name: String) -> OverlayTargetPresentation {
    if let icon = knownIcons[name] {
      return OverlayTargetPresentation(icon: icon, label: name, isKnownDefault: true)
    }
    return OverlayTargetPresentation(
      icon: .systemSymbol(genericSymbol),
      label: name,
      isKnownDefault: false
    )
  }
}
