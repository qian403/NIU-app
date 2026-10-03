import SwiftUI

struct MailErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle").font(.callout)
            Button("重試", action: retry).frame(minHeight: 44)
        }.padding(.vertical, 8)
    }
}

struct MailListToolbar: ToolbarContent {
    @ObservedObject var model: NativeMailViewModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            if model.isLoading || model.isPreparingDraft { ProgressView().accessibilityLabel("正在讀取郵件") }
        }
        ToolbarItem(placement: .bottomBar) {
            Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity)
        }
        ToolbarItem(placement: .bottomBar) { MailComposeButton(model: model) }
    }
}

struct MailComposeButton: View {
    @ObservedObject var model: NativeMailViewModel
    var body: some View {
        Button { model.newDraft() } label: { Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("撰寫郵件")
            .disabled(model.account.isEmpty || model.isSending || model.isPreparingDraft || model.isImporting)
    }
}

struct MailReplyActions: View {
    @ObservedObject var model: NativeMailViewModel
    let summary: MailSummary
    var body: some View {
        ForEach(MailComposeAction.allCases, id: \.self) { action in
            Button(action.rawValue, systemImage: action == .forward ? "arrowshape.turn.up.right" : "arrowshape.turn.up.left") {
                model.compose(action, summary: summary)
            }.disabled(model.isSending || model.isPreparingDraft || model.isImporting)
        }
    }
}

struct MailMessageActions: View {
    @ObservedObject var model: NativeMailViewModel
    let summary: MailSummary
    var body: some View {
        MailReplyActions(model: model, summary: summary)
        Divider()
        Group {
            Button(summary.flagged ? "取消旗標" : "旗標", systemImage: summary.flagged ? "flag.slash" : "flag") {
                model.setFlagged(summary, flagged: !summary.flagged)
            }
            Button(summary.unread ? "標為已讀" : "標為未讀", systemImage: "envelope") {
                model.setSeen(summary, seen: summary.unread)
            }
            Button("刪除", systemImage: "trash", role: .destructive) { model.requestDelete(summary) }
        }.disabled(model.pendingMutations.contains(summary.id) || model.uncertainMutations.contains(summary.id))
    }
}

/// The root installs this chrome on each destination in HomeView's existing stack.
/// All instances observe the same outbox, so navigating never resets a send banner.
private struct MailChrome: ViewModifier {
    @ObservedObject var model: NativeMailViewModel
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if model.operationError != nil || model.banner != nil {
                VStack(spacing: 8) {
                    if let error = model.operationError {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                            Button { model.operationError = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("關閉操作提示")
                        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
                    }
                    if let banner = model.banner {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                if banner.kind == .sending { ProgressView() }
                                else { Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(banner.kind == .success ? Theme.Colors.success : Theme.Colors.warning) }
                                Text(banner.kind == .failure ? "無法寄出郵件" : banner.text)
                                    .font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(banner.kind == .failure ? 1 : nil)
                                    .accessibilityLabel(banner.text)
                                if banner.kind != .sending && !banner.canOpenDraft {
                                    Button { model.dismissBanner() } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                                        .accessibilityLabel("關閉寄送提示")
                                }
                            }
                            if banner.kind == .failure {
                                let prefix = "無法寄出郵件："
                                Text(banner.text.hasPrefix(prefix) ? String(banner.text.dropFirst(prefix.count)) : banner.text)
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityHidden(true) // The title announces the complete reason.
                            }
                            if banner.canOpenDraft {
                                HStack(spacing: 8) {
                                    Spacer(minLength: 0)
                                    Button(banner.kind == .unknown ? "檢視草稿" : "開啟草稿") { model.reopenDraft() }
                                        .frame(minHeight: 44)
                                    Button { model.dismissBanner() } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44) }
                                        .accessibilityLabel("關閉寄送提示")
                                }
                            }
                        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
                            .accessibilityElement(children: .contain)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}

extension View {
    func mailChrome(_ model: NativeMailViewModel) -> some View { modifier(MailChrome(model: model)) }
}

@MainActor enum MailPresentation {
    // Main-actor-owned formatters are reused; refresh their calendar/time zone only
    // when the device settings change, keeping formatting and day boundaries aligned.
    private static var formatterCalendar = Calendar.current
    private static var dateFormatters: [String: DateFormatter] = [:]
    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        if calendar != formatterCalendar {
            dateFormatters.removeAll(); formatterCalendar = calendar
        }
        if let cached = dateFormatters[format] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        dateFormatters[format] = formatter
        return formatter
    }

    static func relativeDate(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "日期不明" }
        let calendar = Calendar.current
        let format: String
        if calendar.isDate(date, inSameDayAs: now) { format = "HH:mm" }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { format = "EEEE" }
        else { format = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "M月d日" : "yyyy/M/d" }
        return formatter(format, calendar: calendar).string(from: date)
    }
    static func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "heic", "gif": return "photo"
        case "zip", "gz": return "doc.zipper"
        case "xls", "xlsx", "csv": return "tablecells"
        case "mp3", "m4a", "wav": return "waveform"
        case "mp4", "mov": return "film"
        default: return "doc"
        }
    }
    static func size(_ count: Int?) -> String {
        count.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "大小未知"
    }
}

extension MailSummary {
    static func placeholder(_ uid: UInt32) -> Self {
        Self(id: MailMessageKey(folder: "", validity: 0, uid: uid), subject: "郵件主旨", sender: "寄件者名稱", date: Date(), unread: false,
             preview: "正在準備郵件內容與信件摘要，請稍候。")
    }
}
