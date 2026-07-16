import Darwin
import Foundation
import LogiLiquidJim

@main
enum JimMain {
  @MainActor
  static func main() async {
    let exitCode = await JimCLI().run(
      arguments: Array(CommandLine.arguments.dropFirst())
    )
    if exitCode != 0 {
      Darwin.exit(exitCode)
    }
  }
}
