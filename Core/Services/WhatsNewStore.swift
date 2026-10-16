import Foundation
import Combine

/// User-facing notes for one App Store version. Add a new entry at the top of
/// `ReleaseNotes.catalog` before releasing a version that should introduce itself.
struct ReleaseNotes: Identifiable, Equatable {
    struct Item: Identifiable, Equatable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    let version: String
    let items: [Item]
    var id: String { version }

    /// Newest first. Patch releases with nothing worth announcing need no entry.
    static let catalog: [ReleaseNotes] = [
        ReleaseNotes(version: "1.5.0", items: [
            Item(icon: "map.fill", title: "校園地圖全面更新",
                 detail: "新增 17 棟大樓的樓層平面圖，改用原生手勢縮放與拖曳，也不會再拖出地圖範圍。"),
            Item(icon: "fork.knife", title: "新增「午餐吃什麼」",
                 detail: "不知道吃什麼時，讓 App 幫你挑一間。"),
            Item(icon: "person.badge.key.fill", title: "校務登入自動續期",
                 detail: "登入逾時會自動續期；需要校方驗證時，完成後就會自動登入。"),
            Item(icon: "chart.bar.doc.horizontal.fill", title: "歷年成績更穩定",
                 detail: "沒有成績時顯示空狀態，網路錯誤也不會再要求重新登入。")
        ])
    ]
}

/// Decides whether to introduce the installed version once after an update.
/// Fresh installs are not prompted; only notes newer than the last seen version are shown.
@MainActor
final class WhatsNewStore: ObservableObject {
    static let shared = WhatsNewStore()
    static let lastSeenVersionKey = "app.whatsNew.lastSeenVersion"
    /// Keys written by versions released before this feature. Any of them means the app
    /// was used before, so a missing last-seen version is an update rather than a fresh install.
    static let legacyUsageKeys = [
        StorageKeys.loginTime,
        StorageKeys.authSessionID,
        AppUpdateChecker.lastCheckKey,
        AppUpdateChecker.failureDateKey
    ]

    /// Notes for every unseen version up to the installed one, newest first.
    @Published private(set) var pendingNotes: [ReleaseNotes] = []
    let currentVersion: String
    let catalog: [ReleaseNotes]
    private let defaults: UserDefaults

    private convenience init() {
        self.init(
            defaults: .standard,
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            catalog: ReleaseNotes.catalog
        )
    }

    /// Evaluates immediately so the decision reads launch-time state, before other
    /// launch work (such as the daily update check) writes to the same defaults.
    init(defaults: UserDefaults, currentVersion: String, catalog: [ReleaseNotes]) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.catalog = catalog
        pendingNotes = Self.unseenNotes(defaults: defaults, currentVersion: currentVersion, catalog: catalog)
        // Fresh installs and versions without notes are recorded right away, so a later
        // update compares against this version instead of an older one.
        if pendingNotes.isEmpty { recordCurrentVersion() }
    }

    /// Notes for the installed version, for re-reading from Settings.
    var currentNotes: ReleaseNotes? {
        catalog.first { $0.version == currentVersion }
    }

    func markSeen() {
        pendingNotes = []
        recordCurrentVersion()
    }

    private func recordCurrentVersion() {
        let lastSeen = defaults.string(forKey: Self.lastSeenVersionKey)
        // Never move a valid record backwards, e.g. after installing an older TestFlight build.
        guard lastSeen.map({
            AppUpdateChecker.isNewer(currentVersion, than: $0) || !AppUpdateChecker.isNewer($0, than: "0")
        }) ?? true,
              AppUpdateChecker.isNewer(currentVersion, than: "0") else { return }
        defaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
    }

    private static func unseenNotes(defaults: UserDefaults, currentVersion: String,
                                    catalog: [ReleaseNotes]) -> [ReleaseNotes] {
        guard AppUpdateChecker.isNewer(currentVersion, than: "0") else { return [] }
        let lastSeen: String
        if let stored = defaults.string(forKey: lastSeenVersionKey) {
            lastSeen = stored
        } else if legacyUsageKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            // Updated from a version that predates this record: introduce the installed version only.
            return catalog.filter { $0.version == currentVersion }
        } else {
            // Fresh install: nothing to introduce.
            return []
        }
        guard AppUpdateChecker.isNewer(currentVersion, than: lastSeen) else { return [] }
        return catalog
            .filter {
                AppUpdateChecker.isNewer($0.version, than: lastSeen)
                    && !AppUpdateChecker.isNewer($0.version, than: currentVersion)
            }
            .sorted { AppUpdateChecker.isNewer($0.version, than: $1.version) }
    }
}
