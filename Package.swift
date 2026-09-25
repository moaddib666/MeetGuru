// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingGuru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetingGuru", targets: ["MeetingGuru"]),
        .library(name: "MeetingGuruCore", targets: ["MeetingGuruCore"]),
    ],
    targets: [
        .target(
            name: "MeetingGuruCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MeetingGuru",
            dependencies: ["MeetingGuruCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeetingGuruCoreTests",
            dependencies: ["MeetingGuruCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
