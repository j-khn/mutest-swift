// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftMutationTesting",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-mutation-testing", targets: ["swift-mutation-testing"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")
    ],
    targets: [
        .target(
            name: "SwiftMutationTesting",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),
        .executableTarget(name: "swift-mutation-testing", dependencies: ["SwiftMutationTesting"]),
        .testTarget(name: "SwiftMutationTestingTests", dependencies: ["SwiftMutationTesting"])
    ]
)
