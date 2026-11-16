// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PolyglotSwiftSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "Polyglot", targets: ["Polyglot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NSStudent/fischer-core.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "Polyglot",
            dependencies: [
                .product(name: "FischerCore", package: "fischer-core"),
            ]
        ),
        .testTarget(
            name: "PolyglotTests",
            dependencies: ["Polyglot"],
            resources: [.copy("Resources")]
        ),
    ]
)
