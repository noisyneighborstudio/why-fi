// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "netmon-menubar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "netmon-menubar", targets: ["netmon-menubar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "NetmonCore",
            path: "Sources/NetmonCore"
        ),
        .executableTarget(
            name: "netmon-menubar",
            dependencies: [
                "NetmonCore",
                .product(name: "Sparkle", package: "sparkle")
            ],
            path: "Sources/netmon-menubar"
        ),
        .executableTarget(
            name: "nofi-widgets",
            dependencies: ["NetmonCore"],
            path: "Sources/nofi-widgets",
            // App extensions start in Foundation's NSExtensionMain, which sets up ExtensionKit
            // and then calls the widget bundle's main. Xcode passes this for extension targets.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(
            name: "NetmonCoreTests",
            dependencies: ["NetmonCore"],
            path: "Tests/NetmonCoreTests"
        )
    ]
)
