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
        .target(name: "NokcanduCore", dependencies: ["NokcanduPadEngine", "NokcanduStreamCore"], path: "Sources/NokcanduCore"),
        // Streams: Mbed TLS 3.6.2 (Apache-2.0), Opus 1.5.2 (BSD-3-Clause) and VoidLink's Moonlight core (GPL-3.0).
        .target(name: "NokcanduMbedTLS", path: "Sources/NokcanduMbedTLS", exclude: ["LICENSE"],
                cSettings: [.headerSearchPath("library"), .unsafeFlags(["-w"])]),
        .target(name: "NokcanduOpus", path: "Sources/NokcanduOpus", exclude: ["COPYING", "AUTHORS"],
                cSettings: [.headerSearchPath("celt"), .headerSearchPath("silk"), .headerSearchPath("silk/float"),
                            .headerSearchPath("src"), .headerSearchPath("include"),
                            .define("OPUS_BUILD"), .define("USE_ALLOCA"), .define("HAVE_LRINT"), .define("HAVE_LRINTF"),
                            .define("ENABLE_HARDENING"), .unsafeFlags(["-w"])]),
        .target(name: "NokcanduStreamCore", dependencies: ["NokcanduMbedTLS", "NokcanduOpus"], path: "Sources/NokcanduStreamCore",
                exclude: ["moonlight/LICENSE.txt", "moonlight/README.md", "moonlight/enet/LICENSE", "moonlight/nanors"],
                cSettings: [.headerSearchPath("moonlight/src"), .headerSearchPath("moonlight/enet/include"),
                            .headerSearchPath("moonlight/nanors"), .headerSearchPath("moonlight/nanors/deps/obl"),
                            .headerSearchPath("moonlight/nanors/deps"), .headerSearchPath("../NokcanduMbedTLS/include"),
                            .define("USE_MBEDTLS"), .define("HAS_SOCKLEN_T"), .define("NDEBUG"),
                            .unsafeFlags(["-w"])],
                linkerSettings: [.linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
                                 .linkedFramework("AudioToolbox")]),
        .executableTarget(name: "Nokcandu", dependencies: ["NokcanduCore", "NokcanduPadEngine", "NokcanduStreamCore"], path: "Sources/Nokcandu"),
        .executableTarget(name: "NokcanduSettings", dependencies: ["NokcanduCore"], path: "Sources/NokcanduSettings"),
        .executableTarget(name: "NokcanduScreenSize", path: "Sources/NokcanduScreenSize"),
        .testTarget(name: "NokcanduCoreTests", dependencies: ["NokcanduCore", "NokcanduPadEngine", "NokcanduStreamCore"], path: "Tests/NokcanduCoreTests"),
    ]
)
