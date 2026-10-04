import SwiftUI

/// Shared by the real settings screen and a pure offline preview (no AppState, Keychain or notification center).
struct EventReminderSettingsSection: View {
    @Binding var enabled: Bool
    @Binding var leadTime: EventReminderLeadTime
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $enabled) {
                Label("已報名活動提醒", systemImage: "calendar.badge.clock")
                    .font(.body)
            }
            .tint(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("活動開始前").font(.subheadline)
                Picker("活動開始前", selection: $leadTime) {
                    ForEach(EventReminderLeadTime.allCases) { lead in Text(lead.label).tag(lead) }
                }
                .labelsHidden()
            }
            .disabled(!enabled)
            Text("只提醒已確認報名的活動；候補、待審核與未知狀態不安排。依校方活動時間（臺北時間）在此裝置提醒，不上傳提醒設定。")
                .font(.footnote).foregroundStyle(.secondary)
            Text(status)
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("eventReminderStatus")
            Text("開啟 App、回到前景或變更報名時核對。App 關閉期間，校方時間或報名異動不保證即時同步。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

#if DEBUG
struct EventReminderSettingsPreview: View {
    @State private var enabled = true
    @State private var leadTime: EventReminderLeadTime = .oneDay
    var status = "已安排 2 個活動提醒\n1 個活動缺少可辨識的開始日期與時間，未安排"

    var body: some View {
        NavigationStack {
            ScrollView {
                EventReminderSettingsSection(enabled: $enabled, leadTime: $leadTime, status: status).padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("通知設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("活動提醒設定・離線") { EventReminderSettingsPreview() }
#Preview("通知未允許・離線") {
    EventReminderSettingsPreview(status: "系統通知尚未允許，未安排活動提醒；請至 iOS 設定開啟通知。")
}
#endif
