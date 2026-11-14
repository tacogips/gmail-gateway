import Foundation
@testable import MailGatewayCore
import Testing

@Test func graphQLScannerIgnoresCommentedWriteField() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }

    let result = try executeReaderGraphQL(
        config: testConfig(paths: paths),
        query: """
        {
          # sendMessage(input: { accountId: "personal", to: ["a@example.com"] }) { messageId }
          accounts { id }
        }
        """
    )

    #expect(result.exitCode == .success)
    #expect(!"\(result.body)".contains("SEND_DISABLED_IN_READER"))
    #expect("\(result.body)".contains("accounts"))
}

@Test func graphQLScannerKeepsHashInsideStringArgument() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ account(id: "personal#not-a-comment") { id } }"#
    )

    #expect(result.exitCode == .success)
    #expect(result.body["data"] != nil)
}

@Test func graphQLScannerRejectsMultipleRootFields() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ accounts { id } account(id: "personal") { id } }"#
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("Multiple GraphQL root fields are not supported"))
}

@Test func graphQLScannerRejectsFragmentsAndSpreads() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: """
        {
          accounts { ...AccountFields }
        }
        fragment AccountFields on MailAccount { id }
        """
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("GraphQL fragments and spreads are not supported"))
}

@Test func threadsRejectsUnsupportedDirectArguments() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ threads(accountId: "personal", unread: true) { totalCount } }"#
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("Unsupported threads argument(s): unread"))
}

@Test func threadsAllowsSupportedDirectArguments() throws {
    let result = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ threads(accountId: "personal", first: 0) { totalCount } }"#
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("ThreadSearchInput.first"))
    #expect(!"\(result.body)".contains("Unsupported threads argument"))
}
