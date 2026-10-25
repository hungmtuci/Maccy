// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Maccy",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Maccy", targets: ["Maccy"])
  ],
  dependencies: [
    .package(url: "https://github.com/sindresorhus/Defaults", exact: "8.2.0"),
    .package(url: "https://github.com/krisk/fuse-swift", exact: "1.4.0"),
    .package(path: "LocalPackages/KeyboardShortcuts"),
    .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", exact: "1.1.0"),
    .package(url: "https://github.com/Clipy/Sauce", exact: "2.5.2"),
    .package(url: "https://github.com/sindresorhus/Settings.git", exact: "3.1.2"),
    .package(url: "https://github.com/apple/swift-log", exact: "1.6.2"),
    .package(url: "https://github.com/thii/SwiftHEXColors", exact: "1.4.1")
  ],
  targets: [
    .executableTarget(
      name: "Maccy",
      dependencies: [
        .product(name: "Defaults", package: "Defaults"),
        .product(name: "Fuse", package: "fuse-swift"),
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
        .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
        .product(name: "Sauce", package: "Sauce"),
        .product(name: "Settings", package: "Settings"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "SwiftHEXColors", package: "SwiftHEXColors")
      ],
      path: "Maccy",
      exclude: [
        "Assets.xcassets",
        "AppIcon.icon",
        "GlobalHotKey.swift",
        "History.xcdatamodeld",
        "Storage.xcdatamodeld",
        "Info.plist",
        "Maccy.entitlements",
        "Sounds"
      ],
      swiftSettings: [
        .defaultIsolation(MainActor.self)
      ]
    )
  ]
)
