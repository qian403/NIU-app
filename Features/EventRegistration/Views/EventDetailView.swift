import SwiftUI

struct EventDetailView: View {
    let event: EventData
    let onRegister: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 活動標題
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.name)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.primary)
                        
                        HStack {
                            Text(event.event_state)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(stateColor.opacity(0.2))
                                .foregroundColor(stateColor)
                                .cornerRadius(8)
                            
                            Spacer()
                        }
                    }
                    .padding(.bottom, 8)
                    
                    Divider()
                    
                    // 活動資訊
                    VStack(alignment: .leading, spacing: 16) {
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
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(event.eventDetail.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n"))
                                .font(.system(size: 14))
                                .foregroundColor(.primary.opacity(0.85))
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        }
                        
                        Divider()
                    }
                    
                    // 聯絡資訊
                    VStack(alignment: .leading, spacing: 8) {
                        Text("聯絡資訊")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        InfoRow(icon: "person.fill", title: "聯絡人", value: event.contactInfoName)
                        TappableInfoRow(icon: "phone.fill", title: "電話", value: event.contactInfoTel, urlScheme: "tel:")
                        TappableInfoRow(icon: "envelope.fill", title: "信箱", value: event.contactInfoMail, urlScheme: "mailto:")
                    }
                    
                    Divider()
                    
                    // 其他資訊
                    if !event.Related_links.isEmpty {
                        InfoRow(icon: "link", title: "相關連結", value: event.Related_links)
                    }
                    
                    if !event.Multi_factor_authentication.isEmpty {
                        InfoRow(icon: "checkmark.seal.fill", title: "多元認證", value: event.Multi_factor_authentication)
                    }
                    
                    if !event.Remark.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("備註")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(event.Remark.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n"))
                                .font(.system(size: 14))
                                .foregroundColor(.primary.opacity(0.85))
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") {
                        dismiss()
                    }
                    .foregroundColor(.primary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if canRegister {
                    Button(action: {
                        onRegister(event.eventSerialID)
                        dismiss()
                    }) {
                        Text("我要報名")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.green)
                            .cornerRadius(12)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                }
            }
        }
    }
    
    private var canRegister: Bool {
        event.event_state.contains("報名中")
    }
    
    private var stateColor: Color {
        switch event.event_state {
        case let state where state.contains("報名中"):
            return .green
        case let state where state.contains("已額滿"):
            return .red
        case let state where state.contains("即將開始"):
            return .orange
        default:
            return .gray
        }
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 14))
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
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.system(size: 14))
                        .foregroundColor(.blue)
                        .underline()
                }
                
                Spacer()
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    
    private func openLink() {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: "\(urlScheme)\(trimmed)") else { return }
        UIApplication.shared.open(url)
    }
}
