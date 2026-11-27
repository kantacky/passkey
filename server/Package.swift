// swift-tools-version:6.4

import PackageDescription

let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "PasskeyServer",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "passkey-server", targets: ["App"]),
        .library(name: "Core", targets: ["Core"]),
        .library(name: "API", targets: ["API"]),
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.25.1"),
        .package(url: "https://github.com/swift-server/webauthn-swift.git", exact: "1.0.0-beta.4"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.3"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.37.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.17.2"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                "API", "Core", "Persistence",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: upcomingFeatures
        ),
        .target(
            name: "API",
            dependencies: [
                "Core",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "WebAuthn", package: "webauthn-swift"),
            ],
            swiftSettings: upcomingFeatures
        ),
        .target(
            name: "Core",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "WebAuthn", package: "webauthn-swift"),
            ],
            resources: [.copy("Resources/aaguid.json")],
            swiftSettings: upcomingFeatures
        ),
        .target(
            name: "Persistence",
            dependencies: [
                "Core",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: upcomingFeatures
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core", "Persistence",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "WebAuthn", package: "webauthn-swift"),
            ],
            swiftSettings: upcomingFeatures
        ),
        .testTarget(
            name: "APITests",
            dependencies: [
                "API", "Core", "Persistence",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: upcomingFeatures
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Core", "Persistence",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            swiftSettings: upcomingFeatures
        ),
    ]
)
