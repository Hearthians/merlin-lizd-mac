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
                "RemoteFiles.swift",
                "SFTPDownloaderLink.swift",
                "ExternalTerminalLauncher.swift",
                "Herdr.swift",
                "IdentifierValidator.swift",
                "InventoryProcess.swift",
                "LoopbackURL.swift",
                "NetworkMeshModels.swift",
                "NetworkMeshProbe.swift",
                "NetworkMeshHealth.swift",
                "NetworkMeshBandwidth.swift",
                "NetworkOnboarding.swift",
                "NetworkMembership.swift",
                "NetworkOnboardingSetup.swift",
                "ManagedTerminalCommandBuilder.swift",
                "SSHHost.swift",
                "SSHHostConfiguration.swift",
                "SSHHostProperties.swift",
                "SSHHostQuickAccess.swift",
                "SSHPasswordStore.swift",
                "SlurmCommands.swift",
                "SlurmModels.swift",
                "SlurmHistory.swift",
                "SlurmCost.swift",
                "SlurmMonitoringModels.swift",
                "SlurmMonitoringParser.swift",
                "SlurmParser.swift",
                "SlurmService.swift",
                "TmuxCommands.swift",
                "TmuxConfiguration.swift",
                "VimPasteConfiguration.swift",
                "SSHMasterCommands.swift",
                "SSHMasterPool.swift",
                "SSHLocalForwardingService.swift",
                "TerminalState.swift",
                "TerminalTabTmuxCoordinator.swift",
                "TmuxSessionController.swift",
                "TmuxSessionDiscovery.swift",
                "TmuxSessionParser.swift",
            ],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("LocalAuthentication")]
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
                "RemoteFileBrowser.swift",
                "AppModel.swift",
                "AddSSHHostSheet.swift",
                "NetworkMeshModel.swift",
                "NetworkMeshView.swift",
                "NetworkMeshHostSheet.swift",
                "NetworkOnboardingSheet.swift",
                "SSHHostPropertiesSheet.swift",
                "DesignSystem.swift",
                "HostViews.swift",
                "HerdrBrowserView.swift",
                "HPC2PlatformModel.swift",
                "HPC2PlatformView.swift",
                "HPC2MonitoringViews.swift",
                "HPC2CostViews.swift",
                "HPC2StartSheet.swift",
                "HPC2PropertiesSheet.swift",
                "HubRuntime.swift",
                "TmuxHubApplication.swift",
                "TmuxHubRootView.swift",
                "WindowChrome.swift",
                "SidebarView.swift",
                "TerminalSession.swift",
                "TerminalSessionHost.swift",
                "TerminalTabsModel.swift",
                "TerminalWorkspaceView.swift",
                "TmuxSessionBrowserView.swift",
                "TmuxConfigurationCard.swift",
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
