// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "CommandBloom",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "LogiLiquidCore", targets: ["LogiLiquidCore"]),
    .library(name: "LogiLiquidHID", targets: ["LogiLiquidHID"]),
    .library(name: "LogiLiquidControl", targets: ["LogiLiquidControl"]),
    .library(name: "LogiLiquidService", targets: ["LogiLiquidService"]),
    .library(name: "LogiLiquidDaemon", targets: ["LogiLiquidDaemon"]),
    .library(name: "LogiLiquidUI", targets: ["LogiLiquidUI"]),
    .library(name: "LogiLiquidJim", targets: ["LogiLiquidJim"]),
    .executable(name: "logi-liquid", targets: ["LogiLiquidCLI"]),
    .executable(name: "logi-liquid-daemon", targets: ["LogiLiquidDaemonExecutable"]),
    .executable(name: "logi-liquid-daemon-fixture", targets: ["LogiLiquidDaemonFixture"]),
    .executable(name: "logi-liquid-overlay", targets: ["LogiLiquidOverlay"]),
    .executable(name: "jim", targets: ["LogiLiquidJimExecutable"]),
  ],
  targets: [
    .target(name: "LogiLiquidCore"),
    .target(
      name: "CLogiLiquidCursor",
      linkerSettings: [
        .linkedFramework("ApplicationServices")
      ]
    ),
    .target(
      name: "CLogiLiquidHID",
      cSettings: [
        .unsafeFlags(["-fblocks"])
      ],
      linkerSettings: [
        .linkedFramework("CoreFoundation"),
        .linkedFramework("IOKit"),
      ]
    ),
    .target(
      name: "LogiLiquidHID",
      dependencies: ["CLogiLiquidHID"]
    ),
    .target(name: "LogiLiquidControl"),
    .target(
      name: "LogiLiquidService",
      dependencies: ["CLogiLiquidCursor", "LogiLiquidCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
      ]
    ),
    .target(
      name: "LogiLiquidDaemon",
      dependencies: [
        "LogiLiquidControl",
        "LogiLiquidCore",
        "LogiLiquidHID",
        "LogiLiquidService",
      ]
    ),
    .executableTarget(
      name: "LogiLiquidCLI",
      dependencies: ["LogiLiquidControl", "LogiLiquidCore"]
    ),
    .executableTarget(
      name: "LogiLiquidDaemonExecutable",
      dependencies: ["LogiLiquidDaemon"]
    ),
    .executableTarget(
      name: "LogiLiquidDaemonFixture",
      dependencies: [
        "LogiLiquidControl",
        "LogiLiquidCore",
        "LogiLiquidDaemon",
        "LogiLiquidHID",
        "LogiLiquidService",
      ]
    ),
    .target(
      name: "LogiLiquidUI",
      dependencies: ["LogiLiquidCore"],
      resources: [.process("Resources")]
    ),
    .target(
      name: "LogiLiquidJim",
      dependencies: ["LogiLiquidCore", "LogiLiquidUI"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ImageIO"),
        .linkedFramework("ScreenCaptureKit"),
      ]
    ),
    .executableTarget(
      name: "LogiLiquidJimExecutable",
      dependencies: ["LogiLiquidJim"]
    ),
    .executableTarget(
      name: "LogiLiquidOverlay",
      dependencies: [
        "LogiLiquidUI",
        "LogiLiquidControl",
        "LogiLiquidCore",
      ]
    ),
    .testTarget(
      name: "LogiLiquidCoreTests",
      dependencies: ["LogiLiquidCore"]
    ),
    .testTarget(
      name: "LogiLiquidHIDTests",
      dependencies: ["LogiLiquidHID"]
    ),
    .testTarget(
      name: "LogiLiquidControlTests",
      dependencies: ["LogiLiquidControl"]
    ),
    .testTarget(
      name: "LogiLiquidServiceTests",
      dependencies: ["LogiLiquidCore", "LogiLiquidService"]
    ),
    .testTarget(
      name: "LogiLiquidCLITests",
      dependencies: ["LogiLiquidCLI", "LogiLiquidControl"]
    ),
    .testTarget(
      name: "LogiLiquidDaemonTests",
      dependencies: [
        "LogiLiquidControl",
        "LogiLiquidCore",
        "LogiLiquidDaemon",
        "LogiLiquidHID",
        "LogiLiquidService",
      ]
    ),
    .testTarget(
      name: "LogiLiquidUITests",
      dependencies: ["LogiLiquidUI", "LogiLiquidCore"]
    ),
    .testTarget(
      name: "LogiLiquidJimTests",
      dependencies: ["LogiLiquidJim", "LogiLiquidCore", "LogiLiquidUI"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
