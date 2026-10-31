// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftMutationTesting",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MutationTestingSpec", targets: ["MutationTestingSpec"]),
        .library(name: "SwiftMutationTesting", targets: ["SwiftMutationTesting"]),
        .executable(name: "swift-mutation-testing", targets: ["swift-mutation-testing"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")
    ],
    targets: [
        .target(name: "MutationTestingSpec"),
        .target(
            name: "SwiftMutationTesting",
            dependencies: [
                "MutationTestingSpec",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(name: "swift-mutation-testing", dependencies: ["SwiftMutationTesting"]),
        .testTarget(name: "MutationTestingSpecTests", dependencies: ["SwiftMutationTesting"]),
        .testTarget(name: "SwiftMutationTestingTests", dependencies: ["SwiftMutationTesting"])
    ]
)
