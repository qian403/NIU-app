import SwiftUI

struct AppliedEventDetailView: View {
    let event: EventData_Apply
    @Environment(\.dismiss) private var dismiss
    let onCancel: (String) -> Void
    let onModify: (EventData_Apply) -> Void
    @State private var confirmingCancellation = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 活動標題
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.name)
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                        
                        HStack(spacing: 8) {
                            if !event.state.isEmpty {
                                EventStatusBadge(text: event.state, color: event.registrationStateColor)
                            }
                            if !event.eventStateLabel.isEmpty {
                                EventStatusBadge(text: event.eventStateLabel, color: event.eventStateColor)
                            }
                        }
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
                if canModify || canCancel {
                    VStack(spacing: 12) {
                        if canModify {
                            Button {
                                onModify(event)
                                dismiss()
                            } label: {
                                Label("修改報名資訊", systemImage: "pencil")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }

                        if canCancel {
                            Button(role: .destructive) {
                                confirmingCancellation = true
                            } label: {
                                Label("取消報名", systemImage: "xmark.circle")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .confirmationDialog("確定要取消報名？", isPresented: $confirmingCancellation, titleVisibility: .visible) {
                Button("取消報名", role: .destructive) {
                    onCancel(event.eventSerialID)
                    dismiss()
                }
                Button("保留報名", role: .cancel) {}
            } message: {
                Text("「\(event.name)」取消後可能無法再報名，App 會再到已報名列表確認結果。")
            }
        }
    }
    
    // 校方列出「修改資料」按鈕，或活動尚未結束時才能修改
    private var canModify: Bool {
        event.offersModification || !event.hasEnded
    }

    // 校方列出「取消報名」按鈕，或報名狀態仍有效時才能取消（例如已報名、正取、候補）
    private var canCancel: Bool {
        guard !event.hasEnded, !event.state.contains("取消") else { return false }
        return event.offersCancellation
            || ["已報名", "報名成功", "正取", "備取", "候補"].contains(where: event.state.contains)
    }
    
}
