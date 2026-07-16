import Foundation

public enum CardinalZone: String, Codable, CaseIterable, Equatable, Sendable {
  case top
  case right
  case bottom
  case left

  /// Stable clockwise order used by configuration output and geometry.
  public static let clockwiseOrder: [CardinalZone] = [.top, .right, .bottom, .left]
}

/// Ordered action names for each cardinal area of the ring.
///
/// The explicit fields are intentional: encoded configuration always retains all
/// four zones, including an empty `bottom` application area.
public struct RingZones: Codable, Equatable, Sendable {
  public var top: [String]
  public var right: [String]
  public var bottom: [String]
  public var left: [String]

  public init(
    top: [String] = [],
    right: [String] = [],
    bottom: [String] = [],
    left: [String] = []
  ) {
    self.top = top
    self.right = right
    self.bottom = bottom
    self.left = left
  }

  private enum CodingKeys: String, CodingKey {
    case top
    case right
    case bottom
    case left
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      top: try container.decodeIfPresent([String].self, forKey: .top) ?? [],
      right: try container.decodeIfPresent([String].self, forKey: .right) ?? [],
      bottom: try container.decodeIfPresent([String].self, forKey: .bottom) ?? [],
      left: try container.decodeIfPresent([String].self, forKey: .left) ?? []
    )
  }

  public subscript(zone: CardinalZone) -> [String] {
    get {
      switch zone {
      case .top: top
      case .right: right
      case .bottom: bottom
      case .left: left
      }
    }
    set {
      switch zone {
      case .top: top = newValue
      case .right: right = newValue
      case .bottom: bottom = newValue
      case .left: left = newValue
      }
    }
  }

  public var actionCount: Int {
    top.count + right.count + bottom.count + left.count
  }

  public var actionNamesClockwise: [String] {
    CardinalZone.clockwiseOrder.flatMap { self[$0] }
  }

  /// Maps the old equally-spaced clockwise ring to its nearest cardinal sectors.
  /// Ordering within each resulting sector stays stable.
  public init(migratingLegacyRing actionNames: [String]) {
    self.init()
    guard !actionNames.isEmpty else { return }

    for (index, name) in actionNames.enumerated() {
      let clockwiseTurns = Double(index) / Double(actionNames.count)
      let quadrant = Int(floor((clockwiseTurns * 4) + 0.5)) % 4
      self[CardinalZone.clockwiseOrder[quadrant]].append(name)
    }
  }

  fileprivate mutating func removeAllOccurrences(of name: String) {
    for zone in CardinalZone.clockwiseOrder {
      self[zone].removeAll { $0 == name }
    }
  }
}

/// An application override can only populate the bottom zone by construction.
public struct ApplicationSpecificActions: Codable, Equatable, Sendable {
  public var bottom: [String]

  public init(bottom: [String] = []) {
    self.bottom = bottom
  }
}

/// Typed application identity captured at the moment the ring is invoked.
public struct FrontmostApplicationContext: Codable, Equatable, Sendable {
  public var bundleID: String?
  public var localizedName: String?

  public init(bundleID: String?, localizedName: String? = nil) {
    self.bundleID = bundleID
    self.localizedName = localizedName
  }

  public static let unknown = FrontmostApplicationContext(bundleID: nil)
}

/// The immutable action order selected for one invocation.
public struct ResolvedMouseConfiguration: Codable, Equatable, Sendable {
  public let context: FrontmostApplicationContext
  public let actions: [String: ConfiguredAction]
  public let zones: RingZones

  public init(
    context: FrontmostApplicationContext,
    actions: [String: ConfiguredAction],
    zones: RingZones
  ) {
    self.context = context
    self.actions = actions
    self.zones = zones
  }
}

/// The complete user-authored configuration consumed by the headless mouse service.
public struct MouseConfiguration: Equatable, Sendable {
  public static let currentVersion = 2

  /// The requested first-run layout. It contains only executable actions; the
  /// bottom application-specific area stays present in zone metadata but empty.
  public static let logiLiquidDefault = MouseConfiguration(
    actions: [
      "Play Spotify": .spotify(SpotifyAction(playback: .play)),
      "Telegram": .application(ApplicationAction(bundleID: "ru.keepcoder.Telegram")),
      "ChatGPT Quick Chat": .shortcut(
        ShortcutAction(key: "space", modifiers: [.option])
      ),
      "Aqua Voice": .shortcut(
        ShortcutAction(key: "fn", repeatCount: 2)
      ),
      "CleanShot Capture": .url(
        URLAction(url: URL(string: "cleanshot://capture-area")!)
      ),
      "CleanShot Record": .url(
        URLAction(url: URL(string: "cleanshot://record-screen")!)
      ),
    ],
    zones: RingZones(
      top: ["Play Spotify"],
      right: ["Telegram", "ChatGPT Quick Chat"],
      bottom: [],
      left: ["Aqua Voice", "CleanShot Capture", "CleanShot Record"]
    )
  )

  public var version: Int
  public var actions: [String: ConfiguredAction]
  public var zones: RingZones
  public var applicationSpecific: [String: ApplicationSpecificActions]

  public init(
    version: Int = MouseConfiguration.currentVersion,
    actions: [String: ConfiguredAction] = [:],
    zones: RingZones = RingZones(),
    applicationSpecific: [String: ApplicationSpecificActions] = [:]
  ) {
    self.version = version
    self.actions = actions
    self.zones = zones
    self.applicationSpecific = applicationSpecific
  }

  /// Source-compatible construction for v1 callers. New code should pass `zones`.
  public init(
    version: Int = MouseConfiguration.currentVersion,
    actions: [String: ConfiguredAction],
    ring: [String]
  ) {
    self.init(
      version: version,
      actions: actions,
      zones: RingZones(migratingLegacyRing: ring)
    )
  }

  /// Flattened compatibility view for old status and diagnostics callers.
  public var ring: [String] {
    zones.actionNamesClockwise
  }

  public func validate() throws {
    guard version == Self.currentVersion else {
      throw ConfigurationError.unsupportedVersion(
        found: version,
        supported: Self.currentVersion
      )
    }

    for (name, action) in actions {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ConfigurationError.emptyActionName
      }
      guard !name.contains("\0") else {
        throw ConfigurationError.invalidActionName(name)
      }
      try action.validate(named: name)
    }

    var baseSeen = Set<String>()
    for zone in CardinalZone.clockwiseOrder {
      for name in zones[zone] {
        try validateReference(name)
        guard baseSeen.insert(name).inserted else {
          throw ConfigurationError.duplicateZoneAction(name)
        }
      }
    }

    for (bundleID, applicationActions) in applicationSpecific {
      guard Self.isValidBundleID(bundleID) else {
        throw ConfigurationError.invalidApplicationSpecificBundleID(bundleID)
      }
      var seen = Set<String>()
      for name in applicationActions.bottom {
        try validateReference(name)
        guard seen.insert(name).inserted else {
          throw ConfigurationError.duplicateApplicationAction(
            name: name,
            bundleID: bundleID
          )
        }
      }
    }
  }

  /// Resolves the bottom zone exactly once at invocation. A matching application
  /// override replaces the default bottom order; all other zones remain global.
  public func resolved(
    for context: FrontmostApplicationContext
  ) throws -> ResolvedMouseConfiguration {
    try validate()
    var resolvedZones = zones
    if let bundleID = context.bundleID,
      let applicationActions = applicationSpecific[bundleID]
    {
      resolvedZones.bottom = applicationActions.bottom
    }
    return ResolvedMouseConfiguration(
      context: context,
      actions: actions,
      zones: resolvedZones
    )
  }

  /// Creates or replaces an action and gives it one ordered placement.
  /// Application-specific placements are accepted only in the bottom zone.
  public mutating func putAction(
    named name: String,
    action: ConfiguredAction,
    zone: CardinalZone = .top,
    whenApplication bundleID: String? = nil
  ) throws {
    var candidate = self
    candidate.actions[name] = action

    if let bundleID {
      guard zone == .bottom else {
        throw ConfigurationMutationError.applicationSpecificActionsRequireBottomZone(zone)
      }
      guard Self.isValidBundleID(bundleID) else {
        throw ConfigurationError.invalidApplicationSpecificBundleID(bundleID)
      }
      var applicationActions =
        candidate.applicationSpecific[bundleID]
        ?? ApplicationSpecificActions()
      if !applicationActions.bottom.contains(name) {
        applicationActions.bottom.append(name)
      }
      candidate.applicationSpecific[bundleID] = applicationActions
    } else if !candidate.zones[zone].contains(name) {
      candidate.zones.removeAllOccurrences(of: name)
      candidate.zones[zone].append(name)
    }

    try candidate.validate()
    self = candidate
  }

  /// Removes the action payload and every global/application-specific reference.
  @discardableResult
  public mutating func removeAction(named name: String) -> Bool {
    guard actions.removeValue(forKey: name) != nil else {
      return false
    }
    zones.removeAllOccurrences(of: name)
    for bundleID in applicationSpecific.keys {
      applicationSpecific[bundleID]?.bottom.removeAll { $0 == name }
    }
    return true
  }

  /// Removes one placement while retaining the shared action payload and every
  /// other global or application-specific reference. An application-specific
  /// removal preserves an empty override because empty means "show no bottom
  /// actions for this application," not "fall back to the global bottom zone."
  @discardableResult
  public mutating func removeActionPlacement(
    named name: String,
    from zone: CardinalZone,
    whenApplication bundleID: String? = nil
  ) throws -> Bool {
    if let bundleID {
      guard zone == .bottom else {
        throw ConfigurationMutationError.applicationSpecificActionsRequireBottomZone(zone)
      }
      guard Self.isValidBundleID(bundleID) else {
        throw ConfigurationError.invalidApplicationSpecificBundleID(bundleID)
      }
      guard var applicationActions = applicationSpecific[bundleID],
        let index = applicationActions.bottom.firstIndex(of: name)
      else {
        return false
      }
      applicationActions.bottom.remove(at: index)
      applicationSpecific[bundleID] = applicationActions
      return true
    }

    guard let index = zones[zone].firstIndex(of: name) else {
      return false
    }
    zones[zone].remove(at: index)
    return true
  }

  /// Persists an explicit empty bottom override for one application. This does
  /// not delete action payloads or placements belonging to any other scope.
  @discardableResult
  public mutating func clearApplicationOverride(
    for bundleID: String
  ) throws -> Bool {
    guard Self.isValidBundleID(bundleID) else {
      throw ConfigurationError.invalidApplicationSpecificBundleID(bundleID)
    }
    if applicationSpecific[bundleID]?.bottom.isEmpty == true {
      return false
    }
    applicationSpecific[bundleID] = ApplicationSpecificActions()
    return true
  }

  /// Compatibility move for a globally placed action, within its current zone.
  public mutating func moveAction(named name: String, to destinationIndex: Int) throws {
    guard let zone = CardinalZone.clockwiseOrder.first(where: { zones[$0].contains(name) }) else {
      throw ConfigurationMutationError.actionNotInRing(name)
    }
    try moveAction(named: name, in: zone, to: destinationIndex)
  }

  /// Moves an action within one ordered zone or one application's bottom override.
  public mutating func moveAction(
    named name: String,
    in zone: CardinalZone,
    to destinationIndex: Int,
    whenApplication bundleID: String? = nil
  ) throws {
    if let bundleID {
      guard zone == .bottom else {
        throw ConfigurationMutationError.applicationSpecificActionsRequireBottomZone(zone)
      }
      guard var applicationActions = applicationSpecific[bundleID],
        let sourceIndex = applicationActions.bottom.firstIndex(of: name)
      else {
        throw ConfigurationMutationError.actionNotInApplicationZone(
          name: name,
          bundleID: bundleID
        )
      }
      try Self.move(
        name: name,
        from: sourceIndex,
        to: destinationIndex,
        in: &applicationActions.bottom
      )
      applicationSpecific[bundleID] = applicationActions
      return
    }

    guard let sourceIndex = zones[zone].firstIndex(of: name) else {
      throw ConfigurationMutationError.actionNotInZone(name: name, zone: zone)
    }
    var names = zones[zone]
    try Self.move(name: name, from: sourceIndex, to: destinationIndex, in: &names)
    zones[zone] = names
  }

  private func validateReference(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.emptyZoneEntry
    }
    guard actions[name] != nil else {
      throw ConfigurationError.unknownZoneAction(name)
    }
  }

  private static func isValidBundleID(_ bundleID: String) -> Bool {
    !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !bundleID.contains("\0")
  }

  private static func move(
    name: String,
    from sourceIndex: Int,
    to destinationIndex: Int,
    in names: inout [String]
  ) throws {
    guard names.indices.contains(destinationIndex) else {
      throw ConfigurationMutationError.destinationOutOfBounds(
        destinationIndex,
        actionCount: names.count
      )
    }
    guard sourceIndex != destinationIndex else { return }
    names.remove(at: sourceIndex)
    names.insert(name, at: destinationIndex)
  }
}

extension MouseConfiguration: Codable {
  private enum CodingKeys: String, CodingKey {
    case version
    case actions
    case ring
    case zones
    case applicationSpecific
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    let decodedActions =
      try container.decodeIfPresent(
        [String: ConfiguredAction].self,
        forKey: .actions
      ) ?? [:]

    if decodedVersion == 1 {
      self.init(
        actions: decodedActions,
        zones: RingZones(
          migratingLegacyRing: try container.decodeIfPresent([String].self, forKey: .ring) ?? []
        )
      )
    } else if decodedVersion != Self.currentVersion {
      // Preserve the version so validation can produce the stable, actionable
      // unsupported-version error without attempting to interpret its schema.
      self.init(version: decodedVersion, actions: decodedActions)
    } else {
      self.init(
        version: decodedVersion,
        actions: decodedActions,
        zones: try container.decodeIfPresent(RingZones.self, forKey: .zones) ?? RingZones(),
        applicationSpecific: try container.decodeIfPresent(
          [String: ApplicationSpecificActions].self,
          forKey: .applicationSpecific
        ) ?? [:]
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(actions, forKey: .actions)
    try container.encode(zones, forKey: .zones)
    try container.encode(applicationSpecific, forKey: .applicationSpecific)
  }
}

public enum ConfiguredAction: Equatable, Sendable {
  case shortcut(ShortcutAction)
  case application(ApplicationAction)
  case executable(ExecutableAction)
  case url(URLAction)
  case spotify(SpotifyAction)

  fileprivate func validate(named name: String) throws {
    switch self {
    case .shortcut(let shortcut):
      guard !shortcut.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !shortcut.key.contains("\0")
      else {
        throw ConfigurationError.invalidShortcutKey(action: name)
      }
      guard shortcut.repeatCount > 0 else {
        throw ConfigurationError.invalidShortcutRepeatCount(action: name)
      }

      var modifiers = Set<KeyboardModifier>()
      for modifier in shortcut.modifiers {
        guard modifiers.insert(modifier).inserted else {
          throw ConfigurationError.duplicateShortcutModifier(
            action: name,
            modifier: modifier
          )
        }
      }

    case .application(let application):
      guard !application.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !application.bundleID.contains("\0")
      else {
        throw ConfigurationError.invalidApplicationBundleID(action: name)
      }

    case .executable(let executable):
      guard executable.executable.hasPrefix("/"),
        !executable.executable.contains("\0")
      else {
        throw ConfigurationError.executablePathMustBeAbsolute(action: name)
      }
      guard executable.argv.allSatisfy({ !$0.contains("\0") }) else {
        throw ConfigurationError.invalidExecutableArgument(action: name)
      }

    case .url(let urlAction):
      guard urlAction.url.scheme != nil,
        urlAction.url.baseURL == nil,
        !urlAction.url.absoluteString.contains("\0")
      else {
        throw ConfigurationError.urlMustBeAbsolute(action: name)
      }

    case .spotify:
      break
    }
  }
}

public struct ShortcutAction: Codable, Equatable, Sendable {
  public var key: String
  public var modifiers: [KeyboardModifier]
  public var repeatCount: Int
  public var interTapDelayMilliseconds: UInt32?

  public init(
    key: String,
    modifiers: [KeyboardModifier] = [],
    repeatCount: Int = 1,
    interTapDelayMilliseconds: UInt32? = nil
  ) {
    self.key = key
    self.modifiers = modifiers
    self.repeatCount = repeatCount
    self.interTapDelayMilliseconds = interTapDelayMilliseconds
  }

  private enum CodingKeys: String, CodingKey {
    case key
    case modifiers
    case repeatCount
    case interTapDelayMilliseconds
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      key: try container.decode(String.self, forKey: .key),
      modifiers: try container.decodeIfPresent([KeyboardModifier].self, forKey: .modifiers) ?? [],
      repeatCount: try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1,
      interTapDelayMilliseconds: try container.decodeIfPresent(
        UInt32.self,
        forKey: .interTapDelayMilliseconds
      )
    )
  }
}

public enum KeyboardModifier: String, Codable, CaseIterable, Hashable, Sendable {
  case command
  case control
  case option
  case shift
  case function
}

public struct ApplicationAction: Codable, Equatable, Sendable {
  public var bundleID: String

  public init(bundleID: String) {
    self.bundleID = bundleID
  }
}

/// A direct process invocation. Executors must pass `executable` and `argv` to
/// `Process` as separate values; this model intentionally has no shell-command form.
public struct ExecutableAction: Codable, Equatable, Sendable {
  public var executable: String
  public var argv: [String]

  public init(executable: String, argv: [String] = []) {
    self.executable = executable
    self.argv = argv
  }
}

public struct URLAction: Codable, Equatable, Sendable {
  public var url: URL

  public init(url: URL) {
    self.url = url
  }
}

public enum SpotifyPlaybackCommand: String, Codable, Equatable, Sendable {
  case play
}

public struct SpotifyAction: Codable, Equatable, Sendable {
  public var playback: SpotifyPlaybackCommand

  public init(playback: SpotifyPlaybackCommand = .play) {
    self.playback = playback
  }
}

extension ConfiguredAction: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case key
    case modifiers
    case repeatCount
    case interTapDelayMilliseconds
    case bundleID
    case executable
    case argv
    case url
    case playback
  }

  private enum Kind: String, Codable {
    case shortcut
    case application
    case executable
    case url
    case spotify
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .type)

    switch kind {
    case .shortcut:
      self = .shortcut(
        ShortcutAction(
          key: try container.decode(String.self, forKey: .key),
          modifiers: try container.decodeIfPresent(
            [KeyboardModifier].self,
            forKey: .modifiers
          ) ?? [],
          repeatCount: try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1,
          interTapDelayMilliseconds: try container.decodeIfPresent(
            UInt32.self,
            forKey: .interTapDelayMilliseconds
          )
        )
      )
    case .application:
      self = .application(
        ApplicationAction(
          bundleID: try container.decode(String.self, forKey: .bundleID)
        )
      )
    case .executable:
      self = .executable(
        ExecutableAction(
          executable: try container.decode(String.self, forKey: .executable),
          argv: try container.decodeIfPresent([String].self, forKey: .argv) ?? []
        )
      )
    case .url:
      self = .url(
        URLAction(url: try container.decode(URL.self, forKey: .url))
      )
    case .spotify:
      self = .spotify(
        SpotifyAction(
          playback: try container.decodeIfPresent(
            SpotifyPlaybackCommand.self,
            forKey: .playback
          ) ?? .play
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .shortcut(let shortcut):
      try container.encode(Kind.shortcut, forKey: .type)
      try container.encode(shortcut.key, forKey: .key)
      try container.encode(shortcut.modifiers, forKey: .modifiers)
      try container.encode(shortcut.repeatCount, forKey: .repeatCount)
      try container.encodeIfPresent(
        shortcut.interTapDelayMilliseconds,
        forKey: .interTapDelayMilliseconds
      )
    case .application(let application):
      try container.encode(Kind.application, forKey: .type)
      try container.encode(application.bundleID, forKey: .bundleID)
    case .executable(let executable):
      try container.encode(Kind.executable, forKey: .type)
      try container.encode(executable.executable, forKey: .executable)
      try container.encode(executable.argv, forKey: .argv)
    case .url(let urlAction):
      try container.encode(Kind.url, forKey: .type)
      try container.encode(urlAction.url, forKey: .url)
    case .spotify(let spotify):
      try container.encode(Kind.spotify, forKey: .type)
      try container.encode(spotify.playback, forKey: .playback)
    }
  }
}

public enum ConfigurationError: Error, Equatable, Sendable {
  case nonFileURL(URL)
  case unsupportedVersion(found: Int, supported: Int)
  case emptyActionName
  case invalidActionName(String)
  case emptyZoneEntry
  case unknownZoneAction(String)
  case duplicateZoneAction(String)
  case invalidApplicationSpecificBundleID(String)
  case duplicateApplicationAction(name: String, bundleID: String)
  case invalidShortcutKey(action: String)
  case invalidShortcutRepeatCount(action: String)
  case duplicateShortcutModifier(action: String, modifier: KeyboardModifier)
  case invalidApplicationBundleID(action: String)
  case executablePathMustBeAbsolute(action: String)
  case invalidExecutableArgument(action: String)
  case urlMustBeAbsolute(action: String)
}

extension ConfigurationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .nonFileURL(let url):
      "Configuration URL must be a file URL: \(url.absoluteString)"
    case .unsupportedVersion(let found, let supported):
      "Unsupported configuration version \(found); this build supports version \(supported)."
    case .emptyActionName:
      "Action names must not be empty."
    case .invalidActionName(let name):
      "Action name contains an invalid null byte: \(name.debugDescription)"
    case .emptyZoneEntry:
      "Zone entries must name a configured action; empty action circles are omitted."
    case .unknownZoneAction(let name):
      "A zone references unknown action \(name.debugDescription)."
    case .duplicateZoneAction(let name):
      "Global action \(name.debugDescription) appears in more than one zone position."
    case .invalidApplicationSpecificBundleID(let bundleID):
      "Application-specific bundle ID is empty or invalid: \(bundleID.debugDescription)."
    case .duplicateApplicationAction(let name, let bundleID):
      "Application \(bundleID.debugDescription) repeats action \(name.debugDescription)."
    case .invalidShortcutKey(let action):
      "Shortcut action \(action.debugDescription) has an empty or invalid key."
    case .invalidShortcutRepeatCount(let action):
      "Shortcut action \(action.debugDescription) must have a positive repeat count."
    case .duplicateShortcutModifier(let action, let modifier):
      "Shortcut action \(action.debugDescription) repeats modifier \(modifier.rawValue)."
    case .invalidApplicationBundleID(let action):
      "Application action \(action.debugDescription) has an empty or invalid bundle ID."
    case .executablePathMustBeAbsolute(let action):
      "Executable action \(action.debugDescription) must use an absolute executable path."
    case .invalidExecutableArgument(let action):
      "Executable action \(action.debugDescription) contains an invalid null byte in argv."
    case .urlMustBeAbsolute(let action):
      "URL action \(action.debugDescription) must contain an absolute URL."
    }
  }
}

public enum ConfigurationMutationError: Error, Equatable, Sendable {
  case actionNotInRing(String)
  case actionNotInZone(name: String, zone: CardinalZone)
  case actionNotInApplicationZone(name: String, bundleID: String)
  case applicationSpecificActionsRequireBottomZone(CardinalZone)
  case destinationOutOfBounds(Int, actionCount: Int)
}

extension ConfigurationMutationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .actionNotInRing(let name):
      "Cannot move action \(name.debugDescription) because it is not in a global zone."
    case .actionNotInZone(let name, let zone):
      "Action \(name.debugDescription) is not in the \(zone.rawValue) zone."
    case .actionNotInApplicationZone(let name, let bundleID):
      "Action \(name.debugDescription) is not in the bottom zone for \(bundleID.debugDescription)."
    case .applicationSpecificActionsRequireBottomZone(let zone):
      "Application-specific actions use the bottom zone, not \(zone.rawValue)."
    case .destinationOutOfBounds(let index, let actionCount):
      "Zone index \(index) is out of bounds for \(actionCount) actions."
    }
  }
}
