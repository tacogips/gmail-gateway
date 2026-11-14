import Testing
@testable import MailGatewayCore

@Test func readerHelpUsesReaderExecutableName() {
    let result = MailGatewayCLI().run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-reader"))
}

@Test func draftHelpUsesDraftExecutableName() {
    let result = MailGatewayCLI(mode: .draftGateway).run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-draft"))
}

@Test func senderHelpUsesSenderExecutableName() {
    let result = MailGatewayCLI(mode: .directSender).run(arguments: ["--help"], environment: [:])
    #expect(result.exitCode == MailGatewayExitCode.success.rawValue)
    #expect(result.stdout.contains("mail-gateway-sender"))
}
