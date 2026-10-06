import Foundation
import WidgetKit
import Combine

/// Device-local custom courses, kept per account. Nothing here contacts the school.
@MainActor
final class CustomCourseStore: ObservableObject {
    static let shared = CustomCourseStore()

    /// Outside the "classSchedule." prefix so logout keeps each account's own courses;
    /// only the App Group mirror (`CustomCourseSnapshot.key`) is cleared with personal caches.
    private let storageKey = "customCourses.byAccount.v1"
    private let appGroupIdentifier = "group.dev.chien.niuapp"

    @Published private(set) var courses: [CustomCourse] = []
    private var account: String?
    private let defaults: UserDefaults
    private let isFixture: Bool

    private init() {
        defaults = .standard
        isFixture = false
        reload()
    }

    #if DEBUG
    /// Isolated store for UI fixtures; never reads account data or writes the App Group.
    init(fixtureDefaults: UserDefaults) {
        defaults = fixtureDefaults
        isFixture = true
        reload()
    }
    #endif

    private var currentAccount: String? {
        isFixture ? "fixture" : UserDefaults.standard.string(forKey: StorageKeys.username)
    }

    /// Re-reads the signed-in account's courses, e.g. after switching accounts.
    func reload() {
        account = currentAccount
        let stored = account.flatMap { loadAll()[$0] } ?? []
        if stored != courses { courses = stored }
    }

    func save(_ course: CustomCourse) {
        reloadIfAccountChanged()
        var list = courses
        if let index = list.firstIndex(where: { $0.id == course.id }) {
            list[index] = course
        } else {
            list.append(course)
        }
        persist(list)
    }

    func delete(id: UUID) {
        reloadIfAccountChanged()
        persist(courses.filter { $0.id != id })
    }

    /// Mirrors the current session's courses for Widget and Live Activity readers.
    func syncShared() {
        reloadIfAccountChanged()
        guard !isFixture,
              let shared = UserDefaults(suiteName: appGroupIdentifier),
              account != nil,
              let sessionID = UserDefaults.standard.string(forKey: StorageKeys.authSessionID),
              !UserDefaults.standard.bool(forKey: "app.logoutCleanupPending"),
              let data = try? JSONEncoder().encode(CustomCourseSnapshot(ownerSessionID: sessionID, courses: courses))
        else { return }
        guard shared.data(forKey: CustomCourseSnapshot.key) != data else { return }
        shared.set(data, forKey: CustomCourseSnapshot.key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Persistence

    private func reloadIfAccountChanged() {
        if account != currentAccount { reload() }
    }

    private func loadAll() -> [String: [CustomCourse]] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: [CustomCourse]].self, from: data) else { return [:] }
        return decoded
    }

    private func persist(_ list: [CustomCourse]) {
        guard let account else { return }
        var all = loadAll()
        all[account] = list.isEmpty ? nil : list
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: storageKey)
        courses = list
        guard !isFixture else { return }
        syncShared()
        // Home, reminders and the Live Activity already re-read the schedule on this signal.
        NotificationCenter.default.post(name: .classScheduleDidUpdate, object: nil)
    }
}
