// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Claudence",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Claudence", targets: ["Claudence"]),
        .library(name: "ClaudenceCore", targets: ["ClaudenceCore"]),
    ],
    targets: [
        .target(name: "ClaudenceCore"),
        .executableTarget(name: "Claudence", dependencies: ["ClaudenceCore"]),
        .testTarget(name: "ClaudenceCoreTests", dependencies: ["ClaudenceCore"]),
    ]
)
