import GatewaySDKKit
import Testing
@testable import GmailGatewayCore

@Test func gmailCatalogsValidateAndAuthorizeExactModes() {
    #expect(GatewaySchemaCatalog.gmailFull.validate().isEmpty)
    for mode in [GmailGatewayCLIMode.reader, .draftGateway, .directSender, .mailboxThreads, .messageBox] {
        #expect(GatewaySchemaCatalog.gmail(mode: mode).validate().isEmpty)
    }
    #expect(GatewaySchemaCatalog.gmail(mode: .reader).operation(named: "sendMessage") == nil)
    #expect(GatewaySchemaCatalog.gmail(mode: .directSender).operation(named: "sendMessage") != nil)
    #expect(GatewaySchemaCatalog.gmail(mode: .mailboxThreads).operation(named: "importMessage") == nil)
    #expect(GatewaySchemaCatalog.gmail(mode: .messageBox).operation(named: "importMessage") != nil)
}

@Test func readerRejectsAuthorizedFullMutationBeforeResolver() async {
    let envelope = await GmailGatewayGraphQLExecutor().run(
        query: "mutation { sendMessage(input: { accountId: \"a\", to: [\"x@example.test\"], textBody: \"x\" }) { status } }",
        mode: .reader,
        environment: [:]
    )
    #expect(envelope.exitCode == 1)
    #expect(envelope.errors.first?.code == "CAPABILITY_DENIED")
}

@Test func schemaAndSearchDoNotNeedConfiguration() {
    let cli = GmailGatewayCLI(mode: .reader)
    let schema = cli.run(arguments: ["graphql", "schema"])
    #expect(schema.exitCode == 0)
    #expect(schema.stdout.contains("type Query"))
    let search = cli.run(arguments: ["graphql", "search", "threads", "--limit", "2"])
    #expect(search.exitCode == 0)
    #expect(search.stdout.contains("threads"))
}

@Test func operationBuilderUsesVariablesAndRequiredInputShape() async {
    let sdk = GmailGatewaySDK(mode: .reader)
    let result = await sdk.invoke(.init(operation: "threads", variables: ["input": .object(["accountId": .string("missing")])], selection: .fields(["totalCount"])), environment: [:])
    #expect(result.exitCode == 1)
    #expect(result.errors.first?.code != "SYNTAX")
}
