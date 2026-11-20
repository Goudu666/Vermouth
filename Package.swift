// swift-tools-version: 6.0

import PackageDescription

var products: [Product] = [
    .library(
        name: "VermouthCore",
        targets: ["VermouthCore"]
    ),
    .executable(
        name: "vermouth",
        targets: ["VermouthCLI"]
    ),
]

var targets: [Target] = [
    .target(
        name: "VermouthCore",
        path: "Sources/VermouthCore",
        resources: [
            .copy("Recipes/Resources"),
        ]
    ),
    .executableTarget(
        name: "VermouthCLI",
        dependencies: ["VermouthCore"],
        path: "Sources/VermouthCLI"
    ),
    .testTarget(
        name: "VermouthCoreTests",
        dependencies: ["VermouthCore"],
        path: "Tests/VermouthCoreTests"
    ),
]

#if os(macOS)
products.append(
    .executable(
        name: "VermouthApp",
        targets: ["VermouthApp"]
    )
)
targets.append(
    .executableTarget(
        name: "VermouthApp",
        dependencies: ["VermouthCore"],
        path: "Sources/VermouthApp"
    )
)
#endif

let package = Package(
    name: "Vermouth",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    targets: targets
)
