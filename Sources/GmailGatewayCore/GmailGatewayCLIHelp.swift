import Foundation

func rootHelpText(mode: GmailGatewayCLIMode) -> String {
    let executableName = mode.executableName
    let authCommand = switch mode {
    case .reader, .draftGateway, .directSender:
        "auth login [--credential <id>] | auth <status|refresh> [--credential <id>] | auth <setup|revoke> --credential <id>"
    case .mailboxThreads, .messageBox:
        "auth login [--credential <id>] | auth <revoke|status> --credential <id>"
    }
    let persistentAuthText = switch mode {
    case .reader, .draftGateway, .directSender:
        """
        Persistent auth setup/revoke:
          auth setup --credential <id> --client-secret-path <path>
                     [--replace --confirm-credential <id>]
          auth revoke --credential <id> --confirm-credential <id>

        """
    case .mailboxThreads, .messageBox:
        ""
    }
    let writeNote: String
    switch mode {
    case .reader:
        writeNote = """
          This binary is read-only. Mutations outside its authorized GraphQL catalog are
          rejected with CAPABILITY_DENIED before resolver or provider dispatch.
          Read surface: accounts, account, threads, thread, message, messageFileSet,
          attachment, labels, and profile.
        """
    case .draftGateway:
        writeNote = """
          This binary is draft-only. It supports createDraft, createReplyDraft,
          createForwardDraft, updateDraft, and deleteDraft, plus the drafts and draft
          queries, and it can never send mail. createReplyDraft and createForwardDraft
          prepare threaded reply and forward drafts without sending them.
          sendMessage, replyMessage, forwardMessage, and sendDraft are rejected with
          CAPABILITY_DENIED before resolver or provider dispatch; use
          gmail-gateway-sender for those.

          updateDraft retains any header or body field it is not given. Supplying textBody
          and/or htmlBody replaces the whole body with exactly what was supplied. Attachments
          already on the draft are all retained unless keepAttachmentIds is given, in which case
          only the listed provider attachment ids survive; attachmentPaths adds local files on
          top, so keepAttachmentIds: [] with attachmentPaths replaces every attachment.
        """
    case .directSender:
        writeNote = """
          This binary is the explicit sender. sendMessage directly sends mail through the provider,
          replyMessage and forwardMessage directly send threaded replies and forwards, and
          sendDraft sends a draft that gmail-gateway-draft already prepared.
          It also supports the full draft surface: createDraft, createReplyDraft,
          createForwardDraft, updateDraft, deleteDraft, and the drafts and draft queries.
        """
    case .mailboxThreads:
        writeNote = """
          This binary mutates stored mail and never composes, sends, or ingests it.
          Label changes:  modifyThreadLabels, modifyMessageLabels, batchModifyMessageLabels
          Trash:          trashThread, untrashThread, trashMessage, untrashMessage
          Label managing: createLabel, updateLabel, deleteLabel
          Permanent:      deleteThread, deleteMessage, batchDeleteMessages

          Trash and label mutations need the read_modify access mode. The three permanent
          delete mutations are irreversible, bypass Trash, and need the full access mode,
          because the provider accepts only its full-access scope for them. Prefer
          trashThread and trashMessage unless a caller truly means to destroy mail.

          Draft, send, and ingest mutations are rejected here; use gmail-gateway-draft,
          gmail-gateway-sender, or gmail-gateway-message-box.
        """
    case .messageBox:
        writeNote = """
          This binary ingests existing RFC 822 mail into the mailbox and never composes,
          sends, or mutates stored mail. It supports importMessage and insertMessage, and
          needs the read_modify access mode.

          importMessage runs the normal delivery pipeline (spam classification, Calendar
          processing) and accepts neverMarkSpam and processForCalendar. insertMessage is a
          direct IMAP-APPEND-style add that bypasses most scanning. Neither sends mail.

          rfc822Path must resolve under a configured storage.allowed_send_attachment_roots
          entry, the same rule outbound attachments follow.

          Draft, send, and mailbox mutations are rejected here; use gmail-gateway-draft,
          gmail-gateway-sender, or gmail-gateway-threads.
        """
    }

    return """
\(executableName)

Usage:
  \(executableName) [--config <path>] [--pretty] <command>

Commands:
  doctor
  graphql [query] --query <query>|--query-file <path> [--variables <json>|--variables-file <path>] [--pretty]
  graphql schema
  graphql search <regex> [--kinds query,mutation,object,inputObject,enumeration] [--include-referenced-types] [--limit <n>]
  graphql operation <name> [--variables <json>|--variables-file <path>] [--select a.b,c]
  config validate
  \(authCommand)
  cache prune [--account <id>|--all]
  file download --key <download-key> [--key <download-key> ...] [--output-dir <dir>]
  --version

Auth login options:
  --redirect-uri <uri>       Optional registered loopback callback URI
                             (127.0.0.1, ::1, or localhost). Defaults to the
                             first stored redirect; a portless URI gets a
                             local ephemeral port while preserving its path.
  --open-browser <true|false>
                             Open the authorization URL automatically. Defaults to true.
  --timeout-seconds <n>      Seconds to wait for the OAuth2 callback. Defaults to 300.

\(persistentAuthText)

Write behavior:
\(writeNote)

File downloads:
  GraphQL returns attachment, body, and temporary-file metadata with
  vendor-neutral downloadKey values, not file payloads. Use file download when
  a caller explicitly needs selected file bytes. Repeat --key to download
  multiple selected files in one command.

  Single-key downloads return a single file JSON object with localPath.
  Multi-key downloads return {"fileCount": n, "files": [...]} and copy files
  under <output-dir>/<accountId>/<messageId>/<filename> to avoid collisions.

Examples:
  \(executableName) file download --config ./config.toml --key <key> --output-dir ./downloads
  \(executableName) file download --config ./config.toml --key <key-1> --key <key-2> --output-dir ./downloads

"""
}

func fileHelpText(executableName: String) -> String {
    """
\(executableName) file download

Usage:
  \(executableName) file download --key <download-key> [--key <download-key> ...] [--output-dir <dir>]

Options:
  --key <download-key>    Vendor-neutral key returned by GraphQL file metadata.
                          Repeat this option to download multiple files.
  --output-dir <dir>      Optional destination under storage.attachment_dir,
                          storage.cache_dir, or the system temporary directory.

Output:
  With one --key, returns the existing single-file JSON object:
    {"kind":"BODY_TEXT","filename":"body.txt","localPath":"..."}

  With multiple --key values, returns:
    {"fileCount":2,"files":[...]}

  Batch downloads copy files under <output-dir>/<accountId>/<messageId>/<filename>
  so files from different messages cannot overwrite each other.

"""
}

