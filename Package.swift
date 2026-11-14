// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "mail-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "MailGatewayCore", targets: ["MailGatewayCore"]),
    .executable(name: "mail-gateway-reader", targets: ["MailGatewayReader"]),
    .executable(name: "mail-gateway-draft", targets: ["MailGatewayDraft"]),
    .executable(name: "mail-gateway-sender", targets: ["MailGatewaySender"])
  ],
  targets: [
    .target(name: "MailGatewayCore"),
    .executableTarget(
      name: "MailGatewayReader",
      dependencies: ["MailGatewayCore"]
    ),
    .executableTarget(
      name: "MailGatewayDraft",
      dependencies: ["MailGatewayCore"]
    ),
    .executableTarget(
      name: "MailGatewaySender",
      dependencies: ["MailGatewayCore"]
    ),
    .executableTarget(
      name: "MailGatewaySwiftSmokeTests",
      dependencies: ["MailGatewayCore"]
    ),
    .testTarget(
      name: "MailGatewayCoreTests",
      dependencies: ["MailGatewayCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
