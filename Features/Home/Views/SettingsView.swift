import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showLogoutConfirm = false
    @State private var showReportAlert = false
    @State private var showMailError = false
    @State private var isRefreshingProfile = false
    @AppStorage("app.appearance.mode") private var appearanceModeRaw = AppAppearanceMode.system.rawValue

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Spacing.medium) {
                    accountSection
                    appearanceSection
                    actionsSection
                    notificationSection
                    aboutSection
                    logoutSection
                }
                .padding(Theme.Spacing.medium)
            }

            if showLogoutConfirm {
                logoutConfirmDialog
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.large)
        .alert("回報問題", isPresented: $showReportAlert) {
            Button("傳送（含設備資訊）") { sendReport(includeDeviceInfo: true) }
            Button("傳送（不含設備資訊）") { sendReport(includeDeviceInfo: false) }
            Button("取消", role: .cancel) {}
        }
        .alert("無法開啟郵件 App", isPresented: $showMailError) {
            Button("好") {}
        } message: {
            Text("請先在此裝置設定可用的郵件 App。")
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(spacing: Theme.Spacing.small) {
            NIUCard {
                VStack(spacing: Theme.Spacing.small) {
                    NIUAvatar(appState.currentUser?.name ?? "User", size: .large)

                    VStack(spacing: 4) {
                        Text(appState.currentUser?.name ?? "-")
                            .font(.system(size: 20, weight: .bold))

                        Text(appState.currentUser?.username ?? "-")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(.secondaryLabel))
                    }

                    Divider().padding(.vertical, Theme.Spacing.xsmall)

                    SettingsInfoRow(icon: "building.2", title: "系所", value: displayDepartment)
                    SettingsInfoRow(icon: "calendar", title: "年級", value: displayGrade)
                    SettingsInfoRow(icon: "clock", title: "最後登入", value: lastLoginText)
                }
            }
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            sectionLabel("外觀")

            NIUCard {
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)

                    Text("顯示模式")
                        .font(.system(size: 16, weight: .medium))

                    Spacer()

                    Picker("", selection: appearanceSelectionBinding) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            sectionLabel("同步")

            Button { Task { await refreshProfile() } } label: {
                SettingsActionRow(
                    icon: "arrow.clockwise",
                    title: "重新抓取個人資訊",
                    subtitle: "更新系所、年級與登入狀態"
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Notification Section

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            sectionLabel("通知")

            NavigationLink(destination: NotificationMenuView()) {
                SettingsNavigationRow(icon: "bell.badge.fill", title: "通知設定", subtitle: "作業死線、重要日期、上課提醒、即時動態")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            sectionLabel("關於")

            VStack(spacing: Theme.Spacing.xsmall) {
                SettingsInfoRow(icon: "info.circle.fill", title: "版本", value: appVersionText)

                Button { showReportAlert = true } label: {
                    SettingsNavigationRow(icon: "exclamationmark.bubble.fill", title: "回報問題", subtitle: "hi@chien.dev")
                }
                .buttonStyle(.plain)

                NavigationLink(destination: PrivacyPolicyView()) {
                    SettingsNavigationRow(icon: "shield.lefthalf.filled", title: "隱私權聲明", subtitle: "查看資料處理說明")
                }
                .buttonStyle(.plain)

                NavigationLink(destination: SpecialThanksView()) {
                    SettingsNavigationRow(icon: "heart.text.square.fill", title: "特別感謝", subtitle: "致謝開源專案開發者")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Logout Section

    private var logoutSection: some View {
        Button { showLogoutConfirm = true } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                Text("登出")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                    .fill(Color.red.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.Spacing.small)
    }

    // MARK: - Logout Dialog

    private var logoutConfirmDialog: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { showLogoutConfirm = false }

            VStack(spacing: Theme.Spacing.large) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(.red)

                Text("確定要登出嗎？")
                    .font(.system(size: 20, weight: .semibold))

                Button {
                    showLogoutConfirm = false
                    appState.logout()
                    dismiss()
                } label: {
                    Text("登出")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule(style: .continuous).fill(Color.red))
                }
                .buttonStyle(.plain)

                Button { showLogoutConfirm = false } label: {
                    Text("取消")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.xlarge, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .cardShadow(Theme.Shadow.large)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(.secondaryLabel))
            .padding(.leading, Theme.Spacing.xsmall)
    }

    private var appVersionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(v) (\(b))"
    }

    private var appearanceSelectionBinding: Binding<AppAppearanceMode> {
        Binding(
            get: { AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    private var lastLoginText: String {
        guard let date = UserDefaults.standard.object(forKey: "app.user.loginTime") as? Date else { return "-" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy年MM月dd日 HH:mm"
        return f.string(from: date)
    }

    private var displayDepartment: String {
        normalized(from: appState.currentUser?.department) ?? "-"
    }

    private var displayGrade: String {
        appState.currentUser?.grade ?? "-"
    }

    private func normalized(from raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        for p in ["系所年級：", "系所年級:", "系所：", "系所:"] where t.hasPrefix(p) {
            let v = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        return t
    }

    private func refreshProfile() async {
        isRefreshingProfile = true
        await appState.refreshProfileIfNeeded(force: true)
        UserDefaults.standard.set(Date(), forKey: "app.user.loginTime")
        isRefreshingProfile = false
    }

    private func sendReport(includeDeviceInfo: Bool) {
        guard let url = makeMailURL(includeDeviceInfo: includeDeviceInfo) else {
            showMailError = true
            return
        }
        openURL(url) { if !$0 { showMailError = true } }
    }

    private func makeMailURL(includeDeviceInfo: Bool) -> URL? {
        let subject = "NIU App 問題回報"
        let body: String
        if includeDeviceInfo {
            body = """
        問題描述


        設備資訊
        - App 版本：\(appVersionText)
        - iOS：\(UIDevice.current.systemVersion)
        - 裝置：\(UIDevice.current.model)
        - 裝置名稱：\(UIDevice.current.name)
        - 語系：\(Locale.current.identifier)
        - 時區：\(TimeZone.current.identifier)
        """
        } else {
            body = "問題描述\n\n\n（未附帶設備資訊）"
        }
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "" }
        return URL(string: "mailto:hi@chien.dev?subject=\(enc(subject))&body=\(enc(body))")
    }
}

// MARK: - Settings Info Row (display only)

struct SettingsInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.label))

            Spacer()

            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(Color(.secondaryLabel))
        }
        .padding(.vertical, Theme.Spacing.xsmall)
    }
}

// MARK: - Settings Action Row (button with action)

struct SettingsActionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.label))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.tertiaryLabel))
            }

            Spacer()
        }
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Settings Navigation Row (NavigationLink wrapper)

struct SettingsNavigationRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.label))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.tertiaryLabel))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Notification Menu View

private struct NotificationMenuView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isRefreshingNotifications = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Spacing.xsmall) {
                    notificationToggle(
                        icon: "checklist.checked",
                        title: "作業死線通知",
                        subtitle: "Moodle 作業截止前一天提醒",
                        isOn: Binding(
                            get: { appState.notificationSettings.assignmentDeadlineEnabled },
                            set: { newValue in Task { await appState.setAssignmentNotificationsEnabled(newValue) } }
                        )
                    )

                    notificationToggle(
                        icon: "calendar.badge.exclamationmark",
                        title: "重要日期通知",
                        subtitle: "學年行事曆重要日期前一天提醒",
                        isOn: Binding(
                            get: { appState.notificationSettings.academicCalendarEnabled },
                            set: { newValue in Task { await appState.setCalendarNotificationsEnabled(newValue) } }
                        )
                    )

                    notificationToggle(
                        icon: "bell.and.waves.left.and.right",
                        title: "上課前提醒",
                        subtitle: "每週固定於上課前 10 分鐘提醒",
                        isOn: Binding(
                            get: { appState.notificationSettings.classReminderEnabled },
                            set: { newValue in Task { await appState.setClassRemindersEnabled(newValue) } }
                        )
                    )

                    notificationToggle(
                        icon: "rectangle.topthird.inset.filled",
                        title: "即時動態（Live Activities）",
                        subtitle: "鎖定畫面與靈動島顯示下一堂課",
                        isOn: Binding(
                            get: { appState.notificationSettings.classLiveActivityEnabled },
                            set: { newValue in Task { await appState.setClassLiveActivityEnabled(newValue) } }
                        )
                    )

                    RemoteActivitySettingsRow(appState: appState)

                    Button {
                        Task {
                            isRefreshingNotifications = true
                            await appState.refreshNotificationSchedules()
                            isRefreshingNotifications = false
                        }
                    } label: {
                        HStack(spacing: Theme.Spacing.medium) {
                            Image(systemName: "bell.badge")
                                .font(.system(size: 17, weight: .light))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.accentColor.opacity(0.12)))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("立即更新通知")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color(.label))
                                Text(isRefreshingNotifications ? "更新中..." : "重新同步通知與即時動態")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }

                            Spacer()

                            if isRefreshingNotifications {
                                ProgressView().scaleEffect(0.8)
                            }
                        }
                        .padding(Theme.Spacing.medium)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Spacing.medium)
            }
        }
        .navigationTitle("通知設定")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func notificationToggle(icon: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.label))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.tertiaryLabel))
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppState())
    }
}


private struct RemoteActivitySettingsRow: View {
    @ObservedObject var appState: AppState
    @AppStorage(LiveActivityRemoteClient.consentKey) private var consent = false
    @State private var showConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("背景即時動態更新", isOn: Binding(
                get: { consent },
                set: { enabled in
                    if enabled { showConsent = true }
                    else { Task { await appState.setRemoteLiveActivityEnabled(false) } }
                }
            ))
            .disabled(LiveActivityRemoteClient.baseURL == nil || !appState.notificationSettings.classLiveActivityEnabled)
            Text(LiveActivityRemoteClient.baseURL == nil
                 ? "遠端更新服務尚未設定；課表與 Widget 仍可使用本機資料。"
                 : "啟用後傳送本次活動所需的課程名稱、教室、教師、時間與推播識別碼，供背景更新。資料短期保存；可隨時關閉。更新時間受網路與 iOS 排程影響。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .alert("啟用背景即時動態更新？", isPresented: $showConsent) {
            Button("取消", role: .cancel) { }
            Button("同意並啟用") { Task { await appState.setRemoteLiveActivityEnabled(true) } }
        } message: {
            Text("本次活動所需的課程資訊與推播識別碼會傳送至服務，經 Apple 推播更新鎖定畫面。活動資料最長保存 24 小時，不傳送學號、密碼或校務登入資訊。關閉不影響本機課表與 Widget。")
        }
    }
}
