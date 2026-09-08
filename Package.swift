// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeVault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WeVault", targets: ["WeVaultApp"]),
        .library(name: "WeVaultCore", targets: ["WeVaultCore"])
    ],
    targets: [
        .target(
            name: "WeVaultCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "WeVaultApp",
            dependencies: ["WeVaultCore"]
        ),
        .testTarget(
            name: "WeVaultAppTests",
            dependencies: ["WeVaultApp", "WeVaultCore"]
        ),
        .testTarget(
            name: "WeVaultCoreTests",
            dependencies: ["WeVaultCore"]
        )
    ]
)
