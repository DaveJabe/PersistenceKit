// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersistenceKit",
    platforms: [
        .iOS("18.6"),
        .macOS("14.0")   // host floor so `swift build`/`swift test` run on the Mac
    ],
    products: [
        .library(name: "PersistenceKit", targets: ["PersistenceKit"])
    ],
    dependencies: [
        // Matches the app's pin (upToNextMajor from 7.0.0) so SPM resolves a single GRDB.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "PersistenceKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "PersistenceKitTests",
            dependencies: [
                "PersistenceKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
