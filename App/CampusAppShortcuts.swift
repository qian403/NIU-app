import AppIntents
import WidgetKit

struct StartClassLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "啟動課表即時動態" }
    static var description: IntentDescription {
        "在背景啟用課表即時動態，依儲存課表啟動或更新鎖定畫面與靈動島。"
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await CampusShortcutService.refreshActivity(startIfNeeded: true)
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct RefreshClassLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "更新課表即時動態" }
    static var description: IntentDescription {
        "在背景依儲存課表更新鎖定畫面與靈動島；已啟用功能且動態已結束時，會重新啟動。"
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await CampusShortcutService.refreshActivity(startIfNeeded: false)
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct StopClassLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "關閉課表即時動態" }
    static var description: IntentDescription { "結束課表即時動態並停用自動更新，直到再次啟用。" }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await CampusShortcutService.stopActivity()
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct GetTodayClassScheduleIntent: AppIntent {
    static var title: LocalizedStringResource { "取得今天的課表" }
    static var description: IntentDescription { "以文字傳回目前帳號儲存的今日課表，包含時間與教室，可接續朗讀或顯示通知。" }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await CampusShortcutService.todaySchedule()
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct GetNextClassIntent: AppIntent {
    static var title: LocalizedStringResource { "取得下一堂課" }
    static var description: IntentDescription { "傳回未來 7 天儲存課表中，下一堂尚未開始的課程、時間與教室。" }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await CampusShortcutService.nextClass()
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct ReloadCampusWidgetsIntent: AppIntent {
    static var title: LocalizedStringResource { "重新整理校園小工具" }
    static var description: IntentDescription { "請求 iOS 依已儲存的課表與行事曆重新整理 NIU-Life 小工具，實際更新時機由系統安排。" }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try Task.checkCancellation()
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "已請求重新整理小工具，實際更新時機由 iOS 安排。")
    }
}

enum CampusShortcutDestination: String, AppEnum {
    case classSchedule, academicCalendar, attendance, library, mail, moodle

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "校園功能" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.classSchedule: "課表", .academicCalendar: "行事曆", .attendance: "快速點名",
         .library: "圖書館 QR Code", .mail: "校園信箱", .moodle: "M 園區"]
    }

    var destination: CampusDestination {
        switch self {
        case .classSchedule: .classSchedule
        case .academicCalendar: .academicCalendar
        case .attendance: .attendance
        case .library: .library
        case .mail: .mail
        case .moodle: .moodle
        }
    }
}

struct OpenCampusShortcutIntent: AppIntent {
    static var title: LocalizedStringResource { "開啟校園頁面" }
    static var description: IntentDescription { "開啟指定校園功能；若尚未登入，完成登入後繼續前往。" }
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "頁面", default: .classSchedule)
    var destination: CampusShortcutDestination

    static var parameterSummary: some ParameterSummary { Summary("開啟 \(\.$destination)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        CampusRouter.shared.open(destination.destination)
        return .result()
    }
}

struct CampusAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartClassLiveActivityIntent(),
                    phrases: ["啟動 \(.applicationName) 課表即時動態"],
                    shortTitle: "啟動課表即時動態", systemImageName: "rectangle.topthird.inset.filled")
        AppShortcut(intent: RefreshClassLiveActivityIntent(),
                    phrases: ["更新 \(.applicationName) 靈動島", "更新 \(.applicationName) 課表即時動態"],
                    shortTitle: "更新課表即時動態", systemImageName: "arrow.clockwise")
        AppShortcut(intent: StopClassLiveActivityIntent(),
                    phrases: ["關閉 \(.applicationName) 課表即時動態"],
                    shortTitle: "關閉課表即時動態", systemImageName: "stop.circle")
        AppShortcut(intent: GetTodayClassScheduleIntent(),
                    phrases: ["查詢 \(.applicationName) 今天的課表"],
                    shortTitle: "今天的課表", systemImageName: "calendar")
        AppShortcut(intent: GetNextClassIntent(),
                    phrases: ["查詢 \(.applicationName) 下一堂課"],
                    shortTitle: "下一堂課", systemImageName: "clock")
        AppShortcut(intent: ReloadCampusWidgetsIntent(),
                    phrases: ["重新整理 \(.applicationName) 小工具"],
                    shortTitle: "重新整理小工具", systemImageName: "square.grid.2x2")
        AppShortcut(intent: OpenCampusShortcutIntent(),
                    phrases: ["開啟 \(.applicationName) \(\.$destination)"],
                    shortTitle: "開啟校園頁面", systemImageName: "arrow.up.forward.app")
    }
}
