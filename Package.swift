// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GuardCore", targets: ["GuardCore"]),
        .executable(name: "AgentGuard", targets: ["AgentGuard"]),
        .executable(name: "AgentGuardES", targets: ["AgentGuardES"]),
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
        .executableTarget(
            name: "AgentGuardES",
            dependencies: ["GuardCore"],
            linkerSettings: [.linkedLibrary("EndpointSecurity")]
        ),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
    ]
)
