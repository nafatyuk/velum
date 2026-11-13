// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Velum",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Velum",
            dependencies: ["VelumStatus"],
            path: "Sources/Velum",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // T1: the status file's schema, shared by the app (which writes it) and velumctl (which reads it).
        .target(name: "VelumStatus", path: "Sources/VelumStatus"),
        .executableTarget(name: "velumctl", dependencies: ["VelumStatus"], path: "Sources/velumctl"),
        .testTarget(
            name: "VelumTests",
            dependencies: ["Velum", "VelumStatus"],
            path: "Tests/VelumTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
