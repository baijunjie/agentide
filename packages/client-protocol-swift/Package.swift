// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AgentIDEProtocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AgentIDEProtocol", targets: ["AgentIDEProtocol"])],
    targets: [
        .target(name: "AgentIDEProtocol"),
        .testTarget(name: "AgentIDEProtocolTests", dependencies: ["AgentIDEProtocol"]),
    ]
)
