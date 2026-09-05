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
    // Replace this operator-managed local path with a pinned URL revision at release time.
    .package(path: "../../gateway-sdk-kit")
  ],
  targets: [
    .target(
      name: "GmailGatewayCore",
      dependencies: [.product(name: "GatewaySDKKit", package: "gateway-sdk-kit")]
    ),
    .executableTarget(
      name: "GmailGatewayReader",
      dependencies: ["GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewayDraft",
      dependencies: ["GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewaySender",
      dependencies: ["GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewayThreads",
      dependencies: ["GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewayMessageBox",
      dependencies: ["GmailGatewayCore"]
    ),
    .executableTarget(
      name: "GmailGatewaySwiftSmokeTests",
      dependencies: ["GmailGatewayCore"]
    ),
    .testTarget(
      name: "GmailGatewayCoreTests",
      dependencies: ["GmailGatewayCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
