// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CatermSpike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CatermSpike", targets: ["CatermSpike"])
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "CatermSpike",
            dependencies: ["GhosttyKit"],
            path: "Sources/CatermSpike",
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
        )
    ]
)
