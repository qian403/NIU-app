import SwiftUI

struct MailboxListView: View {
    @ObservedObject var model: NativeMailViewModel
    @State private var listOwner = UUID()

    var body: some View {
        List {
            Section {
                if model.folders.isEmpty && model.isLoading {
                    ForEach(0..<5) { _ in Label("正在載入信箱", systemImage: "folder").frame(minHeight: 44).redacted(reason: .placeholder) }
                }
                ForEach(model.folders) { folder in
                    NavigationLink(value: folder) {
                        HStack(spacing: 16) {
                            Image(systemName: folder.symbol).font(.title3).foregroundStyle(Theme.Colors.accent)
                                .frame(width: 28)
                            Text(folder.title)
                            Spacer()
                            if let count = folder.unreadCount, count > 0 {
                                Text(count, format: .number).font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary).accessibilityLabel("\(count) 封未讀")
                            }
                        }.frame(minHeight: 44)
                    }
                }
            } header: { Text(model.accountAddress).textCase(nil) }
            if !model.draft.isEmpty {
                Section {
                    Button { model.reopenDraft() } label: {
                        Label(model.sendLocked ? "檢視寄送結果不明的草稿" : "繼續編輯草稿", systemImage: "doc.badge.ellipsis")
                            .frame(minHeight: 44)
                    }.disabled(model.isSending)
                } footer: { Text("草稿只保留於本次 App 工作階段。") }
            }
            if let error = model.errorMessage {
                MailErrorView(message: error) { model.reload() }
            } else if model.hasLoaded && model.folders.isEmpty {
                ContentUnavailableView("沒有可用的信件匣", systemImage: "tray", description: Text("下拉更新，或確認校方信箱設定。"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("信箱").navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .refreshable { await model.refresh() }
        .onAppear { model.activateList(owner: listOwner) }
        .onDisappear { model.suspendList(owner: listOwner) }
        .toolbar { MailListToolbar(model: model) }
    }
}
