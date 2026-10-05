import Foundation

nonisolated struct MailCredentials: Sendable {
    let username: String
    let password: String
    var address: String { username.contains("@") ? username : username + "@niu.edu.tw" }
}

nonisolated struct MailFolder: Identifiable, Sendable, Hashable {
    enum Role: Sendable { case inbox, sent, drafts, trash, junk, other }
    let id: String
    let name: String
    var role: Role = .other
    var unreadCount: Int? = nil
    var title: String {
        switch role {
        case .inbox: return "收件匣"
        case .sent: return "寄件備份"
        case .drafts: return "草稿"
        case .trash: return "垃圾桶"
        case .junk: return "垃圾郵件"
        case .other: return name
        }
    }
    var symbol: String {
        switch role {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .other: return "folder"
        }
    }
}

nonisolated struct MailMessageKey: Hashable, Sendable {
    let folder: String
    let validity: UInt32
    let uid: UInt32
}

nonisolated struct MailSummary: Identifiable, Sendable, Hashable {
    let id: MailMessageKey
    let subject: String
    let sender: String
    let date: Date?
    var unread: Bool
    var to: [String] = []
    var cc: [String] = []
    var hasAttachment = false
    var flagged = false
    var preview: String? = nil
    var senderName: String = ""
    var senderAddress: String = ""
    var displayName: String { senderName.isEmpty ? sender : senderName }
}

nonisolated struct MailInboxSnapshot: Sendable {
    let folders: [MailFolder]
    let messages: [MailSummary]
    let total: Int
}

nonisolated struct MailAttachmentInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let size: Int? // BODYSTRUCTURE transfer-encoded octets, not decoded bytes.
    var mime: String = "application/octet-stream"
    var contentID: String? = nil
    var hasFilename: Bool = true
    var encoding: String? = nil
}

/// BODYSTRUCTURE metadata only; nested message/rfc822 contents belong to that message.
nonisolated struct MailPartMetadata: Sendable {
    let info: MailAttachmentInfo
    let disposition: String?
    let isAttachment: Bool

    static func hasOriginalFilename(_ filename: String?, cidFallback: String?) -> Bool {
        let filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
        guard let filename, !filename.isEmpty else { return false }
        guard let cidFallback = cidFallback?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) else { return true }
        return filename.caseInsensitiveCompare(cidFallback) != .orderedSame
    }
}

nonisolated struct MailPartCatalog: Sendable {
    let attachments: [MailAttachmentInfo]
    let inlineImages: [MailAttachmentInfo]

    init(_ parts: [MailPartMetadata]) {
        let embedded = parts.filter { $0.info.mime.lowercased().hasPrefix("message/rfc822") }.map { $0.info.id + "." }
        var seen = Set<String>()
        let own = parts.filter { part in
            !embedded.contains(where: { part.info.id.hasPrefix($0) }) && seen.insert(part.info.id).inserted
        }
        attachments = own.filter {
            $0.isAttachment || ($0.info.hasFilename && ($0.disposition?.lowercased() == "inline" ||
                ($0.info.mime.lowercased().hasPrefix("image/") && $0.info.contentID != nil)))
        }.map(\.info)
        inlineImages = own.filter {
            $0.info.mime.lowercased().hasPrefix("image/") &&
                ($0.info.contentID != nil || $0.disposition?.lowercased() == "inline")
        }.map(\.info)
    }
}

nonisolated enum MailTransferPolicy {
    // Base64 uses 4 * ceil(decoded / 3) bytes. Allow another 4% (rounded up)
    // for MIME CRLF wrapping (~3.125% at 64 columns, ~2.63% at 76). Other encodings share this
    // bounded transport allowance; decoded payloads still have their own cap.
    static let base64LineBreakPercent = 4
    static let attachmentEncodedLimit = encodedAllowance(MailDraft.attachmentLimit)
    // <=20.8 MiB encoded body (+1 sentinel); 22 MiB parser working buffer
    // leaves room for FETCH framing. Decoded data is separately capped at 15 MiB.
    // These are per-response/payload bounds, not a total process-memory ceiling:
    // the two-job queue and SwiftMail/Data decoding copies can coexist.
    static let responseBufferLimit = 22 * 1024 * 1024

    private static func encodedAllowance(_ decoded: Int) -> Int {
        let base64 = ((decoded + 2) / 3) * 4
        return base64 + (base64 * base64LineBreakPercent + 99) / 100
    }

    static func encodedLimit(for maximumDecodedBytes: Int) throws -> Int {
        guard maximumDecodedBytes >= 0 else { throw NativeMailError.tooLarge }
        return encodedAllowance(min(maximumDecodedBytes, MailDraft.attachmentLimit))
    }

    static func validateEncodedSize(_ size: Int, maximumDecodedBytes: Int) throws {
        guard size >= 0, size <= (try encodedLimit(for: maximumDecodedBytes)) else { throw NativeMailError.tooLarge }
    }

    static func validateDecodedSize(_ size: Int, maximumBytes: Int) throws {
        guard size >= 0, size <= min(maximumBytes, MailDraft.attachmentLimit) else { throw NativeMailError.tooLarge }
    }
}

nonisolated enum MailInlinePolicy {
    static let imageLimit = 10 * 1024 * 1024
    static let messageLimit = 15 * 1024 * 1024

    static func automaticLimits(_ images: [MailAttachmentInfo]) -> [String: Int] {
        var remaining = messageLimit
        var result: [String: Int] = [:]
        for image in images {
            // Reserve decoded budgets before concurrent jobs start. Never trust
            // BODYSTRUCTURE as the actual decoded size; each fetch enforces its budget.
            guard result[image.id] == nil, let size = image.size, size >= 0 else { continue }
            let cap = min(imageLimit, remaining)
            let budget: Int
            if image.encoding?.lowercased() == "base64" {
                guard let encodedCap = try? MailTransferPolicy.encodedLimit(for: cap), size <= encodedCap else { continue }
                // Round up incomplete groups for unpadded Base64; counting
                // whitespace/padding as payload also overestimates, safely.
                // Clamp at the enforced cap so a wrapped 10 MiB image is eligible.
                budget = min(cap, ((size + 3) / 4) * 3)
            } else {
                guard size <= cap else { continue }
                budget = size
            }
            result[image.id] = budget
            remaining -= budget
        }
        return result
    }

    static func automaticIDs(_ images: [MailAttachmentInfo]) -> Set<String> {
        Set(automaticLimits(images).keys)
    }
}

nonisolated struct MailAddress: Sendable, Equatable {
    let name: String
    let address: String

    init(name: String = "", address: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Summary fallback while the already-requested message envelope is loading.
    init(displayString: String) {
        if let start = displayString.lastIndex(of: "<"), let end = displayString.lastIndex(of: ">"), start < end {
            self.init(name: String(displayString[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                address: String(displayString[displayString.index(after: start)..<end]))
        } else {
            self.init(address: displayString)
        }
    }

    var displayName: String { name.isEmpty ? address : name }
    var fullDescription: String { name.isEmpty || name == address ? address : "\(name) <\(address)>" }
}

nonisolated enum MailHeaderPresentation {
    static func addresses(structured: [MailAddress]?, detail: [String]?, summary: [String]) -> [MailAddress] {
        let structured = (structured ?? []).filter { !$0.displayName.isEmpty }
        if !structured.isEmpty { return structured }
        let detail = (detail ?? []).map { MailAddress(displayString: $0) }.filter { !$0.displayName.isEmpty }
        if !detail.isEmpty { return detail }
        return summary.map { MailAddress(displayString: $0) }.filter { !$0.displayName.isEmpty }
    }

    static func recipientSummary(_ recipients: [MailAddress]) -> String {
        recipientLabel(recipients) + (recipientCountLabel(recipients).map { " " + $0 } ?? "")
    }

    static func recipientLabel(_ recipients: [MailAddress]) -> String {
        "收件人：\(recipients.first?.displayName ?? "未提供")"
    }

    static func recipientCountLabel(_ recipients: [MailAddress]) -> String? {
        recipients.count > 1 ? "等 \(recipients.count) 人" : nil
    }

    static func distinctReplyTo(_ replyTo: [MailAddress], from senders: [MailAddress]) -> [MailAddress] {
        let senderAddresses = Set(senders.map { $0.address.lowercased() })
        let replyAddresses = Set(replyTo.map { $0.address.lowercased() })
        return replyAddresses == senderAddresses ? [] : replyTo
    }

    static func headerDate(_ date: Date) -> String {
        formattedDate(date, includingWeekday: false)
    }

    static func fullDate(_ date: Date) -> String {
        formattedDate(date, includingWeekday: true)
    }

    private static func formattedDate(_ date: Date, includingWeekday: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy年M月d日 " + (includingWeekday ? "EEEE " : "") + "ah:mm"
        return formatter.string(from: date)
    }
}

nonisolated struct MailMessageContent: Sendable {
    let text: String
    let simplifiedHTML: Bool
    let replyAddress: String
    let messageID: String?
    let attachments: [MailAttachmentInfo]
    var html: String? = nil
    var inlineImages: [MailAttachmentInfo] = []
    var to: [String] = []
    var cc: [String] = []
    var date: Date? = nil
    var replyAllTo: [String] = []
    var replyAllCC: [String] = []
    var references: [String] = []
    var from: [MailAddress] = []
    var toRecipients: [MailAddress] = []
    var ccRecipients: [MailAddress] = []
    var replyTo: [MailAddress] = []
}

nonisolated struct MailOutgoingAttachment: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data
}

nonisolated struct MailDraft: Sendable {
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: [String] = []
    var attachments: [MailOutgoingAttachment] = []
    // Stable for this compose session, including sent-folder storage.
    let messageID = "<\(UUID().uuidString)@niu.edu.tw>"

    var isEmpty: Bool { to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && body.isEmpty && attachments.isEmpty }
    static let attachmentLimit = 15 * 1024 * 1024

    static func addresses(_ value: String) throws -> [String] {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeMailError.invalidRecipient
        }
        let entries = value.components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard entries.count <= 50, entries.allSatisfy({
            $0.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#,
                     options: .regularExpression) != nil
        }) else { throw NativeMailError.invalidRecipient }
        return entries
    }

    func validate() throws {
        let recipients = try Self.addresses(to) + Self.addresses(cc) + Self.addresses(bcc)
        guard !recipients.isEmpty, recipients.count <= 50 else { throw NativeMailError.invalidRecipient }
        guard !subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), subject.utf8.count <= 998,
              body.utf8.count <= 2 * 1024 * 1024 else { throw NativeMailError.invalidDraft }
        guard attachments.reduce(0, { $0 + $1.data.count }) <= Self.attachmentLimit else {
            throw NativeMailError.tooLarge
        }
    }
}

nonisolated enum MailSendOutcome: Sendable {
    case accepted(copySaved: Bool)
}

nonisolated enum NativeMailError: Error, LocalizedError {
    case credentials, authentication, connection, timeout, changedMailbox, missingMessage, invalidResponse
    case tooLarge, invalidRecipient, invalidDraft, rejected, deliveryUnknown
    case noTrash, unsafeMove, mutationUncertain

    var errorDescription: String? {
        switch self {
        case .noTrash: return "找不到垃圾桶。可將這封信標記為已刪除，校方可能在之後清除。"
        case .unsafeMove: return "校方不支援安全移動這封信，請使用校方信箱管理。"
        case .mutationUncertain: return "無法確認郵件操作結果，請重新整理並核對信箱後再操作。"
        case .credentials: return "App 登入資訊不完整或帳號不一致，請重新登入 App。"
        case .authentication: return "校方郵件登入未通過。請確認 App 密碼；若校方要求額外驗證，需先完成校方設定。"
        case .connection: return "無法連接校方郵件服務，請檢查網路後重試。"
        case .timeout: return "校方郵件連線逾時，請稍後重試。"
        case .changedMailbox: return "信件匣已更新，請返回並重新整理後再開啟信件。"
        case .missingMessage: return "這封信可能已被移動或刪除，請重新整理信件匣。"
        case .invalidResponse: return "無法解析校方郵件資料，請稍後重試。"
        case .tooLarge: return "附件總大小上限為 15 MB，信件本文上限為 2 MB。"
        case .invalidRecipient: return "請填寫完整電子郵件地址，多位收件人以逗號分隔。"
        case .invalidDraft: return "主旨或本文格式不符，請縮短內容並移除主旨中的換行。"
        case .rejected: return "校方郵件伺服器拒絕寄送，請核對收件人與附件大小。"
        case .deliveryUnknown: return "連線中斷，無法確認是否寄出。請先向收件人確認或查核校方信箱，避免重複寄送。"
        }
    }
}

nonisolated protocol NativeMailServing: Sendable {
    func inbox(credentials: MailCredentials, folder: String, limit: Int) async throws -> MailInboxSnapshot
    func message(credentials: MailCredentials, key: MailMessageKey) async throws -> MailMessageContent
    func attachment(credentials: MailCredentials, key: MailMessageKey, part: String, maximumBytes: Int) async throws -> Data
    func setSeen(credentials: MailCredentials, key: MailMessageKey, seen: Bool) async throws
    func setFlagged(credentials: MailCredentials, key: MailMessageKey, flagged: Bool) async throws
    func moveToTrash(credentials: MailCredentials, key: MailMessageKey, allowMarkDeleted: Bool) async throws
    func send(credentials: MailCredentials, draft: MailDraft) async throws -> MailSendOutcome
}

nonisolated enum MailComposeAction: String, CaseIterable {
    case reply = "回覆", replyAll = "全部回覆", forward = "轉寄"
}

nonisolated struct MailBanner: Identifiable, Equatable {
    enum Kind: Sendable { case sending, success, warning, failure, unknown }
    let id = UUID()
    let kind: Kind
    let text: String
    var canOpenDraft: Bool { kind == .failure || kind == .unknown }
}

nonisolated extension MailDraft {
    var canSend: Bool { (try? validate()) != nil }
    static func prefilled(_ action: MailComposeAction, summary: MailSummary,
                          content: MailMessageContent, ownAddress: String) -> MailDraft {
        var draft = MailDraft()
        let prefix = action == .forward ? "Fwd:" : "Re:"
        let subject = summary.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.subject = subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : prefix + " " + subject
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW"); formatter.dateFormat = "yyyy年M月d日 HH:mm"
        let date = (content.date ?? summary.date).map { formatter.string(from: $0) } ?? "日期不明"
        if action == .forward {
            draft.body = "\n\n—— 轉寄郵件 ——\n寄件者：\(summary.sender)\n日期：\(date)\n主旨：\(summary.subject)\n收件人：\(content.to.joined(separator: ", "))\n\n\(content.text)"
        } else {
            var used = Set([ownAddress.lowercased()])
            func unique(_ values: [String]) -> [String] {
                values.filter { !$0.isEmpty && used.insert($0.lowercased()).inserted }
            }
            let replyingToSelf = content.replyAddress.lowercased() == ownAddress.lowercased()
            let recipients = replyingToSelf ? content.replyAllTo : [content.replyAddress]
            draft.to = unique(action == .replyAll ? recipients + content.replyAllTo : recipients).joined(separator: ", ")
            if action == .replyAll { draft.cc = unique(content.replyAllCC).joined(separator: ", ") }
            draft.inReplyTo = content.messageID
            draft.references = content.references
            if let id = content.messageID, !draft.references.contains(id) { draft.references.append(id) }
            draft.body = "\n\n於 \(date)，\(summary.displayName) 寫道：\n" + content.text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }
        return draft
    }
}

nonisolated enum MailSearchScope: String, CaseIterable {
    case all = "全部", sender = "寄件者", subject = "主旨"
    func matches(_ message: MailSummary, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let values: [String]
        switch self {
        case .sender: values = [message.sender, message.senderName, message.senderAddress]
        case .subject: values = [message.subject]
        case .all: values = [message.sender, message.subject, message.preview ?? ""] + message.to + message.cc
        }
        return values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

nonisolated extension NativeMailServing {
    func attachment(credentials: MailCredentials, key: MailMessageKey, part: String) async throws -> Data {
        try await attachment(credentials: credentials, key: key, part: part, maximumBytes: MailDraft.attachmentLimit)
    }
}
