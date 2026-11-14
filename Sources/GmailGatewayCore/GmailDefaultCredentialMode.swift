import Foundation

extension GmailGatewayCLIMode {
    /// Only applies when the implicit default configuration does not exist.
    var synthesizedAccessMode: AccessMode {
        switch self {
        case .reader: return .read
        case .draftGateway, .directSender: return .readSend
        case .mailboxThreads: return .readModify
        case .messageBox: return .full
        }
    }
}
