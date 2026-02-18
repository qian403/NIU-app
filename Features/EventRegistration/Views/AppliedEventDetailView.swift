import SwiftUI

struct AppliedEventDetailView: View {
    let event: EventData_Apply
    @Environment(\.dismiss) private var dismiss
    let onCancel: (String) -> Void
    let onModify: (EventData_Apply) -> Void
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 活動標題
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.name)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.black)
                        
                        HStack {
                            Text(event.state)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(8)
                            
                            Text(event.event_state)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(eventStateColor.opacity(0.2))
                                .foregroundColor(eventStateColor)
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
                    }
                    
                    Divider()
                    
                    // 活動說明
                    if !event.eventDetail.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("活動說明")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.black)
                            Text(event.eventDetail.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n"))
                                .font(.system(size: 14))
                                .foregroundColor(.black.opacity(0.7))
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
                            .foregroundColor(.black)
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
                                .foregroundColor(.black)
                            Text(event.Remark.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n"))
                                .font(.system(size: 14))
                                .foregroundColor(.black.opacity(0.7))
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
            }
            .background(Color.white)
            .navigationTitle("活動詳情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") {
                        dismiss()
                    }
                    .foregroundColor(.black)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    // 修改報名資訊按鈕
                    if canModify {
                        Button(action: {
                            onModify(event)
                            dismiss()
                        }) {
                            HStack {
                                Image(systemName: "pencil")
                                Text("修改報名資訊")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                    
                    // 取消報名按鈕
                    if canCancel {
                        Button(action: {
                            onCancel(event.eventSerialID)
                            dismiss()
                        }) {
                            HStack {
                                Image(systemName: "xmark.circle")
                                Text("取消報名")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                }
                .padding()
                .background(Color.white)
            }
        }
        .preferredColorScheme(.light)
    }
    
    // 是否可以修改
    private var canModify: Bool {
        // 活動進行中或未開始才能修改
        !event.event_state.contains("已結束")
    }
    
    // 是否可以取消
    private var canCancel: Bool {
        // 報名狀態為已報名才能取消
        event.state.contains("已報名") || event.state.contains("報名成功")
    }
    
    private var eventStateColor: Color {
        switch event.event_state {
        case let state where state.contains("進行中"):
            return .green
        case let state where state.contains("已結束"):
            return .gray
        default:
            return .blue
        }
    }
}
