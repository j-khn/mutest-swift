// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MutationFixture",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Fixture", targets: ["Fixture"])],
    targets: [
        .target(name: "Fixture"),
        .testTarget(name: "FixtureTests", dependencies: ["Fixture"])
    ]
)
