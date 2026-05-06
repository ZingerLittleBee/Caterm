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
            dependencies: ["GhosttyKit", "ConfigStore", "SettingsStore"],
            path: "Sources/TerminalEngine"
        ),
        .target(
            name: "SSHCommandBuilder",
            path: "Sources/SSHCommandBuilder",
            exclude: ["Resources/README.md"],
            resources: [
                .copy("Resources/xterm-ghostty.terminfo"),
            ]
        ),
        .target(
            name: "KeychainStore",
            path: "Sources/KeychainStore"
        ),
        .target(
            name: "ConfigStore",
            dependencies: ["SettingsStore"],
            path: "Sources/ConfigStore"
        ),
        .target(
            name: "SessionStore",
            dependencies: ["SSHCommandBuilder", "KeychainStore", "ServerSyncClient"],
            path: "Sources/SessionStore"
        ),
        .target(
            name: "ServerSyncClient",
            dependencies: ["SSHCommandBuilder", "CredentialSyncTypes"],
            path: "Sources/ServerSyncClient"
        ),
        .target(
            name: "HostSyncStore",
            dependencies: ["ServerSyncClient", "SessionStore", "SSHCommandBuilder", "CredentialSyncStore", "CredentialSyncTypes", "KeychainStore", "ManagedKeyStore"],
            path: "Sources/HostSyncStore"
        ),
        .target(
            name: "CloudKitSyncClient",
            dependencies: ["ServerSyncClient", "SSHCommandBuilder", "CredentialSyncTypes", "SettingsSyncStore"],
            path: "Sources/CloudKitSyncClient"
        ),
        .target(
            name: "CredentialSyncTypes",
            path: "Sources/CredentialSyncTypes"
        ),
        .target(
            name: "CredentialSyncStore",
            dependencies: ["CredentialSyncTypes"],
            path: "Sources/CredentialSyncStore"
        ),
        .target(
            name: "SettingsStore",
            dependencies: [],
            path: "Sources/SettingsStore",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "SettingsSyncStore",
            dependencies: ["SettingsStore"],
            path: "Sources/SettingsSyncStore"
        ),
        .target(
            name: "SnippetSyncClient",
            path: "Sources/SnippetSyncClient"
        ),
        .target(
            name: "SnippetStore",
            dependencies: ["SnippetSyncClient"],
            path: "Sources/SnippetStore"
        ),
        .target(
            name: "FileTransferStore",
            dependencies: ["SSHCommandBuilder", "SFTPCommandBuilder"],
            path: "Sources/FileTransferStore"
        ),
        .target(
            name: "SFTPCommandBuilder",
            dependencies: ["SSHCommandBuilder"],
            path: "Sources/SFTPCommandBuilder"
        ),
        .target(
            name: "ManagedKeyStore",
            path: "Sources/ManagedKeyStore"
        ),
        .target(
            name: "CredentialSync",
            dependencies: ["KeychainStore", "SessionStore", "HostSyncStore", "ManagedKeyStore", "CloudKitSyncClient", "CredentialSyncTypes", "CredentialSyncStore"],
            path: "Sources/CredentialSync"
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
                "ServerSyncClient",
                "HostSyncStore",
                "FileTransferStore",
                "SFTPCommandBuilder",
                "CloudKitSyncClient",
                "CredentialSync",
                "CredentialSyncStore",
                "SettingsSyncStore",
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
            dependencies: ["ConfigStore", "SettingsStore"],
            path: "Tests/ConfigStoreTests"
        ),
        .testTarget(
            name: "ServerSyncClientTests",
            dependencies: ["ServerSyncClient"],
            path: "Tests/ServerSyncClientTests"
        ),
        .testTarget(
            name: "HostSyncStoreTests",
            dependencies: ["HostSyncStore", "ServerSyncClient", "SessionStore", "SSHCommandBuilder", "KeychainStore", "CredentialSyncStore", "CredentialSyncTypes", "ManagedKeyStore", "CredentialSync"],
            path: "Tests/HostSyncStoreTests"
        ),
        .testTarget(
            name: "CatermTests",
            dependencies: ["Caterm", "SessionStore", "SSHCommandBuilder", "KeychainStore", "ServerSyncClient", "HostSyncStore", "SettingsStore", "ConfigStore"],
            path: "Tests/CatermTests"
        ),
        .testTarget(
            name: "TerminalEngineTests",
            dependencies: ["TerminalEngine", "SettingsStore"],
            path: "Tests/TerminalEngineTests"
        ),
        .testTarget(
            name: "FileTransferStoreTests",
            dependencies: ["FileTransferStore", "SSHCommandBuilder", "SFTPCommandBuilder"],
            path: "Tests/FileTransferStoreTests"
        ),
        .testTarget(
            name: "SFTPCommandBuilderTests",
            dependencies: ["SFTPCommandBuilder", "SSHCommandBuilder"],
            path: "Tests/SFTPCommandBuilderTests"
        ),
        .testTarget(
            name: "SettingsStoreTests",
            dependencies: ["SettingsStore"],
            path: "Tests/SettingsStoreTests"
        ),
        .testTarget(
            name: "SettingsSyncStoreTests",
            dependencies: ["SettingsSyncStore", "SettingsStore"],
            path: "Tests/SettingsSyncStoreTests"
        ),
        .testTarget(
            name: "SnippetSyncClientTests",
            dependencies: ["SnippetSyncClient"],
            path: "Tests/SnippetSyncClientTests"
        ),
        .testTarget(
            name: "SnippetStoreTests",
            dependencies: ["SnippetStore", "SnippetSyncClient"],
            path: "Tests/SnippetStoreTests"
        ),
        .testTarget(
            name: "CloudKitSyncClientTests",
            dependencies: ["CloudKitSyncClient", "ServerSyncClient", "SSHCommandBuilder", "CredentialSyncTypes"],
            path: "Tests/CloudKitSyncClientTests"
        ),
        .testTarget(
            name: "ManagedKeyStoreTests",
            dependencies: ["ManagedKeyStore"],
            path: "Tests/ManagedKeyStoreTests"
        ),
        .testTarget(
            name: "CredentialSyncTests",
            dependencies: ["CredentialSync", "ManagedKeyStore", "KeychainStore", "SessionStore", "HostSyncStore", "CloudKitSyncClient", "CredentialSyncTypes", "CredentialSyncStore"],
            path: "Tests/CredentialSyncTests"
        ),
        .testTarget(
            name: "CredentialSyncTypesTests",
            dependencies: ["CredentialSyncTypes"],
            path: "Tests/CredentialSyncTypesTests"
        ),
    ]
)
