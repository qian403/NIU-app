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

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    accountSection
                    actionsSection
                    aboutSection
                    logoutSection
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.large)
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "確定要登出嗎？",
            isPresented: $showLogoutConfirm,
            titleVisibility: .visible
        ) {
            Button("登出", role: .destructive) {
                appState.logout()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
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
                .foregroundColor(.black.opacity(0.45))

            VStack(alignment: .leading, spacing: 8) {
                settingsLine(title: "姓名", value: appState.currentUser?.name ?? "-")
                settingsLine(title: "學號", value: appState.currentUser?.username ?? "-")
                settingsLine(title: "系所", value: displayDepartment)
                settingsLine(title: "年級", value: displayGrade)
            }
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("同步")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black.opacity(0.45))

            Button {
                Task { await refreshProfile() }
            } label: {
                settingsActionRow(
                    icon: "arrow.clockwise",
                    title: "重新抓取個人資訊",
                    subtitle: "更新系所、年級與登入狀態",
                    trailingText: isRefreshingProfile ? "更新中..." : nil
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("關於")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black.opacity(0.45))

            VStack(alignment: .leading, spacing: 8) {
                settingsLine(title: "版本", value: appVersionText)
                settingsLine(title: "最後登入", value: lastLoginText)
            }
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
            )

            Button {
                showReportAlert = true
            } label: {
                settingsActionRow(
                    icon: "exclamationmark.bubble",
                    title: "回報問題",
                    subtitle: "寄信到 hi@chien.dev（含設備資訊）",
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

    private func settingsLine(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(.black.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.black.opacity(0.8))
                .multilineTextAlignment(.trailing)
        }
    }

    private func settingsActionRow(
        icon: String,
        title: String,
        subtitle: String,
        trailingText: String?
    ) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.black)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.black)
                Text(subtitle)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.black.opacity(0.5))
            }

            Spacer()

            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.45))
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.black.opacity(0.3))
            }
        }
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var lastLoginText: String {
        guard let date = UserDefaults.standard.object(forKey: "app.user.loginTime") as? Date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
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
