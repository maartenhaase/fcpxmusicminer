// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FCPXMusicMiner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FCPXMusicMiner", targets: ["FCPXMusicMiner"])
    ],
    targets: [
        .executableTarget(
            name: "FCPXMusicMiner",
            path: "Sources/FCPXMusicMiner"
        )
    ]
)
