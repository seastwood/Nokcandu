// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nokcandu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nokcandu", targets: ["Nokcandu"]),
        .executable(name: "nokcandu-settings", targets: ["NokcanduSettings"]),
        .executable(name: "nokcandu-screen-size", targets: ["NokcanduScreenSize"]),
        .library(name: "NokcanduCore", targets: ["NokcanduCore"]),
    ],
    targets: [
        .target(name: "NokcanduPadEngine", path: "Sources/NokcanduPadEngine"),
        .target(name: "NokcanduCore", dependencies: ["NokcanduPadEngine"], path: "Sources/NokcanduCore"),
        .executableTarget(name: "Nokcandu", dependencies: ["NokcanduCore", "NokcanduPadEngine"], path: "Sources/Nokcandu"),
        .executableTarget(name: "NokcanduSettings", dependencies: ["NokcanduCore"], path: "Sources/NokcanduSettings"),
        .executableTarget(name: "NokcanduScreenSize", path: "Sources/NokcanduScreenSize"),
        .testTarget(name: "NokcanduCoreTests", dependencies: ["NokcanduCore", "NokcanduPadEngine"], path: "Tests/NokcanduCoreTests"),
    ]
)
