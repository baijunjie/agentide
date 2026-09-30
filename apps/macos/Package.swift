// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentIDEMacNotificationCore",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../packages/client-protocol-swift"),
    ],
    targets: [
        .target(
            name: "MacNotificationCore",
            dependencies: [.product(name: "AgentIDEProtocol", package: "client-protocol-swift")],
            path: "AgentIDEMac",
            exclude: ["AgentHostSupervisor.swift", "App.swift", "MacSupport.swift", "MacViews.swift"],
            sources: ["NotificationOutboxDrainer.swift"]
        ),
        .testTarget(
            name: "MacNotificationCoreTests",
            dependencies: ["MacNotificationCore", .product(name: "AgentIDEProtocol", package: "client-protocol-swift")],
            path: "Tests/MacNotificationCoreTests"
        ),
    ]
)
