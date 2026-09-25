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
    targets: [
        .target(
            name: "NetmonCore",
            path: "Sources/NetmonCore"
        ),
        .executableTarget(
            name: "netmon-menubar",
            dependencies: ["NetmonCore"],
            path: "Sources/netmon-menubar"
        ),
        .testTarget(
            name: "NetmonCoreTests",
            dependencies: ["NetmonCore"],
            path: "Tests/NetmonCoreTests"
        )
    ]
)
