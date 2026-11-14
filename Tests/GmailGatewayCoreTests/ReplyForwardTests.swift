import Foundation
import Testing
@testable import GmailGatewayCore

private func decodedRawMessage(_ raw: String) throws -> String {
    let data = try #require(dataFromBase64URLString(raw))
    return try #require(String(data: data, encoding: .utf8))
}

private func testOriginalMessage(
    subject: String? = "Original subject",
    from: [String] = ["Sender <sender@example.com>"],
    to: [String] = ["person@example.com"],
    cc: [String] = [],
    replyTo: [String] = [],
    rfc822MessageId: String? = "<original@mail.example.com>",
    referencesHeader: String? = nil
) -> MailMessage {
    MailMessage(
        id: "message-1",
        threadId: "thread-1",
        accountId: "personal",
        subject: subject,
        from: from.map { MailAddress(raw: $0) },
        to: to.map { MailAddress(raw: $0) },
        cc: cc.map { MailAddress(raw: $0) },
        bcc: [],
        replyTo: replyTo.map { MailAddress(raw: $0) },
        sentAt: "2026-08-24T00:00:00Z",
        receivedAt: "2026-08-24T00:00:00Z",
        snippet: nil,
        attachments: [],
        labels: ["INBOX"],
        historyId: nil,
        providerMetadata: nil,
        rfc822MessageId: rfc822MessageId,
        referencesHeader: referencesHeader
    )
}

@Test func replyDefaultsRecipientsToOriginalSenderAndThreadsMail() throws {
    let input = ReplyMessageInput(accountId: "personal", messageId: "message-1", textBody: "Reply body")
    let outbound = plannedReplyMail(
        input: input,
        original: testOriginalMessage(referencesHeader: "<root@mail.example.com>"),
        accountEmail: "person@example.com"
    )

    #expect(outbound.to == ["Sender <sender@example.com>"])
    #expect(outbound.cc.isEmpty)
    #expect(outbound.subject == "Re: Original subject")
    #expect(outbound.threadId == "thread-1")
    #expect(outbound.inReplyTo == "<original@mail.example.com>")
    #expect(outbound.references == "<root@mail.example.com> <original@mail.example.com>")
    #expect(outbound.textBody == "Reply body")
}

@Test func replyPrefersReplyToHeaderOverFrom() throws {
    let input = ReplyMessageInput(accountId: "personal", messageId: "message-1", textBody: "Reply body")
    let outbound = plannedReplyMail(
        input: input,
        original: testOriginalMessage(replyTo: ["list@example.com"]),
        accountEmail: "person@example.com"
    )

    #expect(outbound.to == ["list@example.com"])
}

@Test func replyAllAddsOtherRecipientsWithoutSelfOrDuplicates() throws {
    let input = ReplyMessageInput(
        accountId: "personal",
        messageId: "message-1",
        replyAll: true,
        textBody: "Reply body"
    )
    let outbound = plannedReplyMail(
        input: input,
        original: testOriginalMessage(
            to: ["Person <PERSON@example.com>", "other@example.com"],
            cc: ["copy@example.com", "sender@example.com"]
        ),
        accountEmail: "person@example.com"
    )

    #expect(outbound.to == ["Sender <sender@example.com>"])
    #expect(outbound.cc == ["other@example.com", "copy@example.com"])
}

@Test func replyKeepsExistingReSubjectPrefix() throws {
    let input = ReplyMessageInput(accountId: "personal", messageId: "message-1", textBody: "Reply body")
    let outbound = plannedReplyMail(
        input: input,
        original: testOriginalMessage(subject: "RE: Original subject"),
        accountEmail: "person@example.com"
    )

    #expect(outbound.subject == "RE: Original subject")
}

@Test func replyExplicitRecipientsOverrideDefaults() throws {
    let input = ReplyMessageInput(
        accountId: "personal",
        messageId: "message-1",
        to: ["explicit@example.com"],
        textBody: "Reply body"
    )
    let outbound = plannedReplyMail(
        input: input,
        original: testOriginalMessage(),
        accountEmail: "person@example.com"
    )

    #expect(outbound.to == ["explicit@example.com"])
}

@Test func forwardQuotesOriginalBodyWithHeaderBlock() throws {
    let input = ForwardMessageInput(
        accountId: "personal",
        messageId: "message-1",
        to: ["destination@example.com"],
        textBody: "FYI"
    )
    let bodyFiles = [
        GmailMessageBodyFile(
            kind: .bodyText,
            filename: "body.txt",
            mimeType: "text/plain",
            data: Data("Original text body".utf8)
        )
    ]
    let outbound = plannedForwardMail(
        input: input,
        original: testOriginalMessage(),
        bodyFiles: bodyFiles,
        inlineAttachments: []
    )

    #expect(outbound.to == ["destination@example.com"])
    #expect(outbound.subject == "Fwd: Original subject")
    #expect(outbound.threadId == "thread-1")
    #expect(outbound.inReplyTo == nil)
    #expect(outbound.references == "<original@mail.example.com>")
    let text = try #require(outbound.textBody)
    #expect(text.hasPrefix("FYI\n\n---------- Forwarded message ----------"))
    #expect(text.contains("From: Sender <sender@example.com>"))
    #expect(text.contains("Subject: Original subject"))
    #expect(text.contains("Original text body"))
}

@Test func forwardBuildsHtmlQuoteFromOriginalHtml() throws {
    let input = ForwardMessageInput(
        accountId: "personal",
        messageId: "message-1",
        to: ["destination@example.com"],
        textBody: "See <below>"
    )
    let bodyFiles = [
        GmailMessageBodyFile(
            kind: .bodyHTML,
            filename: "body.html",
            mimeType: "text/html",
            data: Data("<p>Original html body</p>".utf8)
        )
    ]
    let outbound = plannedForwardMail(
        input: input,
        original: testOriginalMessage(),
        bodyFiles: bodyFiles,
        inlineAttachments: []
    )

    let html = try #require(outbound.htmlBody)
    #expect(html.contains("See &lt;below&gt;"))
    #expect(html.contains("<blockquote"))
    #expect(html.contains("<p>Original html body</p>"))
}

@Test func forwardWithoutNoteStillHasHeaderBlockBody() throws {
    let input = ForwardMessageInput(
        accountId: "personal",
        messageId: "message-1",
        to: ["destination@example.com"]
    )
    let outbound = plannedForwardMail(
        input: input,
        original: testOriginalMessage(),
        bodyFiles: [],
        inlineAttachments: []
    )

    let text = try #require(outbound.textBody)
    #expect(text.hasPrefix("---------- Forwarded message ----------"))
    #expect(outbound.htmlBody == nil)
}

@Test func forwardCarriesInlineAttachments() throws {
    let inlineAttachment = OutboundInlineAttachment(
        filename: "report.pdf",
        mimeType: "application/pdf",
        data: Data("payload".utf8)
    )
    let outbound = plannedForwardMail(
        input: ForwardMessageInput(accountId: "personal", messageId: "message-1", to: ["destination@example.com"]),
        original: testOriginalMessage(),
        bodyFiles: [],
        inlineAttachments: [inlineAttachment]
    )

    #expect(outbound.inlineAttachments.count == 1)
    #expect(outbound.inlineAttachments.first?.filename == "report.pdf")
}

@Test func rawMessageIncludesThreadingHeadersAndInlineAttachment() throws {
    let input = OutboundMailInput(
        accountId: "personal",
        to: ["destination@example.com"],
        subject: "Fwd: Original subject",
        textBody: "Body",
        threadId: "thread-1",
        inReplyTo: "<original@mail.example.com>",
        references: "<root@mail.example.com> <original@mail.example.com>",
        inlineAttachments: [
            OutboundInlineAttachment(
                filename: "report.pdf",
                mimeType: "application/pdf",
                data: Data("payload".utf8)
            )
        ]
    )

    let message = try decodedRawMessage(buildRawMessage(
        from: "person@example.com",
        input: input,
        attachmentPaths: []
    ))

    #expect(message.contains("In-Reply-To: <original@mail.example.com>"))
    #expect(message.contains("References: <root@mail.example.com> <original@mail.example.com>"))
    #expect(message.contains("Content-Type: multipart/mixed; boundary="))
    #expect(message.contains("Content-Type: application/pdf; name=\"report.pdf\""))
    #expect(message.contains("Content-Disposition: attachment; filename=\"report.pdf\""))
}

@Test func normalizedAddressSpecExtractsAngleAddress() {
    #expect(normalizedAddressSpec("\"Doe, John\" <JD@Example.com>") == "jd@example.com")
    #expect(normalizedAddressSpec(" plain@example.com ") == "plain@example.com")
}

@Test func readerRejectsReplyAndForwardMutations() throws {
    let replyResult = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ replyMessage(input: { accountId: "personal", messageId: "m1", textBody: "Body" }) { messageId } }"#
    )
    let forwardResult = try executeReaderGraphQL(
        config: testConfig(paths: temporaryConfigPaths()),
        query: #"{ forwardMessage(input: { accountId: "personal", messageId: "m1", to: ["a@example.com"] }) { messageId } }"#
    )

    #expect(replyResult.exitCode == .graphqlExecutionError)
    #expect("\(replyResult.body)".contains("SEND_DISABLED_IN_READER"))
    #expect(forwardResult.exitCode == .graphqlExecutionError)
    #expect("\(forwardResult.body)".contains("SEND_DISABLED_IN_READER"))
}

@Test func replyMutationRequiresReadSendAccessMode() throws {
    let paths = temporaryConfigPaths()
    defer {
        try? FileManager.default.removeItem(atPath: paths.root)
    }
    let config = testConfig(paths: paths, accessMode: .read)
    let result = try executeWriteGraphQL(
        config: config,
        query: #"{ replyMessage(input: { accountId: "personal", messageId: "m1", textBody: "Body" }) { messageId } }"#,
        mode: .directSend
    )

    #expect(result.exitCode == .graphqlExecutionError)
    #expect("\(result.body)".contains("read_send"))
}
