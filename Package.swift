// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "day-timeline",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "day-timeline",
            path: "Sources",
            resources: [
                .copy("Resources/Fonts")
            ]
        )
    ]
)
