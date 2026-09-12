// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GuardCore", targets: ["GuardCore"]),
        .executable(name: "AgentGuard", targets: ["AgentGuard"]),
    ],
    targets: [
        .target(name: "GuardCore"),
        .executableTarget(
            name: "AgentGuard",
            dependencies: ["GuardCore"],
            linkerSettings: [
                .linkedLibrary("EndpointSecurity"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
    ]
)
