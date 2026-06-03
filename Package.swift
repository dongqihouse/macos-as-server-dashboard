// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "macos-as-server-dashboard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacServerDashboard", targets: ["MacServerDashboard"])
    ],
    targets: [
        .executableTarget(
            name: "MacServerDashboard"
        )
    ]
)
