// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pusu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Pusu", targets: ["Pusu"]),
        .executable(name: "pusu-helper", targets: ["PusuHelper"]),
    ],
    targets: [
        .target(
            name: "PusuVirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .target(
            name: "PusuCore",
            dependencies: ["PusuVirtualDisplay"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Pusu",
            dependencies: ["PusuCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(name: "PusuHelper", dependencies: ["PusuCore"]),
        .executableTarget(name: "PusuTests", dependencies: ["PusuCore"], path: "Tests/PusuCoreTests"),
    ]
)
