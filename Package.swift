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
    .package(url: "https://github.com/tacogips/google-gateway-auth.git", revision: "48e0112fb5eb057cf012194cfffaa2581ba29d76"),
    .package(url: "https://github.com/tacogips/gateway-sdk-kit.git", exact: "0.1.0"),
    .package(url: "https://github.com/tacogips/google-service-gateway.git", revision: "9111bd95e02d598a1ddeb1886c8b98fb42134dbe")
  ],
  targets: [
    .target(
      name: "GmailGatewayCore",
      dependencies: [
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
        .product(name: "GatewaySDKKit", package: "gateway-sdk-kit"),
        .product(name: "GoogleServiceGatewayCore", package: "google-service-gateway")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
