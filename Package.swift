// swift-tools-version: 6.2
//
//  Package.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import PackageDescription

let package = Package(
  name: "ArxBridge",
  platforms: [.macOS(.v15)],
  products: [.library(name: "BridgeCore", targets: ["BridgeCore"])],
  dependencies: [
    .package(url: "https://github.com/csjones/lefthook-plugin.git", exact: "2.2.2"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.1"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1"),
    .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.8.0"),
  ],
  targets: [
    .executableTarget(
      name: "BridgeFixtureServer", dependencies: ["BridgeCore"], path: "BridgeFixtureServer"),
    .target(
      name: "BridgeCore",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
      ], path: "BridgeCore", resources: [.copy("Web")]),
    .testTarget(
      name: "BridgeCoreTests",
      dependencies: [
        "BridgeCore", .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ],
      path: "BridgeCoreTests"),
  ]
)
