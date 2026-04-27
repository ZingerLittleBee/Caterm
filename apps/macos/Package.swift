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
        .executableTarget(
            name: "CatermSpike",
            path: "Sources/CatermSpike"
        )
    ]
)
