import SwiftUI
import WebKit
import Combine

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        headerSection
                            .padding(.horizontal, Theme.Spacing.large)
                            .padding(.top, Theme.Spacing.medium)
                        
                        welcomeSection
                            .padding(.horizontal, Theme.Spacing.large)
                            .padding(.top, Theme.Spacing.small)
                        
                        featureCards
                            .padding(.horizontal, Theme.Spacing.large)
                            .padding(.top, Theme.Spacing.large)
                            .padding(.bottom, Theme.Spacing.large)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .task {
            await appState.refreshProfileIfNeeded()
        }
    }
    
    private var headerSection: some View {
        HStack {
            NavigationLink(destination: SettingsView()) {
                Circle()
                    .strokeBorder(Color.primary, lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(appState.currentUser?.name.prefix(1).uppercased() ?? "U")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            
            Spacer()
            
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.primary)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome back,")
                .font(.system(size: 24, weight: .thin))
                .foregroundColor(.primary.opacity(0.6))
            
            Text(appState.currentUser?.name ?? "User")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.primary)
                .padding(.bottom, 4)
            
            // 學生資訊 - 緊湊排列
            if let user = appState.currentUser {
                VStack(alignment: .leading, spacing: 2) {
                    if let department = user.department {
                        HStack(spacing: 6) {
                            Image(systemName: "building.2")
                                .font(.system(size: 12))
                                .foregroundColor(.primary.opacity(0.5))
                            Text(normalizedDepartment(from: department))
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.primary.opacity(0.7))
                        }
                    }
                    
                    HStack(spacing: 12) {
                        if let grade = user.grade {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary.opacity(0.5))
                                Text(grade)
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.primary.opacity(0.7))
                            }
                        }
                        
                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .font(.system(size: 12))
                                .foregroundColor(.primary.opacity(0.5))
                            Text(user.username)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.primary.opacity(0.7))
                        }
                    }
                }
            }
            
            if let loginTime = UserDefaults.standard.object(forKey: "app.user.loginTime") as? Date {
                Text("Last login: \(loginTime, style: .relative)")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.primary.opacity(0.4))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
	    private var featureCards: some View {
	        VStack(spacing: Theme.Spacing.medium) {
	            // M 園區
	            NavigationLink(destination: MoodleView()) {
	                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "graduationcap")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("M 園區")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)

                        Text("Moodle 課程、公告與作業")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.primary.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
	                }
	                .padding(Theme.Spacing.medium)
	                .background(
	                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
	                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
	                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
	            }
	            .buttonStyle(PlainButtonStyle())

	            // 我的課表
	            NavigationLink(destination: ClassScheduleView()) {
	                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的課表")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)

                        Text("查看每週課程安排")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.primary.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
	                }
	                .padding(Theme.Spacing.medium)
	                .background(
	                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
	                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
	                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
	            }
	            .buttonStyle(PlainButtonStyle())

	            // 學年度行事曆
	            NavigationLink(destination: AcademicCalendarView()) {
	                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "calendar")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("學年度行事曆")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text("查看學期重要日程")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.primary.opacity(0.5))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
	            }
	            .buttonStyle(PlainButtonStyle())
	            
	            // 活動報名
            NavigationLink(destination: EventRegistrationView()) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("活動報名")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text("查看與報名校園活動")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.primary.opacity(0.5))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 成績查詢
            NavigationLink(destination: GradeHistoryView()) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "doc.text.below.ecg")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("成績查詢")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)

                        Text("期中、期末與歷年成績")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.primary.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 畢業門檻
            NavigationLink(destination: GraduationRequirementsView()) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "flag.checkered.2.crossed")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("畢業門檻")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)

                        Text("追蹤學分與畢業條件進度")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.primary.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.primary.opacity(0.3))
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("更多功能")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary.opacity(0.5))
                    .padding(.top, Theme.Spacing.small)

                NavigationLink(destination: MoreFeaturesMenuView()) {
                    HStack(spacing: Theme.Spacing.medium) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.primary)
                            .frame(width: 50, height: 50)
                            .background(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("更多功能")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)

                            Text("更多功能")
                                .font(.system(size: 13, weight: .light))
                                .foregroundColor(.primary.opacity(0.5))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.primary.opacity(0.3))
                    }
                    .padding(Theme.Spacing.medium)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func normalizedDepartment(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["系所年級：", "系所年級:", "系所：", "系所:"]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? trimmed : value
        }
        return trimmed
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}

private enum RequirementStatus: String {
    case passed
    case pending
    case notRequired
    case unknown

    var text: String {
        switch self {
        case .passed: return "已達成"
        case .pending: return "待完成"
        case .notRequired: return "不計入"
        case .unknown: return "未知"
        }
    }

    var icon: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .pending: return "exclamationmark.circle.fill"
        case .notRequired: return "minus.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed: return .green
        case .pending: return .orange
        case .notRequired: return .gray
        case .unknown: return .primary.opacity(0.45)
        }
    }
}

private struct DiverseRequirementItem: Identifiable, Codable {
    let id: String
    let title: String
    let currentText: String
    let requiredText: String

    var currentValue: Double? { Self.parseNumber(currentText) }
    var requiredValue: Double? { Self.parseNumber(requiredText) }

    var status: RequirementStatus {
        if requiredText.contains("不計入") || requiredText.contains("免") {
            return .notRequired
        }
        guard let currentValue, let requiredValue, requiredValue > 0 else {
            return .unknown
        }
        return currentValue >= requiredValue ? .passed : .pending
    }

    var progress: Double {
        guard let currentValue, let requiredValue, requiredValue > 0 else { return 0 }
        return min(1, currentValue / requiredValue)
    }

    private static func parseNumber(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let pattern = #"-?\d+(\.\d+)?"#
        guard let range = cleaned.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(cleaned[range])
    }
}

private struct GraduationRequirementsSnapshot: Codable {
    let englishText: String
    let physicalText: String
    let creditsRequiredText: String
    let creditsEarnedText: String
    let diverseItems: [DiverseRequirementItem]
    let programs: [String]

    var englishStatus: RequirementStatus { Self.status(from: englishText) }
    var physicalStatus: RequirementStatus { Self.status(from: physicalText) }

    var creditsRequiredValue: Double? { Self.parseNumber(creditsRequiredText) }
    var creditsEarnedValue: Double? { Self.parseNumber(creditsEarnedText) }
    var creditProgress: Double {
        guard let earned = creditsEarnedValue, let required = creditsRequiredValue, required > 0 else { return 0 }
        return min(1, earned / required)
    }

    var pendingCount: Int {
        var count = 0
        if englishStatus == .pending { count += 1 }
        if physicalStatus == .pending { count += 1 }
        count += diverseItems.filter { $0.status == .pending }.count
        if let earned = creditsEarnedValue, let required = creditsRequiredValue, earned < required {
            count += 1
        }
        return count
    }

    private static func status(from rawText: String) -> RequirementStatus {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .unknown }
        if text.contains("免") || text.contains("不計入") { return .notRequired }
        if text.contains("未") || text.contains("不通過") || text.contains("不符") { return .pending }
        return .passed
    }

    private static func parseNumber(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        let pattern = #"-?\d+(\.\d+)?"#
        guard let range = cleaned.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(cleaned[range])
    }
}

private enum GraduationWebResult {
    case success(GraduationRequirementsSnapshot)
    case sessionExpired
    case failure(String)
}

private struct GraduationRawDTO: Decodable {
    let englishText: String
    let physicalText: String
    let creditsRequiredText: String
    let creditsEarnedText: String
    let diverseValues: [String]
    let programsText: String
}

private struct GraduationRequirementsView: View {
    @StateObject private var vm = GraduationRequirementsViewModel()

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    if let snapshot = vm.snapshot {
                        summaryHero(snapshot: snapshot)
                        statusCards(snapshot: snapshot)
                        diverseSection(snapshot: snapshot)
                        programsSection(snapshot: snapshot)
                    } else {
                        placeholderSection
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.medium)
            }
            .refreshable {
                await vm.pullToRefresh()
            }
        }
        .navigationTitle("畢業門檻")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if vm.showWebView {
                GraduationRequirementsWebView(onResult: vm.handleWebResult)
                    .frame(width: 360, height: 640)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var placeholderSection: some View {
        VStack(spacing: 10) {
            if case .error(let message) = vm.state {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(.primary.opacity(0.4))
                Text(message)
                    .font(.system(size: 15))
                    .foregroundColor(.primary.opacity(0.65))
                    .multilineTextAlignment(.center)
                Text("請下拉重新整理")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary.opacity(0.45))
            } else if vm.state == .loading {
                Text("正在更新畢業門檻資料…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary.opacity(0.65))
                Text("可下拉重新整理")
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.45))
            } else {
                Text("目前尚無資料")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary.opacity(0.65))
                Text("請下拉重新整理")
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func summaryHero(snapshot: GraduationRequirementsSnapshot) -> some View {
        HStack(spacing: Theme.Spacing.large) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: snapshot.creditProgress)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text("\(Int(snapshot.creditProgress * 100))%")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                    Text("學分完成")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.primary.opacity(0.5))
                }
            }
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 10) {
                Text("畢業總覽")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primary)
                Text("已修 \(snapshot.creditsEarnedText) / 需修 \(snapshot.creditsRequiredText)")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.primary.opacity(0.65))
                Text(snapshot.pendingCount == 0 ? "目前所有條件都已達成" : "還有 \(snapshot.pendingCount) 項條件待完成")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(snapshot.pendingCount == 0 ? .green : .orange)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.large)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func statusCards(snapshot: GraduationRequirementsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("關鍵條件")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.primary.opacity(0.5))

            HStack(spacing: Theme.Spacing.small) {
                requirementCard(
                    title: "英文能力",
                    subtitle: snapshot.englishText.trimmedOrDash,
                    status: snapshot.englishStatus
                )
                requirementCard(
                    title: "體適能",
                    subtitle: snapshot.physicalText.trimmedOrDash,
                    status: snapshot.physicalStatus
                )
            }
        }
    }

    private func requirementCard(title: String, subtitle: String, status: RequirementStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: status.icon)
                    .foregroundColor(status.color)
                    .font(.system(size: 15))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }
            Text(status.text)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(status.color)
            Text(subtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.primary.opacity(0.5))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func diverseSection(snapshot: GraduationRequirementsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("多元時數")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.primary.opacity(0.5))

            VStack(spacing: Theme.Spacing.small) {
                ForEach(snapshot.diverseItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(item.currentText) / \(item.requiredText)")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.primary.opacity(0.55))
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                                Capsule()
                                    .fill(Color.primary)
                                    .frame(width: geo.size.width * item.progress)
                            }
                        }
                        .frame(height: 8)
                    }
                }
            }
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func programsSection(snapshot: GraduationRequirementsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("學分學程")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.primary.opacity(0.5))

            if snapshot.programs.isEmpty {
                Text("目前沒有學分學程資料")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.primary.opacity(0.55))
                    .padding(Theme.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                FlexibleTagList(tags: snapshot.programs)
                    .padding(Theme.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
        }
    }
}

@MainActor
private final class GraduationRequirementsViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var state: State = .idle
    @Published var showWebView = false
    @Published var snapshot: GraduationRequirementsSnapshot?

    private let cacheKey = "graduation.requirements.snapshot.v1"
    private let cacheDateKey = "graduation.requirements.snapshot.date.v1"
    private let cacheLifetime: TimeInterval = 12 * 60 * 60
    private var sessionRefreshAttempted = false

    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            snapshot = GraduationRequirementsSnapshot(
                englishText: "已通過",
                physicalText: "尚待完成",
                creditsRequiredText: "128",
                creditsEarnedText: "102",
                diverseItems: [
                    DiverseRequirementItem(id: "service", title: "服務", currentText: "10", requiredText: "12"),
                    DiverseRequirementItem(id: "diverse", title: "多元", currentText: "8", requiredText: "10"),
                    DiverseRequirementItem(id: "major", title: "專業", currentText: "6", requiredText: "6"),
                    DiverseRequirementItem(id: "integration", title: "綜合", currentText: "4", requiredText: "4")
                ],
                programs: ["人工智慧學程", "跨域數位設計學程"]
            )
            state = .loaded
            return
        }

        loadFromCache()
        refresh(force: false)
    }

    func refresh(force: Bool) {
        if !force,
           let lastDate = UserDefaults.standard.object(forKey: cacheDateKey) as? Date,
           Date().timeIntervalSince(lastDate) < cacheLifetime,
           snapshot != nil {
            state = .loaded
            return
        }
        state = .loading
        showWebView = true
    }

    func pullToRefresh() async {
        refresh(force: true)
        while state == .loading {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    func handleWebResult(_ result: GraduationWebResult) {
        showWebView = false

        switch result {
        case .success(let data):
            sessionRefreshAttempted = false
            snapshot = data
            state = .loaded
            saveToCache(data)

        case .sessionExpired:
            if !sessionRefreshAttempted {
                sessionRefreshAttempted = true
                Task {
                    let refreshed = await SSOSessionService.shared.requestRefresh()
                    if refreshed {
                        self.showWebView = true
                    } else {
                        self.state = .error("登入狀態已過期，請重新登入後再試")
                    }
                }
            } else {
                sessionRefreshAttempted = false
                state = .error("登入狀態已過期，請重新登入後再試")
            }

        case .failure(let message):
            if snapshot != nil {
                state = .loaded
            } else {
                state = .error(message)
            }
        }
    }

    private func loadFromCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let value = try? JSONDecoder().decode(GraduationRequirementsSnapshot.self, from: data) else {
            return
        }
        snapshot = value
        state = .loaded
    }

    private func saveToCache(_ value: GraduationRequirementsSnapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date(), forKey: cacheDateKey)
    }
}

private struct GraduationRequirementsWebView: UIViewRepresentable {
    let onResult: (GraduationWebResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/17.0 Safari/605.1.15"

        context.coordinator.webView = webView
        if let url = URL(string: "https://ccsys.niu.edu.tw/SSO/Std002.aspx") {
            webView.load(URLRequest(url: url))
        } else {
            context.coordinator.finish(.failure("無法建立畢業門檻連線"))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        let onResult: (GraduationWebResult) -> Void

        private var active = true
        private var step: Step = .resolveEntryLink

        private enum Step {
            case resolveEntryLink
            case waitForMainFrame
            case waitForThresholdPage
            case parse
        }

        init(onResult: @escaping (GraduationWebResult) -> Void) {
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active else { return }
            let url = webView.url?.absoluteString ?? ""

            if url.contains("/MvcTeam/Account/Login") || url.contains("/Account/Login") || url.contains("Default.aspx") {
                finish(.sessionExpired)
                return
            }

            switch step {
            case .resolveEntryLink:
                if url.contains("Std002.aspx") || url.contains("StdMain.aspx") {
                    extractAcadeEntryAndNavigate(webView: webView)
                } else if url.contains("MainFrame.aspx") {
                    step = .waitForThresholdPage
                    navigateToGraduationThreshold(webView: webView)
                }

            case .waitForMainFrame:
                if url.contains("MainFrame.aspx") {
                    step = .waitForThresholdPage
                    navigateToGraduationThreshold(webView: webView)
                }

            case .waitForThresholdPage:
                if url.contains("ENRG010_01.aspx") {
                    step = .parse
                    pollForSnapshot(webView: webView, attempt: 0)
                }

            case .parse:
                break
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard active else { return }
            finish(.failure("網路連線失敗：\(error.localizedDescription)"))
        }

        private func extractAcadeEntryAndNavigate(webView: WKWebView) {
            let js = """
            (function() {
                var el = document.getElementById('ctl00_ContentPlaceHolder1_RadListView1_ctrl0_HyperLink1');
                return el ? (el.getAttribute('href') || '') : '';
            })()
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, self.active else { return }
                let href = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !href.isEmpty else {
                    self.finish(.sessionExpired)
                    return
                }

                let fullURL: String
                if href.hasPrefix("http") {
                    fullURL = href
                } else {
                    let clean = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                    fullURL = "https://ccsys.niu.edu.tw/SSO/" + clean
                }

                guard let url = URL(string: fullURL) else {
                    self.finish(.failure("無法進入教務系統"))
                    return
                }

                self.step = .waitForMainFrame
                webView.load(URLRequest(url: url))
            }
        }

        private func navigateToGraduationThreshold(webView: WKWebView) {
            guard let url = URL(string: "https://acade.niu.edu.tw/NIU/Application/ENR/ENRG0/ENRG010_01.aspx") else {
                finish(.failure("畢業門檻頁面連結無效"))
                return
            }
            var request = URLRequest(url: url)
            request.setValue("https://acade.niu.edu.tw/NIU/Application/ENR/ENRG0/ENRG010_03.aspx", forHTTPHeaderField: "Referer")
            webView.load(request)
        }

        private func pollForSnapshot(webView: WKWebView, attempt: Int) {
            guard active else { return }
            guard attempt < 120 else {
                finish(.failure("畢業門檻資料載入逾時，請稍後再試"))
                return
            }

            let js = """
            (function() {
                function clean(text) {
                    return (text || '').replace(/\\s+/g, ' ').trim();
                }

                function pickStatus(mlValue) {
                    var span = document.querySelector('span[ml="' + mlValue + '"]');
                    if (!span) return '';
                    var tr = span.closest('tr');
                    if (!tr) return '';
                    var div = tr.querySelector('div');
                    return clean(div ? div.innerText : '');
                }

                var diverseText = '';
                var diverseEl = document.getElementById('div_B');
                if (diverseEl) {
                    diverseText = clean(diverseEl.innerText);
                }
                var nums = diverseText.match(/\\d+/g) || [];
                if (nums.length === 4) {
                    nums = [nums[0], '不計入', nums[1], '不計入', nums[2], '不計入', nums[3], '不計入'];
                }

                var required = '';
                var earned = '';
                var rows = document.querySelectorAll('tr.tdWhite');
                rows.forEach(function(r) {
                    if (r.cells[0] && clean(r.cells[0].innerText) === '畢業最低學分數') {
                        required = clean(r.cells[1] ? r.cells[1].innerText : '');
                        earned = clean(r.cells[2] ? r.cells[2].innerText : '');
                    }
                });

                var programs = '';
                var programEl = document.getElementById('CRS_PROG');
                if (programEl) {
                    programs = clean(programEl.innerText);
                }

                return JSON.stringify({
                    englishText: pickStatus('PL_外語能力'),
                    physicalText: pickStatus('PL_體適能'),
                    creditsRequiredText: required,
                    creditsEarnedText: earned,
                    diverseValues: nums,
                    programsText: programs
                });
            })()
            """

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
                guard let self, let webView, self.active else { return }
                webView.evaluateJavaScript(js) { [weak self] result, _ in
                    guard let self, self.active else { return }
                    guard let json = result as? String, let data = json.data(using: .utf8),
                          let dto = try? JSONDecoder().decode(GraduationRawDTO.self, from: data) else {
                        self.pollForSnapshot(webView: webView, attempt: attempt + 1)
                        return
                    }

                    let titles = ["服務", "多元", "專業", "綜合"]
                    var diverseItems: [DiverseRequirementItem] = []
                    for (index, title) in titles.enumerated() {
                        let pairStart = index * 2
                        guard dto.diverseValues.count > pairStart + 1 else { continue }
                        diverseItems.append(
                            DiverseRequirementItem(
                                id: title,
                                title: title,
                                currentText: dto.diverseValues[pairStart],
                                requiredText: dto.diverseValues[pairStart + 1]
                            )
                        )
                    }

                    if dto.englishText.trimmedOrDash == "-",
                       dto.physicalText.trimmedOrDash == "-",
                       diverseItems.isEmpty,
                       dto.creditsRequiredText.trimmedOrDash == "-" {
                        self.pollForSnapshot(webView: webView, attempt: attempt + 1)
                        return
                    }

                    let programs = dto.programsText
                        .split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "\n" })
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0 != "無" && $0 != "尚無資料" }

                    let snapshot = GraduationRequirementsSnapshot(
                        englishText: dto.englishText,
                        physicalText: dto.physicalText,
                        creditsRequiredText: dto.creditsRequiredText,
                        creditsEarnedText: dto.creditsEarnedText,
                        diverseItems: diverseItems,
                        programs: programs
                    )
                    self.finish(.success(snapshot))
                }
            }
        }

        func finish(_ result: GraduationWebResult) {
            guard active else { return }
            active = false
            onResult(result)
        }
    }
}

private struct FlexibleTagList: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chunked(tags, size: 2), id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chunked(_ source: [String], size: Int) -> [[String]] {
        guard size > 0 else { return [source] }
        var result: [[String]] = []
        var index = 0
        while index < source.count {
            let end = min(index + size, source.count)
            result.append(Array(source[index..<end]))
            index += size
        }
        return result
    }
}

private extension String {
    var trimmedOrDash: String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "-" : value
    }
}

private struct MoreFeaturesMenuView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    Text("更多功能即將推出")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.medium)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.large)
            }
        }
        .navigationTitle("更多功能")
        .navigationBarTitleDisplayMode(.inline)
    }
}
