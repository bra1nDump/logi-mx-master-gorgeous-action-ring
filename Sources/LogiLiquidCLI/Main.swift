import Darwin

@main
public enum LogiLiquidCLIMain {
  public static func main() {
    let code = LogiLiquidCLI().run(
      arguments: Array(CommandLine.arguments.dropFirst())
    )
    Darwin.exit(code.rawValue)
  }
}
