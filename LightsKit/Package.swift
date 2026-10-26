// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LightsKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LightsKit", targets: ["LightsKit"]),
    ],
    targets: [
        .target(name: "LightsKit"),
        .testTarget(name: "LightsKitTests", dependencies: ["LightsKit"]),
    ]
)
