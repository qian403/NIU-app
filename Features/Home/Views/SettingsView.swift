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
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    accountSection
                    appearanceSection
                    actionsSection
                    notificationEntrySection
                    aboutSection
                    statementSection
                    logoutSection
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.large)
            }

            if showLogoutConfirm {
                Color.primary.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showLogoutConfirm = false
                    }

                VStack(spacing: 20) {
                    Text("確定要登出嗎？")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.primary)

                    Button(role: .destructive) {
                        showLogoutConfirm = false
                        appState.logout()
                        dismiss()
                    } label: {
                        Text("登出")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 44)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(24)
                .frame(maxWidth: 470)
                .background(
                    RoundedRectangle(cornerRadius: 30)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30)
                        .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: Color.primary.opacity(0.08), radius: 14, x: 0, y: 6)
                .padding(.horizontal, 30)
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .alert("回報問題", isPresented: $showReportAlert) {
            Button("傳送（含設備資訊）") {
                sendIssueReport(includeDeviceInfo: true)
            }
            Button("傳送（不含設備資訊）") {
                sendIssueReport(includeDeviceInfo: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("請選擇是否附帶設備資訊。")
        }
        .alert("無法開啟郵件 App", isPresented: $showMailError) {
            Button("好") {}
        } message: {
            Text("請先在此裝置設定可用的郵件 App。")
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("帳號")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.45))

            VStack(alignment: .leading, spacing: 8) {
                settingsLine(title: "姓名", value: appState.currentUser?.name ?? "-")
                settingsLine(title: "學號", value: appState.currentUser?.username ?? "-")
                settingsLine(title: "系所", value: displayDepartment)
                settingsLine(title: "年級", value: displayGrade)
            }
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("同步")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.45))

            Button {
                Task { await refreshProfile() }
            } label: {
                settingsActionRow(
                    icon: "arrow.clockwise",
                    title: "重新抓取個人資訊",
                    subtitle: "更新系所、年級與登入狀態",
                    trailingText: isRefreshingProfile ? "更新中..." : nil,
                    isLoading: isRefreshingProfile
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外觀")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.45))

            VStack(alignment: .leading, spacing: 12) {
                Text("顯示模式")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)

                Picker("顯示模式", selection: appearanceSelectionBinding) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("關於")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.45))

            VStack(alignment: .leading, spacing: 8) {
                settingsLine(title: "版本", value: appVersionText)
                settingsLine(title: "最後登入", value: lastLoginText)
            }
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )

            Button {
                showReportAlert = true
            } label: {
                settingsActionRow(
                    icon: "exclamationmark.bubble",
                    title: "回報問題",
                    subtitle: "寄信到 hi@chien.dev 回報任何使用上的問題或建議",
                    trailingText: nil
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var notificationEntrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通知")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.45))

            NavigationLink(destination: NotificationMenuView()) {
                settingsActionRow(
                    icon: "bell.badge",
                    title: "通知設定",
                    subtitle: "管理作業死線與重要日期提醒",
                    trailingText: nil
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var logoutSection: some View {
        Button(role: .destructive) {
            showLogoutConfirm = true
        } label: {
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                Text("登出")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundColor(.red)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var statementSection: some View {
        NavigationLink(destination: StatementMenuView()) {
            settingsActionRow(
                icon: "doc.text",
                title: "聲明",
                subtitle: "隱私權聲明與特別感謝",
                trailingText: nil
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func settingsLine(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(.primary.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
                .multilineTextAlignment(.trailing)
        }
    }

    private func settingsActionRow(
        icon: String,
        title: String,
        subtitle: String,
        trailingText: String?,
        isLoading: Bool = false
    ) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.primary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                )
                .rotationEffect(isLoading ? .degrees(360) : .degrees(0))
                .animation(
                    isLoading
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .default,
                    value: isLoading
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.primary.opacity(0.5))
            }

            Spacer()

            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.45))
            } else if isLoading {
                ProgressView()
                    .scaleEffect(0.85)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.primary.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var appearanceSelectionBinding: Binding<AppAppearanceMode> {
        Binding(
            get: { AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { appearanceModeRaw = $0.rawValue }
        )
    }

    private var lastLoginText: String {
        guard let date = UserDefaults.standard.object(forKey: "app.user.loginTime") as? Date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        return formatter.string(from: date)
    }

    private var displayDepartment: String {
        normalizedDepartment(from: appState.currentUser?.department) ?? "-"
    }

    private var displayGrade: String {
        appState.currentUser?.grade ?? "-"
    }

    private func normalizedDepartment(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let prefixes = ["系所年級：", "系所年級:", "系所：", "系所:"]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return trimmed
    }

    private func refreshProfile() async {
        isRefreshingProfile = true
        await appState.refreshProfileIfNeeded(force: true)
        UserDefaults.standard.set(Date(), forKey: "app.user.loginTime")
        isRefreshingProfile = false
    }

    private func sendIssueReport(includeDeviceInfo: Bool) {
        guard let url = makeIssueMailURL(includeDeviceInfo: includeDeviceInfo) else {
            showMailError = true
            return
        }
        openURL(url) { accepted in
            if !accepted {
                showMailError = true
            }
        }
    }

    private func makeIssueMailURL(includeDeviceInfo: Bool) -> URL? {
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
            body = """
        問題描述
        
        
        （未附帶設備資訊）
        """
        }

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:hi@chien.dev?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}

private struct NotificationMenuView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isRefreshingNotifications = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                notificationToggleRow(
                    icon: "checklist.checked",
                    title: "作業死線通知",
                    subtitle: "Moodle 作業截止前一天提醒",
                    isOn: Binding(
                        get: { appState.notificationSettings.assignmentDeadlineEnabled },
                        set: { newValue in
                            Task { await appState.setAssignmentNotificationsEnabled(newValue) }
                        }
                    )
                )

                notificationToggleRow(
                    icon: "calendar.badge.exclamationmark",
                    title: "重要日期通知",
                    subtitle: "學年行事曆重要日期前一天提醒",
                    isOn: Binding(
                        get: { appState.notificationSettings.academicCalendarEnabled },
                        set: { newValue in
                            Task { await appState.setCalendarNotificationsEnabled(newValue) }
                        }
                    )
                )

                notificationToggleRow(
                    icon: "bell.and.waves.left.and.right",
                    title: "上課前提醒",
                    subtitle: "每週固定於上課前 10 分鐘提醒教室",
                    isOn: Binding(
                        get: { appState.notificationSettings.classReminderEnabled },
                        set: { newValue in
                            Task { await appState.setClassRemindersEnabled(newValue) }
                        }
                    )
                )

                notificationToggleRow(
                    icon: "rectangle.topthird.inset.filled",
                    title: "即時動態（Live Activities）",
                    subtitle: "鎖定畫面與靈動島顯示下一堂課與教室",
                    isOn: Binding(
                        get: { appState.notificationSettings.classLiveActivityEnabled },
                        set: { newValue in
                            Task { await appState.setClassLiveActivityEnabled(newValue) }
                        }
                    )
                )

                Button {
                    Task {
                        isRefreshingNotifications = true
                        await appState.refreshNotificationSchedules()
                        isRefreshingNotifications = false
                    }
                } label: {
                    actionRow(
                        icon: "bell.badge",
                        title: "立即更新通知",
                        subtitle: "重新同步通知與即時動態",
                        trailingText: isRefreshingNotifications ? "更新中..." : nil
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.medium)
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func actionRow(
        icon: String,
        title: String,
        subtitle: String,
        trailingText: String?
    ) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.primary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.primary.opacity(0.5))
            }

            Spacer()

            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.45))
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.primary.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func notificationToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.primary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.primary.opacity(0.5))
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct StatementMenuView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: Theme.Spacing.medium) {
                NavigationLink(destination: SettingsPrivacyPolicyView()) {
                    statementRow(
                        icon: "shield.lefthalf.filled",
                        title: "隱私權聲明",
                        subtitle: "查看資料處理與使用說明"
                    )
                }
                .buttonStyle(PlainButtonStyle())

                NavigationLink(destination: SpecialThanksView()) {
                    statementRow(
                        icon: "heart.text.square",
                        title: "特別感謝",
                        subtitle: "致謝開源專案開發者"
                    )
                }
                .buttonStyle(PlainButtonStyle())

                NavigationLink(destination: LicenseView()) {
                    statementRow(
                        icon: "doc.plaintext",
                        title: "LICENSE",
                        subtitle: "查看開源授權條款"
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.medium)
        }
        .navigationTitle("聲明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statementRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.primary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.primary.opacity(0.5))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .light))
                .foregroundColor(.primary.opacity(0.3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct SettingsPrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("隱私權聲明 (Privacy Policy)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)

                Text("感謝您下載並使用本應用程式（以下簡稱「本 App」）。本 App 致力於保護您的個人隱私，並確保您在使用校務相關功能時的資訊安全。在使用本 App 前，請詳閱以下聲明：")

                Text("一、重要聲明：非官方性質")
                    .font(.system(size: 17, weight: .semibold))
                Text("本 App 為個人開發之第三方校務輔助工具，與「國立宜蘭大學 (NIU)」官方並無任何隸屬、合作或授權關係。本 App 透過原生介面整合校務入口，提供課表/成績查詢、Moodle 整合、活動報名、行事曆匯出與通知管理等功能，以提升行動端使用體驗。")

                Text("二、帳號登入與個人資料處理")
                    .font(.system(size: 17, weight: .semibold))
                Text("登入資訊：當您登入校務帳號時，您的帳號與密碼將直接傳送至學校官方伺服器進行身分驗證。本 App 不會記錄、儲存、攔截或傳送您的校務帳號與密碼至開發者伺服器或任何第三方平台。")
                Text("校務資料存取：本 App 獲取之課表、成績、缺曠課等個人資訊，僅限於提供您在行動裝置上查看與管理之用。")

                Text("三、資料儲存與保護機制")
                    .font(.system(size: 17, weight: .semibold))
                Text("本地存儲 (Local Storage)：為提升使用流暢度，您的基本校務資訊（如課表、姓名等）將加密儲存於您的行動裝置本地端。")
                Text("Session 與 Cookie：系統會暫存必要的 Session 資訊以維持登入狀態。您隨時可以透過 App 內的「登出」功能，立即清除本機端儲存的所有登入資訊與暫存檔案。")

                Text("四、數據收集與技術分析")
                    .font(.system(size: 17, weight: .semibold))
                Text("為了持續優化 App 品質，我們會收集部分匿名且無法辨識個人身分的統計數據，包括：")
                Text("使用統計：例如每日活躍人數 (DAU)、各功能點擊頻率。")
                Text("錯誤回報：App 閃退或載入失敗時的去識別化系統錯誤紀錄。")
                Text("上述數據僅用於技術改善與效能優化，不包含任何姓名、學號或敏感個資。")

                Text("五、第三方連結與免責聲明")
                    .font(.system(size: 17, weight: .semibold))
                Text("外部連結：本 App 部分功能可能導向學校官方網頁。對於外部網站的隱私權政策，本 App 不負任何法律責任。")
                Text("資料準確性：所有校務資訊均同步自學校伺服器，若資料有誤，請以學校官方行政系統為準。")
                Text("安全風險：請確保您的行動裝置環境安全。若因裝置遭惡意程式入侵或遺失而導致資料流失，開發者概不負責。")

                Text("六、隱私權聲明之修改")
                    .font(.system(size: 17, weight: .semibold))
                Text("開發者保留隨時修改本聲明之權利。修改後的條款將直接更新於本 App 內，不另行個別通知，建議您定期查看。")

                Text("七、聯繫方式")
                    .font(.system(size: 17, weight: .semibold))
                Text("若您對本隱私權聲明或資料處理方式有任何疑問、建議或發現潛在漏洞，歡迎透過以下方式聯繫開發者：")
                Text("開發者聯絡信箱：hi@chien.dev")
                Text("GitHub 專案頁面：https://github.com/qian403/NIU-app")
            }
            .font(.system(size: 15))
            .foregroundColor(.primary.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("隱私權聲明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpecialThanksView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("感謝下列開源專案與開發者提供靈感與參考：")
                    .font(.system(size: 15))
                    .foregroundColor(.primary.opacity(0.75))

                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    HStack(spacing: 12) {
                        Image(systemName: "heart.text.square")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.04))
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("KennyYang0726")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("NIU_APP_IOS 開發者")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.primary.opacity(0.6))
                        }
                    }

                    if let projectURL = URL(string: "https://github.com/KennyYang0726/NIU_APP_IOS?tab=readme-ov-file") {
                        Link(destination: projectURL) {
                            HStack {
                                Text("查看專案")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, Theme.Spacing.medium)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .contentShape(Rectangle())
                        }
                    }
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("特別感謝")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseView: View {
    private var licenseText: String {
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return "目前 App 內未包含 LICENSE 檔案。\n你可以透過下方連結查看："
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("LICENSE")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)

                Text(licenseText)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if let licenseURL = URL(string: "https://github.com/qian403/NIU-app/blob/main/LICENSE") {
                    Link("GitHub LICENSE", destination: licenseURL)
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("LICENSE")
        .navigationBarTitleDisplayMode(.inline)
    }
}
