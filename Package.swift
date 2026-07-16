// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MerlinHubX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MerlinLizdCore", targets: ["MerlinLizdCore"]),
        .library(
            name: "MerlinLizdCodexAdapter",
            targets: ["MerlinLizdCodexAdapter"]
        ),
        .executable(name: "MerlinHubX", targets: ["MerlinLizdApp"]),
        .executable(name: "MerlinLizdCoreTests", targets: ["MerlinLizdCoreTests"])
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .target(name: "MerlinLizdCore"),
        .target(
            name: "MerlinLizdCodexAdapter",
            dependencies: ["MerlinLizdCore"]
        ),
        .target(
            name: "_Testing_Foundation",
            path: "Sources/TestingFoundationShim"
        ),
        .executableTarget(
            name: "MerlinLizdApp",
            dependencies: [
                "MerlinLizdCore",
                "MerlinLizdCodexAdapter",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "MerlinLizdCoreTests",
            dependencies: [
                "MerlinLizdCore",
                "MerlinLizdCodexAdapter",
                "_Testing_Foundation",
            ],
            path: "Tests/MerlinLizdCoreTests",
            resources: [
                .copy("Fixtures")
            ],
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
