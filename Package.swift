// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PodiumApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PodiumCore", targets: ["PodiumCore"]),
        .library(name: "PodiumServer", targets: ["PodiumServer"]),
        .executable(name: "podium-server", targets: ["PodiumServerCLI"]),
        .executable(name: "podium-hook", targets: ["PodiumHook"]),
        .executable(name: "PodiumApp", targets: ["PodiumApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        // System library wrapping the platform sqlite3 (apt libsqlite3-dev on
        // Linux, the system lib on macOS — no header needed via brew since
        // the macOS SDK already ships sqlite3.h).
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"])
            ]
        ),

        // Cross-platform (macOS + Linux) core: models, SQLite store, pricing,
        // hook ingestion, transcripts, discovery. No UI, no Apple-only APIs.
        .target(
            name: "PodiumCore",
            dependencies: ["CSQLite"],
            path: "Sources/PodiumCore"
        ),

        // Cross-platform Hummingbird 2 HTTP + WebSocket server.
        .target(
            name: "PodiumServer",
            dependencies: [
                "PodiumCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/PodiumServer"
        ),

        // podium-server: headless daemon CLI (macOS + Linux). On Linux this
        // is the app — it serves the web dashboard over HTTP.
        .executableTarget(
            name: "PodiumServerCLI",
            dependencies: [
                "PodiumServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/PodiumServerCLI"
        ),

        // podium-hook: tiny native replacement for hook.mjs. Depends only on
        // PodiumCore (Foundation-only within that library) — deliberately
        // dependency-free of third-party packages so it stays a fast, small
        // binary Claude Code shells out to on every tool call.
        .executableTarget(
            name: "PodiumHook",
            dependencies: ["PodiumCore"],
            path: "Sources/PodiumHook"
        ),

        // Native SwiftUI macOS app. Sources are wrapped in #if os(macOS) so
        // `swift build` still succeeds for the other products on Linux.
        .executableTarget(
            name: "PodiumApp",
            path: "Sources/PodiumApp"
        ),

        .testTarget(
            name: "PodiumCoreTests",
            dependencies: ["PodiumCore"],
            path: "Tests/PodiumCoreTests"
        ),
        .testTarget(
            name: "PodiumServerTests",
            dependencies: ["PodiumServer"],
            path: "Tests/PodiumServerTests"
        )
    ]
)
