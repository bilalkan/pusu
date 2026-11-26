// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pusu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Pusu", targets: ["Pusu"]),
        .executable(name: "pusu-helper", targets: ["PusuHelper"]),
    ],
    dependencies: [
        // Uygulama içi güncelleme: indirir, EdDSA imzasını doğrular, kurar ve yeniden açar.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
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
            dependencies: ["PusuCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                // Sparkle.framework paketin Contents/Frameworks klasöründe.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
