// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Caterm",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "caterm", targets: ["Caterm"]),
        .executable(name: "caterm-askpass", targets: ["CatermAskpass"]),
        .library(name: "CatermMobile", targets: ["CatermMobile"]),
        .library(name: "CatermMobileTerminal", targets: ["CatermMobileTerminal"]),
        .executable(name: "CatermMobileApp", targets: ["CatermMobileApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),

        // --- Libraries ---
        .target(
            name: "TerminalEngine",
            dependencies: ["GhosttyKit", "ConfigStore", "SettingsStore", "SnippetSyncClient"],
            path: "Sources/TerminalEngine"
        ),
        .target(
            name: "SSHCredentialContract",
            path: "Sources/SSHCredentialContract"
        ),
        .target(
            name: "SSHCommandBuilder",
            dependencies: ["SSHCredentialContract"],
            path: "Sources/SSHCommandBuilder",
            exclude: ["Resources/README.md"],
            resources: [
                .copy("Resources/xterm-ghostty.terminfo"),
            ]
        ),
        .target(
            name: "KeychainStore",
            dependencies: ["SSHCredentialContract"],
            path: "Sources/KeychainStore"
        ),
        .target(
            name: "ConfigStore",
            dependencies: ["SettingsStore"],
            path: "Sources/ConfigStore"
        ),
        .target(
            name: "MergeDecision",
            path: "Sources/MergeDecision"
        ),
        .target(
            name: "SyncScheduler",
            path: "Sources/SyncScheduler"
        ),
        .target(
            name: "SessionHistory",
            path: "Sources/SessionHistory"
        ),
        .target(
            name: "WorkspaceCore",
            path: "Sources/WorkspaceCore"
        ),
        .target(
            name: "WorkspaceTemplateStore",
            dependencies: ["WorkspaceCore"],
            path: "Sources/WorkspaceTemplateStore"
        ),
        .target(
            name: "WorkspaceBroadcast",
            dependencies: ["WorkspaceCore"],
            path: "Sources/WorkspaceBroadcast"
        ),
        .target(
            name: "HostRepositoryCore",
            dependencies: ["SSHCommandBuilder", "ServerSyncClient", "MergeDecision"],
            path: "Sources/HostRepositoryCore"
        ),
        .target(
            name: "KnownHostsStore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/KnownHostsStore"
        ),
        .target(
            name: "SessionStore",
            dependencies: ["SSHCommandBuilder", "SSHCredentialContract", "KeychainStore", "ManagedKeyStore", "ServerSyncClient", "SessionHistory", "HostRepositoryCore"],
            path: "Sources/SessionStore"
        ),
        .target(
            name: "ServerSyncClient",
            dependencies: ["SSHCommandBuilder", "CredentialSyncTypes"],
            path: "Sources/ServerSyncClient"
        ),
        .target(
            name: "HostSyncStore",
            dependencies: ["ServerSyncClient", "SessionStore", "SSHCommandBuilder", "CredentialSync", "CredentialSyncStore", "CredentialSyncTypes", "MergeDecision", "SyncScheduler", "HostRepositoryCore"],
            path: "Sources/HostSyncStore"
        ),
        .target(
            name: "CloudKitSyncClient",
            dependencies: ["ServerSyncClient", "SSHCommandBuilder", "CredentialSyncTypes", "SettingsSyncStore", "SnippetSyncClient"],
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
            dependencies: ["SettingsStore", "SyncScheduler"],
            path: "Sources/SettingsSyncStore"
        ),
        .target(
            name: "SnippetSyncClient",
            path: "Sources/SnippetSyncClient"
        ),
        .target(
            name: "SnippetStore",
            dependencies: ["SnippetSyncClient", "MergeDecision", "SyncScheduler"],
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
            name: "BackupArchive",
            dependencies: [
                "SettingsStore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
            ],
            path: "Sources/BackupArchive"
        ),
        .target(
            name: "BackupService",
            dependencies: ["BackupArchive", "SessionStore", "SnippetStore", "SnippetSyncClient", "SettingsStore", "SSHCommandBuilder", "MergeDecision"],
            path: "Sources/BackupService"
        ),
        .target(
            name: "HostKeyProvisioning",
            dependencies: ["SessionStore", "SSHCommandBuilder"],
            path: "Sources/HostKeyProvisioning"
        ),
        .target(
            name: "CredentialSync",
            dependencies: ["SessionStore", "ServerSyncClient", "CredentialSyncTypes", "CredentialSyncStore", "KeychainStore", "HostRepositoryCore"],
            path: "Sources/CredentialSync"
        ),
        .target(
            name: "CatermAskpassCore",
            path: "Sources/CatermAskpassCore"
        ),
        .target(
            name: "CatermMobile",
            dependencies: ["SSHCommandBuilder", "SSHCredentialContract", "SessionStore", "SnippetStore", "SnippetSyncClient", "FileTransferStore", "KeychainStore", "CatermMobileTerminal", "BackupArchive", "BackupService", "ManagedKeyStore", "HostRepositoryCore", "CredentialSync", "CredentialSyncStore", "CloudKitSyncClient", "ServerSyncClient", "SettingsStore", "SettingsSyncStore"],
            path: "Sources/CatermMobile"
        ),
        .target(
            name: "CatermMobileTerminal",
            dependencies: [
                "SSHCommandBuilder",
                "KeychainStore",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/CatermMobileTerminal"
        ),

        // --- Executables ---
        // iOS/iPadOS app. Built via SwiftPM (not Xcode's SwiftPM
        // integration, which is broken for swift-nio's C targets on
        // Xcode 26.5's iphonesimulator) and hand-wrapped into a .app by
        // Scripts/build-ios-app.sh. Compiles on macOS too (unused there).
        .executableTarget(
            name: "CatermMobileApp",
            dependencies: ["CatermMobile", "CatermMobileTerminal"],
            path: "App/iOS",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "Caterm",
            dependencies: [
                "TerminalEngine",
                "SSHCommandBuilder",
                "SSHCredentialContract",
                "SessionStore",
                "SessionHistory",
                "WorkspaceCore",
                "WorkspaceTemplateStore",
                "WorkspaceBroadcast",
                "KnownHostsStore",
                "KeychainStore",
                "ConfigStore",
                "ServerSyncClient",
                "HostSyncStore",
                "FileTransferStore",
                "SFTPCommandBuilder",
                "CloudKitSyncClient",
                "CredentialSync",
                "CredentialSyncStore",
                "HostKeyProvisioning",
                "ManagedKeyStore",
                "BackupArchive",
                "BackupService",
                "SettingsSyncStore",
                "SnippetStore",
                "SnippetSyncClient",
                .product(name: "Sparkle", package: "Sparkle"),
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
            dependencies: [
                "KeychainStore",
                "CatermAskpassCore",
                "SSHCredentialContract",
            ],
            path: "Sources/CatermAskpass"
        ),

        // --- Tests ---
        .testTarget(
            name: "SSHCredentialContractTests",
            dependencies: ["SSHCredentialContract"],
            path: "Tests/SSHCredentialContractTests"
        ),
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
            dependencies: ["SessionStore", "SessionHistory", "KeychainStore", "ManagedKeyStore", "SSHCommandBuilder"],
            path: "Tests/SessionStoreTests"
        ),
        .testTarget(
            name: "SessionHistoryTests",
            dependencies: ["SessionHistory"],
            path: "Tests/SessionHistoryTests"
        ),
        .testTarget(
            name: "WorkspaceCoreTests",
            dependencies: ["WorkspaceCore"],
            path: "Tests/WorkspaceCoreTests"
        ),
        .testTarget(
            name: "WorkspaceTemplateStoreTests",
            dependencies: ["WorkspaceTemplateStore", "WorkspaceCore"],
            path: "Tests/WorkspaceTemplateStoreTests"
        ),
        .testTarget(
            name: "WorkspaceBroadcastTests",
            dependencies: ["WorkspaceBroadcast", "WorkspaceCore"],
            path: "Tests/WorkspaceBroadcastTests"
        ),
        .testTarget(
            name: "HostRepositoryCoreTests",
            dependencies: ["HostRepositoryCore", "ServerSyncClient", "SSHCommandBuilder", "SessionStore", "CatermMobile", "KeychainStore"],
            path: "Tests/HostRepositoryCoreTests"
        ),
        .testTarget(
            name: "ConfigStoreTests",
            dependencies: ["ConfigStore", "SettingsStore"],
            path: "Tests/ConfigStoreTests"
        ),
        .testTarget(
            name: "MergeDecisionTests",
            dependencies: ["MergeDecision"],
            path: "Tests/MergeDecisionTests"
        ),
        .testTarget(
            name: "SyncSchedulerTests",
            dependencies: ["SyncScheduler"],
            path: "Tests/SyncSchedulerTests"
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
            dependencies: ["Caterm", "SessionStore", "SSHCommandBuilder", "KeychainStore", "ServerSyncClient", "HostSyncStore", "SettingsStore", "ConfigStore", "SnippetStore", "SnippetSyncClient", "WorkspaceCore", "WorkspaceTemplateStore", "WorkspaceBroadcast"],
            path: "Tests/CatermTests"
        ),
        .testTarget(
            name: "CatermMobileTests",
            dependencies: ["CatermMobile", "CatermMobileTerminal", "CloudKitSyncClient", "SSHCommandBuilder", "SSHCredentialContract", "SessionStore", "SnippetStore", "SnippetSyncClient", "FileTransferStore", "KeychainStore", "BackupArchive", "BackupService", "ManagedKeyStore", "HostRepositoryCore", "ServerSyncClient", "CredentialSync", "CredentialSyncStore", "CredentialSyncTypes"],
            path: "Tests/CatermMobileTests"
        ),
        .testTarget(
            name: "CatermMobileTerminalTests",
            dependencies: ["CatermMobileTerminal", "SSHCommandBuilder", "KeychainStore"],
            path: "Tests/CatermMobileTerminalTests"
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
            dependencies: ["CloudKitSyncClient", "ServerSyncClient", "SSHCommandBuilder", "CredentialSyncTypes", "SnippetSyncClient"],
            path: "Tests/CloudKitSyncClientTests"
        ),
        .testTarget(
            name: "ManagedKeyStoreTests",
            dependencies: ["ManagedKeyStore"],
            path: "Tests/ManagedKeyStoreTests"
        ),
        .testTarget(
            name: "BackupArchiveTests",
            dependencies: ["BackupArchive", "SettingsStore"],
            path: "Tests/BackupArchiveTests"
        ),
        .testTarget(
            name: "BackupServiceTests",
            dependencies: ["BackupService", "BackupArchive", "SessionStore", "ManagedKeyStore", "SnippetStore", "SnippetSyncClient", "SettingsStore", "SSHCommandBuilder", "KeychainStore"],
            path: "Tests/BackupServiceTests"
        ),
        .testTarget(
            name: "HostKeyProvisioningTests",
            dependencies: ["HostKeyProvisioning", "SessionStore", "ManagedKeyStore", "KeychainStore", "SSHCommandBuilder"],
            path: "Tests/HostKeyProvisioningTests"
        ),
        .testTarget(
            name: "KnownHostsStoreTests",
            dependencies: ["KnownHostsStore"],
            path: "Tests/KnownHostsStoreTests"
        ),
        .testTarget(
            name: "CredentialSyncTests",
            dependencies: ["CredentialSync", "ManagedKeyStore", "KeychainStore", "SessionStore", "ServerSyncClient", "SSHCommandBuilder", "SSHCredentialContract", "CredentialSyncTypes", "CredentialSyncStore"],
            path: "Tests/CredentialSyncTests"
        ),
        .testTarget(
            name: "CredentialSyncTypesTests",
            dependencies: ["CredentialSyncTypes"],
            path: "Tests/CredentialSyncTypesTests"
        ),
        .testTarget(
            name: "CatermAskpassCoreTests",
            dependencies: ["CatermAskpassCore"],
            path: "Tests/CatermAskpassCoreTests"
        ),
    ]
)
