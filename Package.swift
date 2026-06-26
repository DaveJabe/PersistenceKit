// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersistenceKit",
    platforms: [
        // Floors track GRDB's own minimums (iOS 13 / macOS 10.15 / tvOS 13 / watchOS 7); kept a little
        // higher for the modern concurrency / Combine surface this package uses.
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16)
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
