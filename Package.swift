// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "apple-sync-kit",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "AppleSyncKit", targets: ["AppleSyncKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client", from: "1.21.0"),
    .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    .package(
      url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.3",
      traits: ["SQLiteSwiftCSQLite"]),
  ],
  targets: [
    .target(
      name: "AppleSyncKit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOFoundationCompat", package: "swift-nio"),
        .product(name: "SQLite", package: "SQLite.swift"),
      ],
      path: "Sources/AppleSyncKit"
    ),
    .testTarget(
      name: "AppleSyncKitTests",
      dependencies: ["AppleSyncKit"],
      path: "Tests/AppleSyncKitTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
