// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nokcandu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nokcandu", targets: ["Nokcandu"]),
        .executable(name: "nokcandu-screen-size", targets: ["NokcanduScreenSize"]),
        .library(name: "NokcanduCore", targets: ["NokcanduCore"]),
    ],
    targets: [
        .target(name: "NokcanduCore", path: "Sources/NokcanduCore"),
        .executableTarget(name: "Nokcandu", dependencies: ["NokcanduCore"], path: "Sources/Nokcandu"),
        .executableTarget(name: "NokcanduScreenSize", path: "Sources/NokcanduScreenSize"),
        .testTarget(name: "NokcanduCoreTests", dependencies: ["NokcanduCore"], path: "Tests/NokcanduCoreTests"),
    ]
)
