// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MerlinHub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MerlinLizdCore", targets: ["MerlinLizdCore"]),
        .executable(name: "MerlinHub", targets: ["MerlinLizdApp"]),
        .executable(name: "MerlinLizdCoreTests", targets: ["MerlinLizdCoreTests"])
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .target(name: "MerlinLizdCore"),
        .target(
            name: "_Testing_Foundation",
            path: "Sources/TestingFoundationShim"
        ),
        .executableTarget(
            name: "MerlinLizdApp",
            dependencies: [
                "MerlinLizdCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "MerlinLizdCoreTests",
            dependencies: ["MerlinLizdCore", "_Testing_Foundation"],
            path: "Tests/MerlinLizdCoreTests",
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
