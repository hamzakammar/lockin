// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LockIn",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LockIn",
            path: "Sources/LockIn"
        )
    ]
)
