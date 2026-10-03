import Foundation
import SwiftMail
import SwiftSoup
import Logging

/// A connection belongs to exactly one operation/account. No global credential/session cache.
nonisolated struct NativeMailService: NativeMailServing {
    // SwiftMail logs server responses and MIME metadata. The app currently has no other
    // swift-log clients; install a no-op backend once, before creating any mail connection.
    private static let configureLogging: Void = LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }

    @concurrent
    private func withIMAP<T: Sendable>(credentials: MailCredentials,
                                      operation: @Sendable (IMAPServer) async throws -> T) async throws -> T {
        _ = Self.configureLogging
        let server = IMAPServer(host: "mail.niu.edu.tw", port: 993, transportSecurity: .implicitTLS,
                                responseBufferLimit: 20 * 1024 * 1024,
                                parserLimits: IMAPParserLimits(bodySizeLimit: 20 * 1024 * 1024,
                                                              messageAttributeLimit: 1024))
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await server.connect()
                try Task.checkCancellation()
                try await server.login(username: credentials.username, password: credentials.password)
                try Task.checkCancellation()
                let result = try await operation(server)
                // Disconnect errors cannot invalidate an already received result.
                try? await server.disconnect()
                try Task.checkCancellation()
                return result
            } catch {
                // Also close after a connect finishes racing cancellation.
                try? await server.disconnect()
                if Task.isCancelled { throw CancellationError() }
                throw Self.readError(error)
            }
        } onCancel: {
            Task { try? await server.disconnect() }
        }
    }

    @concurrent
    func inbox(credentials: MailCredentials, folder: String, limit: Int) async throws -> MailInboxSnapshot {
        try await withIMAP(credentials: credentials) { server in
            let allFolders = try await server.listMailboxes()
            var folders: [MailFolder] = allFolders.filter(\.isSelectable).map {
                MailFolder(id: $0.name, name: $0.name, role: Self.folderRole($0))
            }.sorted { ($0.role == .inbox ? "" : $0.title) < ($1.role == .inbox ? "" : $1.title) }
            // STATUS is cheap for a small folder set. Large accounts probe only the active folder.
            for index in folders.indices where folders.count <= 12 || folders[index].id == folder {
                try Task.checkCancellation()
                folders[index].unreadCount = try? await server.mailboxStatus(folders[index].id).unseenCount
            }
            try Task.checkCancellation()
            let selection = try await server.examineMailbox(folder)
            guard selection.uidValidity.value > 0 else { throw NativeMailError.invalidResponse }
            let count = selection.messageCount
            guard count > 0 else { return MailInboxSnapshot(folders: folders, messages: [], total: 0) }
            let start = max(1, count - min(1000, max(1, limit)) + 1)
            var summaries: [MailSummary] = []
            // Bound each FETCH and check cancellation between chunks.
            for lower in stride(from: start, through: count, by: 50) {
                try Task.checkCancellation()
                let headers = try await server.fetchMessageInfos(
                    sequenceRange: SequenceNumber(UInt32(lower))...SequenceNumber(UInt32(min(count, lower + 49))),
                    options: [.envelope, .internalDate, .flags, .bodyStructure])
                for header in headers where !header.flags.contains(.deleted) {
                    guard let uid = header.uid, uid.value > 0 else { throw NativeMailError.invalidResponse }
                    let structure = Message(header: header, parts: header.parts)
                    var preview: String?
                    // Every message in this <=50-message chunk gets at most 1 KiB
                    // BODY.PEEK. Never download attachments or a complete message.
                    // A truncated transfer encoding may not decode; omit that preview.
                    if var part = structure.bodies.first(where: { $0.contentType.lowercased().hasPrefix("text/plain") }) {
                        part.data = try? await server.fetchPart(section: part.section, of: uid, offset: 0, count: 1024)
                        preview = part.textContent.map { String($0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(240)) }
                    }
                    try Task.checkCancellation()
                    let sender = header.fromAddresses.mailboxes.first
                    summaries.append(MailSummary(
                        id: MailMessageKey(folder: folder, validity: selection.uidValidity.value, uid: uid.value),
                        subject: header.subject.flatMap { $0.isEmpty ? nil : $0 } ?? "（無主旨）",
                        sender: header.from ?? "未知寄件者", date: header.date ?? header.internalDate,
                        unread: !header.flags.contains(.seen), to: header.to, cc: header.cc,
                        hasAttachment: !Self.catalog(structure).attachments.isEmpty, flagged: header.flags.contains(.flagged),
                        preview: preview, senderName: sender?.name ?? "", senderAddress: sender?.address ?? ""))
                }
            }
            // UID is stable within UIDVALIDITY, unlike changing sequence numbers.
            let unique = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return MailInboxSnapshot(folders: folders, messages: unique.values.sorted { $0.id.uid > $1.id.uid }, total: count)
        }
    }

    private static func catalog(_ message: Message) -> MailPartCatalog {
        let attachments = Set(message.attachments.map { $0.section.description })
        return MailPartCatalog(message.parts.map { part in
            // SwiftMail 會以 CID 填入 filename，因此保守地將相同值視為沒有原始檔名。
            let cidFallback = part.contentId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")).decodeMIMEHeader()
            let named = MailPartMetadata.hasOriginalFilename(part.filename, cidFallback: cidFallback)
            let name = named ? part.suggestedFilename
                : MessagePart(section: part.section, contentType: part.contentType).suggestedFilename
            return MailPartMetadata(info: MailAttachmentInfo(id: part.section.description, name: name,
                size: part.size, mime: part.contentType, contentID: part.contentId, hasFilename: named),
                disposition: part.disposition, isAttachment: attachments.contains(part.section.description))
        })
    }

    private static func header(server: IMAPServer, key: MailMessageKey) async throws -> MessageInfo {
        let selected = try await server.examineMailbox(key.folder)
        guard selected.uidValidity.value == key.validity else { throw NativeMailError.changedMailbox }
        try Task.checkCancellation()
        guard let header = try await server.fetchMessageInfo(for: UID(key.uid), options: [.envelope, .bodyStructure], headerFields: ["References"]) else {
            throw NativeMailError.missingMessage
        }
        return header
    }

    @concurrent
    func message(credentials: MailCredentials, key: MailMessageKey) async throws -> MailMessageContent {
        try await withIMAP(credentials: credentials) { server in
            let header = try await Self.header(server: server, key: key)
            let structure = Message(header: header, parts: header.parts)
            let plainPart = structure.bodies.first { $0.contentType.lowercased().hasPrefix("text/plain") }
            let htmlPart = structure.bodies.first { $0.contentType.lowercased().hasPrefix("text/html") }
            var plain: String?
            var html: String?
            var bodyError: Error?
            for candidate in [plainPart, htmlPart] {
                guard var part = candidate else { continue }
                do {
                    let limit = 2 * 1024 * 1024
                    guard (part.size ?? 0) <= limit else { throw NativeMailError.tooLarge }
                    try Task.checkCancellation()
                    part.data = try await server.fetchPart(section: part.section, of: UID(key.uid), offset: 0, count: limit + 1)
                    guard (part.data?.count ?? 0) <= limit else { throw NativeMailError.tooLarge }
                    guard let decoded = part.textContent else { throw NativeMailError.invalidResponse }
                    guard decoded.utf8.count <= limit else { throw NativeMailError.tooLarge }
                    if part.contentType.lowercased().hasPrefix("text/html") { html = decoded }
                    else { plain = decoded }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    bodyError = error
                }
            }
            if plain == nil && html == nil, let bodyError { throw bodyError }
            let text = try plain ?? html.map { try Self.plainTextHTML($0) } ?? "這封信沒有可顯示的文字本文。"
            let reply = header.replyToAddresses.mailboxes.first?.address ?? header.fromAddresses.mailboxes.first?.address ?? ""
            return MailMessageContent(text: text, simplifiedHTML: htmlPart != nil, replyAddress: Self.addressOnly(reply),
                                      messageID: header.messageId?.description,
                                      attachments: Self.catalog(structure).attachments, html: html,
                                      inlineImages: Self.catalog(structure).inlineImages, to: header.to, cc: header.cc, date: header.date ?? header.internalDate,
                                      replyAllTo: header.toAddresses.mailboxes.map(\.address).filter { $0.lowercased() != credentials.address.lowercased() },
                                      replyAllCC: header.ccAddresses.mailboxes.map(\.address).filter { $0.lowercased() != credentials.address.lowercased() },
                                      references: header.references?.map(\.description) ?? [],
                                      from: header.fromAddresses.mailboxes.map { MailAddress(name: $0.name ?? "", address: $0.address) },
                                      toRecipients: header.toAddresses.mailboxes.map { MailAddress(name: $0.name ?? "", address: $0.address) },
                                      ccRecipients: header.ccAddresses.mailboxes.map { MailAddress(name: $0.name ?? "", address: $0.address) },
                                      replyTo: header.replyToAddresses.mailboxes.map { MailAddress(name: $0.name ?? "", address: $0.address) })
        }
    }

    private static func selectForMutation(_ server: IMAPServer, key: MailMessageKey) async throws {
        let selected = try await server.selectMailbox(key.folder)
        guard selected.uidValidity.value == key.validity else { throw NativeMailError.changedMailbox }
        guard !selected.isReadOnly else { throw NativeMailError.unsafeMove }
        guard try await server.fetchMessageInfo(for: UID(key.uid), options: .uidFlagsOnly) != nil else {
            throw NativeMailError.missingMessage
        }
        try Task.checkCancellation()
    }

    func setSeen(credentials: MailCredentials, key: MailMessageKey, seen: Bool) async throws {
        try await withIMAP(credentials: credentials) { server in
            try await Self.selectForMutation(server, key: key)
            try await server.store(flags: [.seen], on: UIDSet(UID(key.uid)), operation: seen ? .add : .remove)
        }
    }

    func setFlagged(credentials: MailCredentials, key: MailMessageKey, flagged: Bool) async throws {
        try await withIMAP(credentials: credentials) { server in
            try await Self.selectForMutation(server, key: key)
            try await server.store(flags: [.flagged], on: UIDSet(UID(key.uid)), operation: flagged ? .add : .remove)
        }
    }

    func moveToTrash(credentials: MailCredentials, key: MailMessageKey, allowMarkDeleted: Bool) async throws {
        try await withIMAP(credentials: credentials) { server in
            let folders = try await server.listMailboxes()
            let trash = folders.first { $0.isSelectable && Self.folderRole($0) == .trash && $0.name != key.folder }
            guard trash != nil || allowMarkDeleted else { throw NativeMailError.noTrash }
            try await Self.selectForMutation(server, key: key)
            let uids = UIDSet(UID(key.uid))
            guard let trash, trash.name != key.folder else {
                guard allowMarkDeleted else { throw NativeMailError.noTrash }
                try await server.store(flags: [.deleted], on: uids, operation: .add)
                return
            }
            // Never allow the library's non-targeted EXPUNGE fallback.
            let move = await server.supportsMove
            let uidPlus = await server.supportsUIDPlus
            guard move || uidPlus else { throw NativeMailError.unsafeMove }
            do {
                if move {
                    try await server.move(message: UID(key.uid), to: trash.name, fallback: .disabled)
                } else {
                    try await server.copy(messages: uids, to: trash.name)
                    try Task.checkCancellation()
                    try await server.store(flags: [.deleted], on: uids, operation: .add)
                    try await server.expunge(messages: uids)
                }
            } catch {
                // COPY/MOVE may have partially completed. Never retry automatically.
                throw NativeMailError.mutationUncertain
            }
        }
    }

    @concurrent
    func attachment(credentials: MailCredentials, key: MailMessageKey, part: String, maximumBytes: Int) async throws -> Data {
        try await withIMAP(credentials: credentials) { server in
            let header = try await Self.header(server: server, key: key)
            let structure = Message(header: header, parts: header.parts)
            let catalog = Self.catalog(structure)
            guard (catalog.attachments + catalog.inlineImages).contains(where: { $0.id == part }),
                  var item = structure.parts.first(where: { $0.section.description == part }) else {
                throw NativeMailError.missingMessage
            }
            let limit = min(maximumBytes, MailDraft.attachmentLimit)
            guard limit >= 0, (item.size ?? 0) <= limit else { throw NativeMailError.tooLarge }
            try Task.checkCancellation()
            item.data = try await server.fetchPart(section: item.section, of: UID(key.uid), offset: 0, count: limit + 1)
            guard (item.data?.count ?? 0) <= limit,
                  let data = item.decodedData(), data.count <= limit else { throw NativeMailError.tooLarge }
            return data
        }
    }

    @concurrent
    func send(credentials: MailCredentials, draft: MailDraft) async throws -> MailSendOutcome {
        try draft.validate()
        _ = Self.configureLogging
        var email = Email(sender: EmailAddress(address: credentials.address),
                          recipients: try MailDraft.addresses(draft.to).map { EmailAddress(address: $0) },
                          ccRecipients: try MailDraft.addresses(draft.cc).map { EmailAddress(address: $0) },
                          bccRecipients: try MailDraft.addresses(draft.bcc).map { EmailAddress(address: $0) },
                          subject: draft.subject, textBody: draft.body,
                          attachments: draft.attachments.map { Attachment(filename: $0.name, mimeType: $0.mime, data: $0.data) })
        email.messageID = MessageID(draft.messageID)
        if let reference = draft.inReplyTo, let id = MessageID(reference) {
            let references = draft.references.compactMap { MessageID($0)?.description }
            email.additionalHeaders = ["In-Reply-To": id.description,
                                       "References": (references.isEmpty ? [id.description] : references).joined(separator: " ")]
        }
        let smtp = SMTPServer(host: "mail.niu.edu.tw", port: 465, transportSecurity: .implicitTLS)
        do {
            var submitted = false
            do {
                try Task.checkCancellation()
                try await smtp.connect()
                try Task.checkCancellation()
                try await smtp.login(username: credentials.username, password: credentials.password)
                try Task.checkCancellation()
                submitted = true
                try await smtp.sendEmail(email)
                // SMTP acceptance is final even if QUIT or sent-copy storage later fails.
                await Task { try? await smtp.disconnect() }.value
            } catch {
                await Task { try? await smtp.disconnect() }.value
                if submitted { throw Self.submissionError(error) }
                if Task.isCancelled { throw CancellationError() }
                if case SMTPError.authenticationFailed = error { throw NativeMailError.authentication }
                throw NativeMailError.connection
            }
        }
        let sentEmail = email
        do {
            try await withIMAP(credentials: credentials) { server in
                let folders = try await server.listMailboxes()
                guard let sent = folders.first(where: { $0.isSelectable && Self.folderRole($0) == .sent }) else {
                    throw NativeMailError.invalidResponse
                }
                try Task.checkCancellation()
                _ = try await server.append(email: sentEmail, to: sent.name, flags: [.seen])
            }
            return .accepted(copySaved: true)
        } catch {
            // Never retry SMTP when only the sent-folder copy failed.
            return .accepted(copySaved: false)
        }
    }

    static func plainTextHTML(_ html: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        try document.select("script,style,head,iframe,object").remove()
        for node in try document.select("br,p,div,li,tr,h1,h2,h3,blockquote").array() { try node.prependText("\n") }
        for link in try document.select("a[href]").array() {
            let href = try link.attr("href")
            if let url = URL(string: href), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                try link.appendText(" (\(href))")
            }
        }
        return try document.text(trimAndNormaliseWhitespace: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func addressOnly(_ value: String) -> String {
        if let start = value.lastIndex(of: "<"), let end = value.lastIndex(of: ">"), start < end {
            return String(value[value.index(after: start)..<end])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func folderRole(_ folder: Mailbox.Info) -> MailFolder.Role {
        if folder.attributes.contains(.inbox) || folder.name.uppercased() == "INBOX" { return .inbox }
        if folder.attributes.contains(.sent) { return .sent }
        if folder.attributes.contains(.drafts) { return .drafts }
        if folder.attributes.contains(.trash) { return .trash }
        if folder.attributes.contains(.junk) { return .junk }
        return .other
    }

    private static func readError(_ error: Error) -> Error {
        if error is NativeMailError || error is CancellationError { return error }
        if let error = error as? IMAPError {
            switch error {
            case .loginFailed, .authFailed, .unsupportedAuthMechanism: return NativeMailError.authentication
            case .timeout: return NativeMailError.timeout
            case .fetchFailed: return NativeMailError.invalidResponse
            default: break
            }
        }
        return NativeMailError.connection
    }

    private static func submissionError(_ error: Error) -> Error {
        if let failure = error as? SMTPSendError {
            switch failure.acceptance {
            case .ambiguous: return NativeMailError.deliveryUnknown
            case .rejectedTransiently, .rejectedPermanently: return NativeMailError.rejected
            case .notAccepted:
                switch failure.reason {
                case .cancelled: return CancellationError()
                case .timedOut: return NativeMailError.timeout
                case .connectionLost, .transport: return NativeMailError.connection
                case .reply: return NativeMailError.rejected
                }
            }
        }
        if let error = error as? SMTPError {
            switch error {
            case .invalidEmailAddress, .messageTooLarge: return NativeMailError.rejected
            case .unexpectedResponse(let response) where response.code >= 400: return NativeMailError.rejected
            default: break
            }
        }
        return NativeMailError.deliveryUnknown
    }
}
