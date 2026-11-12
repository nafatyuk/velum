// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Velum",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Velum",
            path: "Sources/Velum",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "VelumTests",
            dependencies: ["Velum"],
            path: "Tests/VelumTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
