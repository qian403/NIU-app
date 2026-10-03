import SwiftUI

struct MessageListView: View {
    @ObservedObject var model: NativeMailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var openedAccount = ""
    @State private var listOwner = UUID()
    let mailbox: MailFolder
    @State private var query = ""
    @State private var scope = MailSearchScope.all

    private var filtered: [MailSummary] {
        model.messages.filter { scope.matches($0, query: query) }
    }
    var body: some View {
        List {
            if let error = model.errorMessage {
                MailErrorView(message: error) { model.reload() }.listRowSeparator(.hidden)
            }
            if model.isLoading && model.messages.isEmpty {
                ForEach(0..<7) { index in
                    MessageRow(summary: .placeholder(UInt32(index)))
                        .redacted(reason: .placeholder).accessibilityHidden(true)
                }
            } else {
                ForEach(filtered) { summary in
                    NavigationLink(value: summary) { MessageRow(summary: summary) }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { model.setSeen(summary, seen: summary.unread) } label: {
                                Label(summary.unread ? "標為已讀" : "標為未讀", systemImage: summary.unread ? "envelope.open" : "envelope.badge")
                            }.tint(.blue).disabled(model.pendingMutations.contains(summary.id) || model.uncertainMutations.contains(summary.id))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { model.requestDelete(summary) } label: { Label("刪除", systemImage: "trash") }
                                .disabled(model.pendingMutations.contains(summary.id) || model.uncertainMutations.contains(summary.id))
                            Button { model.setFlagged(summary, flagged: !summary.flagged) } label: {
                                Label(summary.flagged ? "取消旗標" : "旗標", systemImage: summary.flagged ? "flag.slash" : "flag")
                            }.tint(.orange).disabled(model.pendingMutations.contains(summary.id) || model.uncertainMutations.contains(summary.id))
                        }
                        .contextMenu { MailMessageActions(model: model, summary: summary) }
                        .onAppear { if query.isEmpty { model.loadMoreIfNeeded(summary) } }
                }
                if model.hasLoaded && filtered.isEmpty && model.errorMessage == nil {
                    ContentUnavailableView(query.isEmpty ? "沒有郵件" : "找不到郵件", systemImage: query.isEmpty ? "tray" : "magnifyingglass",
                                           description: Text(query.isEmpty ? "收到的郵件會顯示在這裡。" : "搜尋僅涵蓋已載入的郵件，可更換關鍵字或搜尋範圍。"))
                        .listRowSeparator(.hidden)
                }
            }
            if model.isLoading && !model.messages.isEmpty {
                HStack { Spacer(); ProgressView("正在載入…"); Spacer() }.listRowSeparator(.hidden)
            } else if model.canLoadMore {
                Button("載入更多郵件") { model.reload(more: true) }.frame(maxWidth: .infinity, minHeight: 44)
                    .listRowSeparator(.hidden)
            }
            if model.hasLoaded {
                VStack(spacing: 5) {
                    Text("已載入 \(model.messages.count) 封・\(model.messages.filter(\.unread).count) 封未讀")
                    if let date = model.lastUpdated { Text("已更新 \(date.formatted(date: .omitted, time: .shortened))") }
                    if model.messages.count >= 1000 { Text("已達本次載入上限 1,000 封") }
                }.font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(mailbox.title).navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "搜尋已載入的郵件")
        .searchScopes($scope) { ForEach(MailSearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        .refreshable { await model.refresh() }
        .task(id: mailbox.id) { openedAccount = model.account; model.activateList(owner: listOwner); model.chooseFolder(mailbox.id) }
        .onDisappear {
            model.suspendList(owner: listOwner)
            model.cancelComposePreparation()
        }
        .onChange(of: model.account) { _, account in if account != openedAccount { dismiss() } }
        .toolbar { MailListToolbar(model: model) }
    }
}

struct MessageRow: View {
    let summary: MailSummary
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(summary.unread ? Theme.Colors.info : .clear).frame(width: 8, height: 8).padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.displayName).font(.headline).fontWeight(summary.unread ? .bold : .regular).lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        if summary.hasAttachment { Image(systemName: "paperclip") }
                        if summary.flagged { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                        Text(MailPresentation.relativeDate(summary.date)).lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
                }
                Text(summary.subject).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                if let preview = summary.preview, !preview.isEmpty {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }.padding(.vertical, 8).frame(minHeight: 68)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("寄件者：\(summary.displayName)，主旨：\(summary.subject)，\(MailPresentation.relativeDate(summary.date))，\(summary.unread ? "未讀" : "已讀")\(summary.hasAttachment ? "，含附件" : "")\(summary.flagged ? "，已加旗標" : "")")
    }
}
