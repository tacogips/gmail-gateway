import GmailGatewayCore

func testPersistentAuthHelpSnapshots() throws {
    let targetModes: [GmailGatewayCLIMode] = [.reader, .directSender, .draftGateway]
    for mode in targetModes {
        let policy: GmailAuthPolicy
        switch mode {
        case .reader:
            policy = .persistent(requiredAccessMode: .read)
        case .directSender, .draftGateway:
            policy = .persistent(requiredAccessMode: .readSend)
        case .mailboxThreads, .messageBox:
            throw SmokeTestFailure.assertionFailed("excluded mode entered persistent smoke test")
        }
        let cli = GmailGatewayCLI(mode: mode, authPolicy: policy)
        let result = cli.run(arguments: ["--help"], environment: [:])
        guard result.exitCode == 0, result.stdout.contains("auth <setup|login|revoke|status>") else {
            throw SmokeTestFailure.assertionFailed("persistent target help regression")
        }
    }
}
