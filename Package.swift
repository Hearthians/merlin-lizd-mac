// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SSHTmuxHub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SSHTmuxHubCore", targets: ["SSHTmuxHubCore"]),
        .executable(name: "SSHTmuxHub", targets: ["SSHTmuxHubApp"]),
        .executable(
            name: "SSHTmuxHubCoreTests",
            targets: ["SSHTmuxHubCoreTests"]
        )
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .target(
            name: "SSHTmuxHubCore",
            path: "Sources/SSHTmuxHubCore",
            sources: [
                "ExternalTerminalLauncher.swift",
                "IdentifierValidator.swift",
                "InventoryProcess.swift",
                "ManagedTerminalCommandBuilder.swift",
                "SSHHost.swift",
                "SSHTmuxCommands.swift",
                "SSHMasterCommands.swift",
                "SSHMasterPool.swift",
                "TerminalState.swift",
                "TerminalTabTmuxCoordinator.swift",
                "TmuxSessionController.swift",
                "TmuxSessionDiscovery.swift",
                "TmuxSessionParser.swift",
            ]
        ),
        .target(
            name: "_Testing_Foundation",
            path: "Sources/TestingFoundationShim"
        ),
        .executableTarget(
            name: "SSHTmuxHubApp",
            dependencies: [
                "SSHTmuxHubCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/SSHTmuxHubApp",
            sources: [
                "AppModel.swift",
                "DesignSystem.swift",
                "HostViews.swift",
                "HubRuntime.swift",
                "SSHTmuxHubApplication.swift",
                "SSHTmuxHubRootView.swift",
                "SidebarView.swift",
                "TerminalSession.swift",
                "TerminalSessionHost.swift",
                "TerminalTabsModel.swift",
                "TerminalWorkspaceView.swift",
                "TmuxSessionBrowserView.swift",
            ]
        ),
        .executableTarget(
            name: "SSHTmuxHubCoreTests",
            dependencies: [
                "SSHTmuxHubCore",
                "_Testing_Foundation",
            ],
            path: "Tests/SSHTmuxHubCoreTests",
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
