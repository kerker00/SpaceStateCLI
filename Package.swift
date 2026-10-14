// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Local override for developing both sibling repositories; releases use the pinned tag.
let localKit = ProcessInfo.processInfo.environment["SPACESTATEKIT_PATH"]
let package = Package(
    name: "SpaceStateCLI",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "spacestate", targets: ["SpaceStateCLI"])],
    dependencies: [
        localKit.map { .package(path: $0) }
            ?? .package(url: "https://github.com/kerker00/SpaceStateKit.git", exact: "0.3.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(name: "CLIKit", dependencies: [.product(name: "SpaceAPI", package: "SpaceStateKit")]),
        .executableTarget(name: "SpaceStateCLI", dependencies: [
            "CLIKit",
            .product(name: "SpaceAPI", package: "SpaceStateKit"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "CLIKitTests", dependencies: ["CLIKit", .product(name: "SpaceAPI", package: "SpaceStateKit")]),
    ]
)
