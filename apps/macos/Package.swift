// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Caterm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "caterm", targets: ["Caterm"]),
        .executable(name: "caterm-askpass", targets: ["CatermAskpass"]),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),

        // --- Libraries ---
        .target(
            name: "TerminalEngine",
            dependencies: ["GhosttyKit", "ConfigStore"],
            path: "Sources/TerminalEngine"
        ),
        .target(
            name: "SSHCommandBuilder",
            path: "Sources/SSHCommandBuilder"
        ),
        .target(
            name: "KeychainStore",
            path: "Sources/KeychainStore"
        ),
        .target(
            name: "ConfigStore",
            path: "Sources/ConfigStore"
        ),
        .target(
            name: "SessionStore",
            dependencies: ["SSHCommandBuilder", "KeychainStore"],
            path: "Sources/SessionStore"
        ),

        // --- Executables ---
        .executableTarget(
            name: "Caterm",
            dependencies: [
                "TerminalEngine",
                "SSHCommandBuilder",
                "SessionStore",
                "KeychainStore",
                "ConfigStore",
            ],
            path: "Sources/Caterm",
            resources: [.copy("../../Resources/Caterm.entitlements")],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
        .executableTarget(
            name: "CatermAskpass",
            dependencies: ["KeychainStore"],
            path: "Sources/CatermAskpass"
        ),

        // --- Tests ---
        .testTarget(
            name: "SSHCommandBuilderTests",
            dependencies: ["SSHCommandBuilder"],
            path: "Tests/SSHCommandBuilderTests"
        ),
        .testTarget(
            name: "KeychainStoreTests",
            dependencies: ["KeychainStore"],
            path: "Tests/KeychainStoreTests"
        ),
        .testTarget(
            name: "SessionStoreTests",
            dependencies: ["SessionStore", "KeychainStore", "SSHCommandBuilder"],
            path: "Tests/SessionStoreTests"
        ),
        .testTarget(
            name: "ConfigStoreTests",
            dependencies: ["ConfigStore"],
            path: "Tests/ConfigStoreTests"
        ),
    ]
)
