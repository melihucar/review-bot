// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReviewBot",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ReviewBot", targets: ["ReviewBot"]),
    ],
    targets: [
        .executableTarget(
            name: "ReviewBot",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ReviewBotTests",
            dependencies: ["ReviewBot"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
