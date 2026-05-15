// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "roontrol",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "roontrol", targets: ["roontrol"]),
    ],
    targets: [
        .executableTarget(
            name: "roontrol",
            path: "Sources/roontrol",
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
            name: "roontrolTests",
            dependencies: ["roontrol"],
            path: "Tests/roontrolTests"
        ),
    ]
)
