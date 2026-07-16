/// Deterministic scenario runner used by tests, recordings, and future CLI tooling.
public enum RingSimulation {
  public static func run(
    configuration: MouseConfiguration,
    profile: RingInteractionProfile = .default,
    inputs: [RingInput]
  ) throws -> [RingTransition] {
    var machine = try RingInteractionMachine(
      configuration: configuration,
      profile: profile
    )
    return inputs.map { machine.handle($0) }
  }
}
