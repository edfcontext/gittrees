// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitTrees",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GitTrees", targets: ["GitTrees"]),
        .library(name: "GitTreesCore", targets: ["GitTreesCore"])
    ],
    targets: [
        // Git execution, parsing, models and state. No SwiftUI.
        .target(
            name: "GitTreesCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // SwiftUI application shell.
        .executableTarget(
            name: "GitTrees",
            dependencies: ["GitTreesCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GitTreesCoreTests",
            dependencies: ["GitTreesCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
