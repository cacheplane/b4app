// swift-tools-version: 6.2
import PackageDescription

// Approachable concurrency on every target (Swift 6 language mode is set package-wide).
let concurrency: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]
// UI code defaults to the main actor; libraries, the daemon, and the CLI stay nonisolated.
let mainActorDefault: [SwiftSetting] = concurrency + [.defaultIsolation(MainActor.self)]

let package = Package(
  name: "b4app",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "WorkspaceProtocol", targets: ["WorkspaceProtocol"]),
    .library(name: "WorkspaceClient", targets: ["WorkspaceClient"]),
    .library(name: "WorkspacePlatform", targets: ["WorkspacePlatform"]),
    .library(name: "WorkspaceStorage", targets: ["WorkspaceStorage"]),
    .library(name: "CodexAdapter", targets: ["CodexAdapter"]),
    .library(name: "ClaudeAdapter", targets: ["ClaudeAdapter"]),
    .library(name: "B4Adapter", targets: ["B4Adapter"]),
    .library(name: "Coordinator", targets: ["Coordinator"]),
    .library(name: "NIOTransport", targets: ["NIOTransport"]),
    .library(name: "WorkspaceUI", targets: ["WorkspaceUI"]),
    .executable(name: "b4app-coordinator", targets: ["CoordinatorMain"]),
    .executable(name: "agent-workspace", targets: ["AgentWorkspaceCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.35.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
  ],
  targets: [
    // Runtime-neutral: Foundation only, links on iOS.
    .target(name: "WorkspaceProtocol", swiftSettings: concurrency),
    .target(name: "WorkspaceClient", dependencies: ["WorkspaceProtocol"], swiftSettings: concurrency),

    // macOS-only infrastructure.
    .target(
      name: "WorkspacePlatform",
      dependencies: [
        "WorkspaceProtocol",
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      swiftSettings: concurrency),
    .target(
      name: "WorkspaceStorage",
      dependencies: ["WorkspaceProtocol", .product(name: "GRDB", package: "GRDB.swift")],
      swiftSettings: concurrency),
    .target(
      name: "NIOTransport",
      dependencies: [
        "WorkspaceProtocol", "WorkspaceClient",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOExtras", package: "swift-nio-extras"),
      ],
      swiftSettings: concurrency),

    // Adapters translate native protocols into app commands and events.
    .target(
      name: "CodexAdapter", dependencies: ["WorkspaceProtocol", "WorkspacePlatform"],
      swiftSettings: concurrency),
    .target(
      name: "ClaudeAdapter", dependencies: ["WorkspaceProtocol", "WorkspacePlatform"],
      swiftSettings: concurrency),
    .target(
      name: "B4Adapter", dependencies: ["WorkspaceProtocol", "WorkspacePlatform"], swiftSettings: concurrency),

    // The coordinator: one per user, owns SQLite, serves GUI and CLI over a Unix socket.
    .target(
      name: "Coordinator",
      dependencies: [
        "WorkspaceProtocol", "WorkspaceClient", "WorkspacePlatform", "WorkspaceStorage",
        "CodexAdapter", "ClaudeAdapter", "B4Adapter", "NIOTransport",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOExtras", package: "swift-nio-extras"),
      ],
      swiftSettings: concurrency),
    .executableTarget(name: "CoordinatorMain", dependencies: ["Coordinator"], swiftSettings: concurrency),
    .executableTarget(
      name: "AgentWorkspaceCLI",
      dependencies: [
        "WorkspaceProtocol", "WorkspaceClient", "WorkspacePlatform", "Coordinator", "NIOTransport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: concurrency),

    // SwiftUI shared by the macOS and iOS apps.
    .target(
      name: "WorkspaceUI", dependencies: ["WorkspaceProtocol", "WorkspaceClient"],
      resources: [.copy("Resources/Fonts"), .copy("Resources/Brand")],
      swiftSettings: mainActorDefault),

    // Tests.
    .testTarget(
      name: "WorkspaceProtocolTests", dependencies: ["WorkspaceProtocol"], swiftSettings: concurrency),
    .testTarget(name: "WorkspaceClientTests", dependencies: ["WorkspaceClient"], swiftSettings: concurrency),
    .testTarget(
      name: "WorkspacePlatformTests", dependencies: ["WorkspacePlatform"], swiftSettings: concurrency),
    .testTarget(
      name: "WorkspaceStorageTests", dependencies: ["WorkspaceStorage"], swiftSettings: concurrency),
    .testTarget(
      name: "CodexAdapterTests", dependencies: ["CodexAdapter"], exclude: ["Fixtures"],
      swiftSettings: concurrency),
    .testTarget(
      name: "ClaudeAdapterTests", dependencies: ["ClaudeAdapter"], exclude: ["Fixtures"],
      swiftSettings: concurrency),
    .testTarget(
      name: "B4AdapterTests", dependencies: ["B4Adapter"], exclude: ["Fixtures"], swiftSettings: concurrency),
    .testTarget(
      name: "CoordinatorTests", dependencies: ["Coordinator", "NIOTransport"], swiftSettings: concurrency),
    // Model-level tests of the shared UI against a real in-process coordinator (macOS only).
    .testTarget(
      name: "WorkspaceUITests", dependencies: ["WorkspaceUI", "Coordinator", "NIOTransport"],
      swiftSettings: mainActorDefault),
  ],
  swiftLanguageModes: [.v6]
)
