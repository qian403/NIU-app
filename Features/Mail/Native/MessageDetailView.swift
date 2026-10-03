import SwiftUI
import QuickLook

struct MessageDetailView: View {
    @ObservedObject var model: NativeMailViewModel
    let summary: MailSummary
    @Environment(\.dismiss) private var dismiss
    @State private var openedAccount = ""
    @State private var expanded = false
    @State private var previewURL: URL?
    @State private var htmlHeight: CGFloat = 1
    @State private var htmlLoading = true
    @State private var htmlFailed = false
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase

    init(model: NativeMailViewModel, summary: MailSummary) {
        self.model = model
        self.summary = summary
        #if DEBUG
        _expanded = State(initialValue: NativeMailUIFixtureScreen.launchScreen() == .detailExpanded)
        #endif
    }

    private var message: MailSummary { model.latest(summary) }
    private var senders: [MailAddress] {
        if let from = model.content?.from, !from.isEmpty { return from }
        return [message.senderAddress.isEmpty ? MailAddress(displayString: message.sender) :
            MailAddress(name: message.senderName, address: message.senderAddress)]
    }
    private var recipients: [MailAddress] {
        if let to = model.content?.toRecipients, !to.isEmpty { return to }
        return (model.content?.to ?? message.to).map { MailAddress(displayString: $0) }
    }
    private var copies: [MailAddress] {
        if let cc = model.content?.ccRecipients, !cc.isEmpty { return cc }
        return (model.content?.cc ?? message.cc).map { MailAddress(displayString: $0) }
    }
    private var avatarInitials: String {
        let name = message.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) {
            return String(name[range].prefix(1))
        }
        let initials = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2).compactMap(\.first)
        return String(String(initials).uppercased().prefix(2))
    }
    private var color: Color {
        let address = message.senderAddress.isEmpty ? message.sender : message.senderAddress
        let index = address.lowercased().utf8.reduce(0) { ($0 * 31 + Int($1)) % 6 }
        return [Color.blue, .indigo, .teal, .purple, .orange, .pink][index]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                Text(message.subject).font(.title.bold()).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                if model.isReading {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView("正在讀取信件…")
                        Text(String(repeating: "正在載入郵件本文。", count: 16)).redacted(reason: .placeholder).accessibilityHidden(true)
                    }
                }
                if let error = model.detailError { MailErrorView(message: error) { model.read(message) } }
                if let content = model.content {
                    if let document = model.htmlDocument, !htmlFailed {
                        if document.hasExternalImages && !model.allowsExternalImages {
                            Button { model.allowExternalImages() } label: {
                                Label("這封信含外部圖片。載入外部圖片", systemImage: "photo")
                                    .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }
                        if document.hasExternalImages {
                            Text("僅允許載入 HTTPS 圖片。部分未加密（http）的圖片不會載入。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if htmlLoading { ProgressView("正在顯示信件…") }
                        if visible && scenePhase == .active {
                            MailHTMLView(document: document, message: summary.id, model: model,
                                externalImages: model.allowsExternalImages, imageRevision: model.htmlImageRevision,
                                height: $htmlHeight, loading: $htmlLoading, failed: $htmlFailed)
                                .frame(height: htmlHeight).frame(maxWidth: .infinity)
                        }
                        // Only a download/retry control for blocked CID parts, never a duplicate image.
                        ForEach(content.inlineImages.filter {
                            document.referencedParts.contains($0.id) && model.downloadedFiles[$0.id] == nil &&
                                !model.activeDownloads.contains($0.id) && model.inlineStatus[$0.id] != nil
                        }) { item in
                            Button { model.downloadHTMLImage(item, message: message) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("下載／重試內嵌圖片：\(item.name)", systemImage: "arrow.down.circle")
                                    Text(model.inlineStatus[item.id] ?? "圖片未載入").font(.caption)
                                }.frame(minHeight: 44)
                            }
                        }
                    } else {
                        if content.simplifiedHTML || content.html != nil {
                            Label("已轉為文字顯示", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
                            Text("無法顯示 HTML 排版，以下為文字內容。").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.linkedBody).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let images = content.inlineImages.filter {
                        htmlFailed || model.htmlDocument?.referencedParts.contains($0.id) != true
                    }
                    if !images.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("內嵌圖片").font(.headline)
                            ForEach(Array(images.enumerated()), id: \.element.id) { index, item in
                                inlineImageCard(item, index: index)
                            }
                        }
                    }
                    if !content.attachments.isEmpty {
                        Divider()
                        Text("附件（\(content.attachments.count)）").font(.headline)
                        ForEach(content.attachments) { item in attachmentCard(item) }
                    }
                }
            }.padding(20)
        }
        // Keep the last attachment action clear of the floating bottom toolbar.
        // MailChrome separately reserves the banner's actual height.
        .safeAreaPadding(.bottom, 64)
        .background(Theme.Colors.background)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { model.setFlagged(message, flagged: !message.flagged) } label: {
                    Image(systemName: message.flagged ? "flag.fill" : "flag").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(message.flagged ? "取消旗標" : "加上旗標")
                    .disabled(model.pendingMutations.contains(summary.id) || model.uncertainMutations.contains(summary.id))
                Spacer()
                Button(role: .destructive) { model.requestDelete(message) } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("移到垃圾桶")
                    .disabled(model.pendingMutations.contains(summary.id) || model.uncertainMutations.contains(summary.id))
                Spacer()
                Menu { MailReplyActions(model: model, summary: message) } label: {
                    Image(systemName: "arrowshape.turn.up.left").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("回覆、全部回覆或轉寄").disabled(model.content == nil)
                Spacer()
                MailComposeButton(model: model)
            }
        }
        .task(id: summary.id) {
            visible = true; htmlFailed = false; htmlLoading = true; htmlHeight = 1
            openedAccount = model.account
            if model.selected?.id == summary.id && model.content != nil { model.loadInlineImages() }
            else { model.read(summary) }
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            if !model.composing && previewURL == nil {
                model.closeMessage(); model.selected = nil; model.cancelComposePreparation()
            }
        }
        .onChange(of: model.deletedMessage) { _, deleted in if deleted == summary.id { dismiss() } }
        .onChange(of: model.account) { _, account in if account != openedAccount { previewURL = nil; dismiss() } }
        .onChange(of: model.sharedFile) { _, url in if let url { previewURL = url } }
        .onChange(of: previewURL) { _, url in if url == nil { model.sharedFile = nil } }
        .quickLookPreview($previewURL)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(avatarInitials).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: 48, height: 48).background(color, in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.displayName).font(.headline).textSelection(.enabled)
                    if !message.senderAddress.isEmpty {
                        addressText(MailAddress(address: message.senderAddress))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let date = model.content?.date ?? message.date {
                        Text(MailHeaderPresentation.headerDate(date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(MailHeaderPresentation.recipientLabel(recipients))
                        .lineLimit(1).textSelection(.enabled)
                    if let count = MailHeaderPresentation.recipientCountLabel(recipients) {
                        Text(count).fixedSize().textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MailHeaderPresentation.recipientSummary(recipients))
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Label(expanded ? "隱藏" : "詳細資訊", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .accessibilityLabel("郵件詳細資訊")
                .accessibilityValue(expanded ? "已展開" : "已收合")
                .accessibilityHint(expanded ? "隱藏完整郵件標頭" : "顯示完整郵件標頭")
                .accessibilityIdentifier("mail-header-details")
            }.font(.subheadline)
            if expanded {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    addressRow("寄件者", addresses: senders)
                    addressRow("收件人", addresses: recipients)
                    if !copies.isEmpty { addressRow("副本", addresses: copies) }
                    let replyTo = MailHeaderPresentation.distinctReplyTo(model.content?.replyTo ?? [], from: senders)
                    if !replyTo.isEmpty { addressRow("回覆地址", addresses: replyTo) }
                    GridRow(alignment: .top) {
                        Text("日期").foregroundStyle(.secondary)
                        Text((model.content?.date ?? message.date).map(MailHeaderPresentation.fullDate) ?? "未提供")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func addressRow(_ label: String, addresses: [MailAddress]) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                if addresses.isEmpty { Text("未提供").textSelection(.enabled) }
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                    addressText(address)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addressText(_ address: MailAddress) -> some View {
        Text(address.fullDescription)
            .textSelection(.enabled)
            .contextMenu {
                Button("拷貝地址", systemImage: "doc.on.doc") { UIPasteboard.general.string = address.address }
                Button("撰寫郵件給此地址", systemImage: "square.and.pencil") { model.newDraft(to: address.address) }
                    .disabled(model.isSending || model.isImporting || model.isPreparingDraft)
            }
    }

    private func inlineImageCard(_ item: MailAttachmentInfo, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = model.downloadedFiles[item.id] { previewURL = url }
                else { model.download(item, message: message) }
            } label: {
                if let image = model.inlineThumbnails[item.id] {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
                } else {
                    HStack(spacing: 12) {
                        if model.activeDownloads.contains(item.id) { ProgressView() }
                        else { Image(systemName: "photo").font(.title2) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.hasFilename ? item.name : "內嵌圖片 \(index + 1)").font(.subheadline)
                            Text(model.inlineStatus[item.id] ?? "正在載入圖片…").font(.caption)
                            Text(MailPresentation.size(item.size)).font(.caption)
                        }
                        Spacer()
                    }.padding(14).frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                        .background(Theme.Colors.secondaryBackground, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
                }
            }.buttonStyle(.plain)
                .accessibilityLabel(item.hasFilename ? "圖片：\(item.name)" : "內嵌圖片 \(index + 1)")
                .accessibilityHint(model.inlineStatus[item.id] ?? "開啟全螢幕預覽")
            if let url = model.downloadedFiles[item.id] {
                ShareLink(item: url) { Label("分享／儲存", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
            }
        }
    }

    private func attachmentCard(_ item: MailAttachmentInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: MailPresentation.fileIcon(item.name)).font(.title2).foregroundStyle(Theme.Colors.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(MailPresentation.size(item.size)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.activeDownloads.contains(item.id) { ProgressView().accessibilityLabel("正在下載 \(item.name)") }
            }
            if let url = model.downloadedFiles[item.id] {
                HStack {
                    Button("預覽", systemImage: "eye") { previewURL = url }.frame(minHeight: 44)
                    Spacer()
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                }
            } else {
                Button("下載附件", systemImage: "arrow.down.circle") { model.download(item, message: message) }
                    .frame(minHeight: 44).disabled(model.activeDownloads.contains(item.id))
            }
        }.padding(14).background(Theme.Colors.secondaryBackground, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
    }
}
