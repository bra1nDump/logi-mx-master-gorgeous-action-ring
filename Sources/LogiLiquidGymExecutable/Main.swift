import Darwin
import Foundation
import LogiLiquidGym

@main
enum GymMain {
  @MainActor
  static func main() async {
    let exitCode = await GymCLI().run(
      arguments: Array(CommandLine.arguments.dropFirst())
    )
    if exitCode != 0 {
      Darwin.exit(exitCode)
    }
  }
}
