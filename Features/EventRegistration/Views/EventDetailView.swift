import SwiftUI

struct EventDetailView: View {
    let event: EventData
    let onRegister: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRegistration = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 活動標題
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.name)
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                        
                        EventStatusBadge(text: event.event_state, color: event.stateColor)
                    }
                    .padding(.bottom, 8)
                    
                    Divider()
                    
                    // 活動資訊
                    VStack(alignment: .leading, spacing: 16) {
                        InfoRow(icon: "number", title: "活動編號", value: event.eventSerialID)
                            .textSelection(.enabled)
                        InfoRow(icon: "building.2", title: "主辦單位", value: event.department)
                        InfoRow(icon: "calendar", title: "活動時間", value: event.eventTime)
                        InfoRow(icon: "mappin.and.ellipse", title: "活動地點", value: event.eventLocation)
                        InfoRow(icon: "clock", title: "報名時間", value: event.eventRegisterTime)
                        InfoRow(icon: "person.3", title: "報名人數", value: event.eventPeople)
                    }
                    
                    Divider()
                    
                    // 活動說明
                    if !event.eventDetail.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("活動說明")
                                .font(.headline)
                                .foregroundColor(.primary)
                            EventLinkedText(event.eventDetail)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        }
                        
                        Divider()
                    }
                    
                    // 聯絡資訊
                    VStack(alignment: .leading, spacing: 8) {
                        Text("聯絡資訊")
                            .font(.headline)
                            .foregroundColor(.primary)
                        InfoRow(icon: "person.fill", title: "聯絡人", value: event.contactInfoName)
                        TappableInfoRow(icon: "phone.fill", title: "電話", value: event.contactInfoTel, urlScheme: "tel:")
                        TappableInfoRow(icon: "envelope.fill", title: "信箱", value: event.contactInfoMail, urlScheme: "mailto:")
                    }
                    
                    Divider()
                    
                    // 其他資訊
                    if !event.Related_links.isEmpty {
                        InfoRow(icon: "link", title: "相關連結", value: event.Related_links, detectsLinks: true)
                    }
                    
                    if !event.Multi_factor_authentication.isEmpty {
                        InfoRow(icon: "checkmark.seal.fill", title: "多元認證", value: event.Multi_factor_authentication)
                    }
                    
                    if !event.Remark.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("備註")
                                .font(.headline)
                                .foregroundColor(.primary)
                            EventLinkedText(event.Remark)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemBackground))
            .navigationTitle("活動詳情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EventShareMenu(content: event.shareContent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") {
                        dismiss()
                    }
                    .foregroundColor(.primary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if canRegister {
                    Button {
                        confirmingRegistration = true
                    } label: {
                        Text("我要報名")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                    .padding()
                    .background(.bar)
                }
            }
            .confirmationDialog("確定要報名這個活動？", isPresented: $confirmingRegistration, titleVisibility: .visible) {
                Button("報名") {
                    onRegister(event.eventSerialID)
                    dismiss()
                }
                Button("先不要", role: .cancel) {}
            } message: {
                Text("「\(event.name)」報名送出後會寫入校方紀錄，App 會再到已報名列表確認結果。")
            }
        }
    }
    
    private var canRegister: Bool {
        event.event_state.contains("報名中")
    }
    
}

struct EventShareMenu: View {
    let content: EventShareContent

    var body: some View {
        Menu {
            ShareLink(item: content.text, subject: Text(content.name)) {
                Label("分享活動資訊", systemImage: "text.bubble")
            }
            if let url = content.url {
                ShareLink(item: url) {
                    Label("只分享連結", systemImage: "link")
                }
            }
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("分享活動")
    }
}

struct EventLinkedText: View {
    private let content: AttributedString

    init(_ text: String) {
        content = EventTextLinks.attributedText(text)
    }

    var body: some View {
        Text(content)
            .tint(.accentColor)
            .textSelection(.enabled)
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    var detectsLinks = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Group {
                    if detectsLinks {
                        EventLinkedText(value)
                    } else {
                        Text(value)
                    }
                }
                .font(.subheadline)
                .foregroundColor(.primary)
            }
            
            Spacer()
        }
    }
}

struct TappableInfoRow: View {
    let icon: String
    let title: String
    let value: String
    let urlScheme: String
    
    var body: some View {
        Button(action: openLink) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityHint(urlScheme == "tel:" ? "撥打電話" : "撰寫郵件")
    }
    
    private func openLink() {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(urlScheme)\(trimmed)") else { return }
        UIApplication.shared.open(url)
    }
}
