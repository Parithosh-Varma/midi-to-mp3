// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MidiToMp3",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MidiToMp3", targets: ["MidiToMp3App"])
    ],
    targets: [
        .target(name: "MidiToMp3Core"),
        .executableTarget(
            name: "MidiToMp3App",
            dependencies: ["MidiToMp3Core"]
        ),
        .testTarget(
            name: "MidiToMp3CoreTests",
            dependencies: ["MidiToMp3Core"]
        ),
    ]
)
