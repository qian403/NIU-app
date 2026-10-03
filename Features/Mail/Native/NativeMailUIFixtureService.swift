#if DEBUG
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum NativeMailUIFixtureScreen: String {
    case list, detail, inline, html, notification, compose, reply, sending, sent, failure
    case detailExpanded = "detail-expanded"

    static func launchScreen(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard let flag = arguments.firstIndex(of: "-NIUMailUIFixtureScreen"),
              arguments.indices.contains(flag + 1) else { return nil }
        return Self(rawValue: arguments[flag + 1])
    }
}

/// Synthetic, in-memory mail only. No production service, Keychain or network access.
actor NativeMailUIFixtureService: NativeMailServing {
    static func screenshotDraft(invalidRecipient: Bool = false) -> MailDraft {
        var draft = MailDraft()
        // The trailing delimiter makes every recipient a completed UI token.
        draft.to = "alex@example.com, peer@example.com," + (invalidRecipient ? " invalid-address," : "")
        draft.subject = "校園活動討論與時程確認"
        draft.body = "各位同學好：\n\n附件是本次會議議程，請先閱讀。\n我可以參加週三下午的討論，期待收到大家的回覆。\n\n謝謝！"
        draft.attachments = [MailOutgoingAttachment(name: "會議議程.txt", mime: "text/plain", data: agenda)]
        return draft
    }

    private let sendFailure: Bool
    private var mail: [String: [MailSummary]]
    private var nextUID: UInt32 = 100
    private let folders = [
        MailFolder(id: "INBOX", name: "INBOX", role: .inbox),
        MailFolder(id: "fixture-sent", name: "寄出", role: .sent),
        MailFolder(id: "fixture-drafts", name: "撰寫中", role: .drafts),
        MailFolder(id: "fixture-trash", name: "回收區", role: .trash),
        MailFolder(id: "fixture-junk", name: "過濾區", role: .junk)
    ]

    init(sendFailure: Bool = false, now: Date = Date()) {
        self.sendFailure = sendFailure
        let senders = ["圖書資訊館", "王小明", "Alex Chen", "國際事務處", "Research Team"]
        let subjects = [
            "校園活動通知：會議議程與活動時程",
            "課程分組討論與期末專題進度確認，請於本週閱讀附件並回覆可參加的時段",
            "Welcome to the new semester — course resources",
            "圖書館借閱到期提醒",
            "研究計畫討論 / Project discussion"
        ]
        var messages: [MailSummary] = []
        for index in 0..<20 {
            let folder = index < 16 ? "INBOX" : ["fixture-sent", "fixture-drafts", "fixture-trash", "fixture-junk"][index - 16]
            let address = "sender\(index + 1)@example.com"
            messages.append(MailSummary(
                id: MailMessageKey(folder: folder, validity: 1, uid: UInt32(20 - index)),
                subject: index == 3 ? "校務資訊入口網 登入通知（合成測試）" : index == 2 ? "校園電子報：HTML 排版與圖片" : index == 1 ? "校園照片：兩張內嵌圖片" : subjects[index % subjects.count], sender: "\(senders[index % senders.count]) <\(address)>",
                date: now.addingTimeInterval(-Double(index) * 18_000), unread: index % 3 != 1,
                to: index == 0 ? ["測試同學 <test@niu.edu.tw>", "Alex Chen <alex@example.com>"] : ["test@niu.edu.tw"],
                cc: index == 0 ? ["同學 <peer@example.com>", "助教 <assistant@example.com>"] : [],
                hasAttachment: index <= 2, flagged: index % 4 == 0,
                preview: index % 2 == 0 ? "各位同學好，請參閱本次活動資訊與時程，並回覆可以參加的時間。" : "Hello everyone, here are the notes and resources for our next discussion.",
                senderName: senders[index % senders.count], senderAddress: address))
        }
        mail = Dictionary(grouping: messages, by: { $0.id.folder })
    }

    func inbox(credentials: MailCredentials, folder: String, limit: Int) async throws -> MailInboxSnapshot {
        try Task.checkCancellation()
        let messages = mail[folder] ?? []
        let counted = folders.map { folder in
            var folder = folder
            folder.unreadCount = (mail[folder.id] ?? []).filter(\.unread).count
            return folder
        }
        return MailInboxSnapshot(folders: counted, messages: Array(messages.prefix(max(0, limit))), total: messages.count)
    }

    private func summary(_ key: MailMessageKey) throws -> MailSummary {
        try Task.checkCancellation()
        guard let message = mail[key.folder]?.first(where: { $0.id == key }) else { throw NativeMailError.missingMessage }
        return message
    }

    func message(credentials: MailCredentials, key: MailMessageKey) async throws -> MailMessageContent {
        let summary = try summary(key)
        if key.uid == 17 {
            return MailMessageContent(text: "校務資訊入口網 登入通知（合成測試）\n測試代號：DEMO-ONLY\n時間：2026-10-03 08:30\n底部說明：本信件完全使用合成資料。",
                simplifiedHTML: true, replyAddress: summary.senderAddress, messageID: "<notification-fixture@example.com>",
                attachments: [], html: """
                <!doctype html><html><head><title>合成登入通知</title></head><body>
                <table width="700" cellspacing="0" cellpadding="0" style="width:700px;border:1px solid #ddd">
                <tr><td><div style="height:48px;line-height:48px;overflow:hidden;background:#1766ab;color:white;font-size:26px;font-weight:bold;padding:0 16px">校務資訊入口網 登入通知（合成測試）</div></td></tr>
                <tr><td style="padding:24px;background:#eee;font-size:16px;line-height:1.6">
                <p>這是通知模板排版測試，沒有真實帳號、姓名或網路位址。</p>
                <p>測試代號：DEMO-ONLY</p><p style="color:#c00">通知時間：2026-10-03 08:30（合成）</p>
                <p>此固定寬度資訊區的右側文字應完整顯示。</p></td></tr>
                <tr><td style="padding:24px;font-size:16px;line-height:1.6">
                <p>說明：此信僅供離線檢查版面，不代表任何實際登入紀錄。</p>
                <p>請在窄螢幕、橫向畫面與放大系統字級下確認標題、右側內容及底部說明。</p>
                <p>底部驗收標記：合成通知結束。</p></td></tr>
                </table></body></html>
                """, to: summary.to, date: summary.date)
        }
        if key.uid == 18 {
            let image = MailAttachmentInfo(id: "cid", name: "電子報插圖.png", size: Self.cidPhoto.count,
                mime: "image/png", contentID: "newsletter@example.com", hasFilename: false)
            return MailMessageContent(text: "校園電子報\n本週活動：週三 14:00，圖書館。\n查看活動：https://example.com/event\n聯絡：events@example.com",
                simplifiedHTML: true, replyAddress: summary.senderAddress, messageID: "<html-fixture@example.com>",
                attachments: [], html: """
                <!doctype html><html><head><style>
                body{background:#101827;color:#edf2ff}td{padding:16px;font-size:14px}a{color:#a9caff}
                </style></head><body><table width="640" bgcolor="#17243b" style="color:#edf2ff;border-radius:16px">
                <tr><td><h1>校園週報</h1><p>NIU CAMPUS · 本週精選</p></td></tr>
                <tr><td><img src="cid:newsletter@example.com" alt="合成校園插圖" width="520"></td></tr>
                <tr><td><h2>一起探索校園</h2><p style="font-size:14px">週三 14:00，圖書館見！這封信保留表格、文字色彩與按鈕排版。</p>
                <a href="https://example.com/event" style="display:inline-block;padding:14px 24px;background:#4169e1;color:white;border-radius:10px">查看活動資訊</a></td></tr>
                <tr><td><img src="https://example.com/newsletter-banner.png" alt="HTTPS 外部圖片（預設封鎖）" width="520" height="100">
                <img src="http://example.com/newsletter-insecure.png" alt="HTTP 外部圖片（同意後仍封鎖）" width="520" height="100">
                <p><a href="mailto:events@example.com?subject=校園活動詢問">聯絡活動窗口</a></p></td></tr>
                </table></body></html>
                """, inlineImages: [image], to: summary.to, date: summary.date)
        }
        if key.uid == 19 {
            let images = [
                MailAttachmentInfo(id: "photo", name: "校園照片.png", size: Self.photo.count,
                                   mime: "image/png", hasFilename: true),
                MailAttachmentInfo(id: "cid", name: "part_3.png", size: Self.cidPhoto.count,
                                   mime: "image/png", contentID: "fixture-photo@example.com", hasFilename: false)
            ]
            return MailMessageContent(text: "這封合成信包含一張有檔名的 inline 照片，以及一張只有 Content-ID 的圖片。",
                simplifiedHTML: true, replyAddress: summary.senderAddress, messageID: "<inline-fixture@example.com>",
                attachments: [images[0]], inlineImages: images, to: summary.to, date: summary.date)
        }
        let attachments = summary.hasAttachment ? [
            MailAttachmentInfo(id: "agenda", name: "會議議程.txt", size: Self.agenda.count),
            MailAttachmentInfo(id: "schedule", name: "活動時程.csv", size: Self.schedule.count)
        ] : []
        return MailMessageContent(
            text: """
            各位同學好：

            歡迎參加本週的校園活動。請先閱讀會議議程與活動時程，並回覆方便參加的時間。

            活動資訊：https://example.com/campus-event
            聯絡窗口：events@example.com

            Please review the agenda before our discussion. Thank you!

            圖書資訊館 敬上
            """,
            simplifiedHTML: false, replyAddress: key.uid == 20 ? "events@example.com" : summary.senderAddress,
            messageID: "<fixture-\(key.uid)@example.com>", attachments: attachments,
            to: summary.to, cc: summary.cc, date: summary.date,
            replyAllTo: key.uid == 20 ? ["alex@example.com"] : [],
            replyAllCC: key.uid == 20 ? ["peer@example.com", "assistant@example.com"] : [],
            from: [MailAddress(name: summary.senderName, address: summary.senderAddress)],
            toRecipients: summary.to.map { MailAddress(displayString: $0) },
            ccRecipients: summary.cc.map { MailAddress(displayString: $0) },
            replyTo: key.uid == 20 ? [MailAddress(name: "活動窗口", address: "events@example.com")] : [])
    }

    private static let agenda = Data("會議議程\n一、活動介紹\n二、分組討論\n三、問題交流\n".utf8)
    private static let schedule = Data("時間,活動\n09:00,報到\n09:30,分組討論\n10:30,交流\n".utf8)

    // Generate small local PNGs without bundling assets or fetching external URLs.
    private static let photo = makePNG(width: 480, height: 300, red: 0.15, blue: 0.85)
    private static let cidPhoto = makePNG(width: 300, height: 420, red: 0.85, blue: 0.25)
    private static func makePNG(width: Int, height: Int, red: CGFloat, blue: CGFloat) -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        context.setFillColor(CGColor(red: red, green: 0.6, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.5, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    func attachment(credentials: MailCredentials, key: MailMessageKey, part: String, maximumBytes: Int) async throws -> Data {
        guard try summary(key).hasAttachment else { throw NativeMailError.missingMessage }
        let data: Data
        switch part {
        case "photo" where key.uid == 19: data = Self.photo
        case "cid" where key.uid == 19 || key.uid == 18: data = Self.cidPhoto
        case "agenda" where key.uid == 20: data = Self.agenda
        case "schedule" where key.uid == 20: data = Self.schedule
        default: throw NativeMailError.missingMessage
        }
        guard data.count <= maximumBytes else { throw NativeMailError.tooLarge }
        return data
    }

    func setSeen(credentials: MailCredentials, key: MailMessageKey, seen: Bool) async throws {
        var message = try summary(key); message.unread = !seen
        mail[key.folder] = mail[key.folder]?.map { $0.id == key ? message : $0 }
    }

    func setFlagged(credentials: MailCredentials, key: MailMessageKey, flagged: Bool) async throws {
        var message = try summary(key); message.flagged = flagged
        mail[key.folder] = mail[key.folder]?.map { $0.id == key ? message : $0 }
    }

    func moveToTrash(credentials: MailCredentials, key: MailMessageKey, allowMarkDeleted: Bool) async throws {
        let message = try summary(key)
        if key.folder == "fixture-trash" {
            guard allowMarkDeleted else { throw NativeMailError.noTrash }
        } else {
            let moved = MailSummary(
                id: MailMessageKey(folder: "fixture-trash", validity: 1, uid: nextUID),
                subject: message.subject, sender: message.sender, date: message.date, unread: message.unread,
                to: message.to, cc: message.cc, hasAttachment: message.hasAttachment, flagged: message.flagged,
                preview: message.preview, senderName: message.senderName, senderAddress: message.senderAddress)
            nextUID += 1
            mail["fixture-trash", default: []].insert(moved, at: 0)
        }
        mail[key.folder]?.removeAll { $0.id == key }
    }

    func send(credentials: MailCredentials, draft: MailDraft) async throws -> MailSendOutcome {
        try draft.validate()
        try await Task.sleep(for: .milliseconds(1500))
        try Task.checkCancellation()
        if sendFailure { throw NativeMailError.rejected }
        return .accepted(copySaved: true)
    }
}
#endif
