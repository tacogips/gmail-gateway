import Foundation
import Testing
@testable import GmailGatewayCore

@Test func defaultCredentialDirectoryUsesXDGStateHome() {
  let directory = GmailGatewayConfigLoader.resolveDefaultCredentialDirectory(
    environment: ["XDG_STATE_HOME": "/tmp/xdg-state"]
  )
  #expect(directory == "/tmp/xdg-state/gmail-gateway/credentials")
}

@Test func defaultCredentialDirectoryDefaultsToLocalState() {
  let directory = GmailGatewayConfigLoader.resolveDefaultCredentialDirectory(environment: [:])
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  #expect(directory == "\(home)/.local/state/gmail-gateway/credentials")
}

@Test func credentialDirEnvironmentVariableOverridesStateDefault() {
  let directory = GmailGatewayConfigLoader.resolveDefaultCredentialDirectory(
    environment: [
      "GMAIL_GATEWAY_CREDENTIAL_DIR": "/tmp/riela-credentials",
      "XDG_STATE_HOME": "/tmp/xdg-state"
    ]
  )
  #expect(directory == "/tmp/riela-credentials")
}

@Test func synthesizedConfigStoresTokensUnderCredentialDirectory() throws {
  let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmail-credential-dir-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: scratch) }
  let config = try GmailGatewayConfigLoader.loadConfig(
    environment: [
      "XDG_CONFIG_HOME": scratch.appendingPathComponent("config").path,
      "GMAIL_GATEWAY_CREDENTIAL_DIR": "/tmp/riela-credentials"
    ]
  )
  #expect(config.credentials.first?.tokenStorePath == "/tmp/riela-credentials/gmail-personal.json")
}
