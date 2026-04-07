// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HelloTTY",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "HelloTTY",
            path: "HelloTTY/Sources",
            resources: [
                .process("../Resources")
            ]
        )
    ]
)
