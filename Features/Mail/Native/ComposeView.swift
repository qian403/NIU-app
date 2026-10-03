import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @ObservedObject var model: NativeMailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = false
    @State private var choosingFiles = false
    @State private var confirmsDiscard = false
    private var attachmentSize: Int { model.draft.attachments.reduce(0) { $0 + $1.data.count } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MailRecipientField(title: "收件人", value: $model.draft.to)
                        Divider()
                        if expanded {
                            MailRecipientField(title: "副本", value: $model.draft.cc)
                            Divider()
                            MailRecipientField(title: "密件副本", value: $model.draft.bcc)
                            Divider()
                            HStack(alignment: .firstTextBaseline) {
                                Text("寄件人").foregroundStyle(.secondary)
                                Text(model.accountAddress).textSelection(.enabled)
                            }.padding(.vertical, 14).frame(minHeight: 44)
                        } else {
                            Button { expanded = true } label: {
                                HStack {
                                    Text("副本／密件副本、寄件人").foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.caption)
                                }.padding(.vertical, 14).frame(minHeight: 44)
                            }
                        }
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            Text("主旨").foregroundStyle(.secondary)
                            TextField("主旨", text: $model.draft.subject).accessibilityLabel("主旨")
                        }.padding(.vertical, 14).frame(minHeight: 44)
                        Divider()
                        attachments.padding(.vertical, 8)
                        Divider()
                        if let message = model.sendMessage {
                            Label(message, systemImage: "info.circle").font(.callout).padding(.vertical, 12)
                        }
                        TextEditor(text: $model.draft.body)
                            .frame(minHeight: max(220, geometry.size.height - (expanded ? 390 : 280)))
                            .scrollContentBackground(.hidden).accessibilityLabel("郵件本文")
                        Text("草稿暫存於 App 記憶體；登出或關閉 App 後不保留。")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                    }.padding(.horizontal, 20)
                        .disabled(model.isSending || model.sendLocked)
                }.scrollDismissesKeyboard(.interactively)
            }
            .background(Theme.Colors.background)
            .navigationTitle(model.draft.subject.isEmpty ? "新郵件" : model.draft.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if model.draft.isEmpty { dismiss() } else { confirmsDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("寄出郵件")
                        .disabled(!model.draft.canSend || model.isSending || model.sendLocked || model.isImporting)
                }
            }
            .interactiveDismissDisabled(!model.draft.isEmpty)
            .confirmationDialog("保留這份草稿？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("刪除草稿", role: .destructive) { model.discardDraft(); dismiss() }
                Button("儲存草稿") { dismiss() }
            } message: {
                Text(model.sendLocked ? "寄送結果尚未確認。儲存後仍會鎖定寄出按鈕，請先確認收件情況。" : "草稿只保留於本次 App 工作階段。")
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.importAttachments(urls)
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled { model.attachmentImportFailed() }
                }
            }
            .onAppear { expanded = !model.draft.cc.isEmpty || !model.draft.bcc.isEmpty }
            .onChange(of: model.account) { _, account in if account.isEmpty { dismiss() } }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.draft.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.draft.attachments) { item in
                            HStack(spacing: 10) {
                                Image(systemName: MailPresentation.fileIcon(item.name)).foregroundStyle(Theme.Colors.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.subheadline).lineLimit(2)
                                    Text(MailPresentation.size(item.data.count)).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button(role: .destructive) { model.draft.attachments.removeAll { $0.id == item.id } } label: {
                                    Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel("移除附件 \(item.name)")
                            }.padding(.horizontal, 10).padding(.vertical, 4)
                                .frame(width: 260)
                                .background(Theme.Colors.secondaryBackground, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            HStack {
                Button("加入附件", systemImage: "paperclip") { choosingFiles = true }.frame(minHeight: 44)
                Spacer()
                Text("\(MailPresentation.size(attachmentSize))／15 MB").font(.caption).foregroundStyle(.secondary)
            }
            if !model.forwardAttachments.isEmpty {
                Button("加入原信附件（\(model.forwardAttachments.count)）", systemImage: "arrow.down.doc") { model.includeForwardAttachments() }
                    .frame(minHeight: 44)
            }
            if model.isImporting { ProgressView("正在讀取附件…") }
        }.disabled(model.isImporting)
    }
}

/// Completed entries are tokens; the trailing entry stays editable until comma,
/// Return or focus departure. Validation uses the same parser as the SMTP draft.
private struct MailRecipientField: View {
    let title: String
    @Binding var value: String
    @FocusState private var focused: Bool
    private var parts: [String] { value.components(separatedBy: CharacterSet(charactersIn: ",;，；")) }
    private var trailing: Binding<String> {
        Binding(get: { parts.last ?? "" }, set: { text in
            let completed = parts.dropLast()
            value = (Array(completed) + [text]).joined(separator: ",")
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            MailTokenLayout(spacing: 6) {
                ForEach(Array(parts.dropLast().enumerated()), id: \.offset) { index, raw in
                    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let valid = (try? MailDraft.addresses(token))?.count == 1
                    if !token.isEmpty {
                        Menu {
                            Button("移除", role: .destructive) {
                                var updated = parts; updated.remove(at: index); value = updated.joined(separator: ",")
                            }
                                .accessibilityLabel("移除\(title) \(token)")
                        } label: {
                            HStack(spacing: 5) {
                                if !valid { Image(systemName: "exclamationmark.circle.fill") }
                                Text(token).lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption2)
                            }.font(.subheadline).padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(minHeight: 30)
                                .foregroundStyle(valid ? Theme.Colors.accent : Theme.Colors.error)
                                .background(valid ? Theme.Colors.accentSoft : Theme.Colors.error.opacity(0.12), in: Capsule())
                                .padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(title) \(token)\(valid ? "" : "，地址格式不正確")")
                            .accessibilityHint("點兩下開啟選單，可移除此地址")
                    }
                }
            }
            TextField("輸入電子郵件地址", text: trailing).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                .accessibilityLabel(title).frame(minHeight: 44)
                .onAppear { complete() }
                .onSubmit { complete() }
                .onChange(of: focused) { _, focused in if !focused { complete() } }
        }.padding(.vertical, 8)
    }
    private func complete() {
        if !(parts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value += "," }
    }
}

private struct MailTokenLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 300, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                                 proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, view.sizeThatFits(.unspecified).width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += height + spacing; height = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; height = max(height, size.height)
        }
        return (CGSize(width: width, height: y + height), points)
    }
}
