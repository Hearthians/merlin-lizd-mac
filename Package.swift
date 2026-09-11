// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TmuxHub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TmuxHubCore", targets: ["TmuxHubCore"]),
        .executable(name: "TmuxHub", targets: ["TmuxHubApp"]),
        .executable(name: "TmuxHubAskPass", targets: ["TmuxHubAskPass"]),
        .executable(
            name: "TmuxHubCoreTests",
            targets: ["TmuxHubCoreTests"]
        )
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .target(
            name: "TmuxHubCore",
            path: "Sources/TmuxHubCore",
            sources: [
                "AttachmentTransfer.swift",
                "ExternalTerminalLauncher.swift",
                "Herdr.swift",
                "IdentifierValidator.swift",
                "InventoryProcess.swift",
                "ManagedTerminalCommandBuilder.swift",
                "SSHHost.swift",
                "SSHHostQuickAccess.swift",
                "SSHPasswordStore.swift",
                "TmuxCommands.swift",
                "SSHMasterCommands.swift",
                "SSHMasterPool.swift",
                "TerminalState.swift",
                "TerminalTabTmuxCoordinator.swift",
                "TmuxSessionController.swift",
                "TmuxSessionDiscovery.swift",
                "TmuxSessionParser.swift",
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "_Testing_Foundation",
            path: "Sources/TestingFoundationShim"
        ),
        .executableTarget(
            name: "TmuxHubApp",
            dependencies: [
                "TmuxHubCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/TmuxHubApp",
            sources: [
                "AttachmentTerminalView.swift",
                "TerminalAttachmentModel.swift",
                "TerminalAttachmentBar.swift",
                "AppModel.swift",
                "DesignSystem.swift",
                "HostViews.swift",
                "HerdrBrowserView.swift",
                "HubRuntime.swift",
                "TmuxHubApplication.swift",
                "TmuxHubRootView.swift",
                "SidebarView.swift",
                "TerminalSession.swift",
                "TerminalSessionHost.swift",
                "TerminalTabsModel.swift",
                "TerminalWorkspaceView.swift",
                "TmuxSessionBrowserView.swift",
            ]
        ),
        .executableTarget(
            name: "TmuxHubAskPass",
            path: "Sources/TmuxHubAskPass"
        ),
        .executableTarget(
            name: "TmuxHubCoreTests",
            dependencies: [
                "TmuxHubCore",
                "_Testing_Foundation",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Tests/TmuxHubCoreTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ]
        )
    ]
)
