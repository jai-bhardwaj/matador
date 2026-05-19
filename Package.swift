// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Matador",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Matador",
            path: "Sources/Matador",
            resources: [
                .copy("Resources/lua"),
            ]
        ),
    ]
)
