// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Velum",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Velum",
            path: "Sources/Velum",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
