// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Folga",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Folga",
            path: "Sources/Folga",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"])]
        )
    ]
)
