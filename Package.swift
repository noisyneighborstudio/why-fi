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
        .testTarget(
            name: "NetmonCoreTests",
            dependencies: ["NetmonCore"],
            path: "Tests/NetmonCoreTests"
        )
    ]
)
