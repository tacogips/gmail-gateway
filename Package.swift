// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "gmail-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "GmailGatewayCore", targets: ["GmailGatewayCore"]),
    .executable(name: "gmail-gateway-reader", targets: ["GmailGatewayReader"]),
    .executable(name: "gmail-gateway-draft", targets: ["GmailGatewayDraft"]),
    .executable(name: "gmail-gateway-sender", targets: ["GmailGatewaySender"]),
    .executable(name: "gmail-gateway-threads", targets: ["GmailGatewayThreads"]),
    .executable(name: "gmail-gateway-message-box", targets: ["GmailGatewayMessageBox"]),
    .executable(name: "gmail-gateway-swift-smoke-tests", targets: ["GmailGatewaySwiftSmokeTests"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
    .package(url: "https://github.com/tacogips/google-gateway-auth.git", revision: "48e0112fb5eb057cf012194cfffaa2581ba29d76"),
    .package(url: "https://github.com/tacogips/gateway-sdk-kit.git", exact: "0.1.1"),
    .package(url: "https://github.com/tacogips/google-service-gateway.git", revision: "ed020e4a8f45a0acedaf46334e2a67677e3c3e63")
  ],
  targets: [
    .target(name: "GmailGatewayPlatform"),
    .target(
      name: "GmailGatewayCore",
      dependencies: [
        "GmailGatewayPlatform",
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        .product(name: "GoogleGatewayAuth", package: "google-gateway-auth"),
        .product(name: "GatewaySDKKit", package: "gateway-sdk-kit"),
        .product(name: "GoogleServiceGatewayCore", package: "google-service-gateway")
      ]
    ),
    .executableTarget(
      name: "GmailGatewayReader",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewayDraft",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewaySender",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewayThreads",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewayMessageBox",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewaySwiftSmokeTests",
      dependencies: ["GmailGatewayCore"]
    ),
    .testTarget(
      name: "GmailGatewayCoreTests",
      dependencies: [
        "GmailGatewayCore",
        "GmailGatewayPlatform",
        .product(name: "GatewaySDKKit", package: "gateway-sdk-kit"),
        .product(name: "GoogleServiceGatewayCore", package: "google-service-gateway")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
