// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "roon-key",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "roon-key", targets: ["roon-key"]),
    ],
    targets: [
        .executableTarget(
            name: "roon-key",
            path: "Sources/roon-key",
            exclude: [
                // Info.plist is used by the .app bundle wrapper, not by the SPM binary.
                // When building with Xcode, add it to the target's Info.plist setting.
                "Info.plist",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "roon-keyTests",
            dependencies: ["roon-key"],
            path: "Tests/roon-keyTests"
        ),
    ]
)
