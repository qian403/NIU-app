#if DEBUG
import SwiftUI

/// Synthetic schedule and isolated preference suite; never loads school/Keychain data.
enum ClassScheduleUIFixture {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("-NIUClassScheduleUIFixture")
    }

    static var mode: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-NIUClassScheduleUIFixtureMode"),
              args.indices.contains(index + 1), ["week", "day"].contains(args[index + 1]) else { return "week" }
        return args[index + 1]
    }

    static var scenario: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-NIUClassScheduleUIFixtureScenario"),
              args.indices.contains(index + 1) else { return "weekday" }
        return args[index + 1]
    }

    static var now: Date {
        Date(timeIntervalSince1970: 1_791_160_500) // Taipei 2026-10-05 08:35.
    }

    static var schedule: ClassSchedule {
        let names = ["資料結構", "行動應用程式設計", "資料庫系統", "資訊安全導論", "跨領域人工智慧專題", "週末實作", "專題討論"]
        let dayCount = ["weekend", "dense"].contains(scenario) ? 7 : 5
        let periodCount = scenario == "dense" ? 16 : 10
        let periods = (0..<periodCount).map { row in
            var courses: [Int: CourseInfo] = [:]
            for column in 0..<dayCount where scenario != "empty" {
                let rows = column >= 5 ? 2..<4 : (column % 3 + 1)..<(column % 3 + 4)
                if rows.contains(row) || (column == 0 && row == 7) ||
                    (scenario == "dense" && row >= 8 && (row + column) % 3 == 0) {
                    courses[column] = CourseInfo(name: names[column], teacher: "測試教師\(column + 1)", classroom: "教\(column + 1)01")
                }
            }
            let hour = row + 7
            return ClassPeriod(id: "\(row)", timeRange: String(format: "%02d:10~%02d:00", hour, hour + 1), courses: courses)
        }
        return ClassSchedule(periods: periods, dayCount: dayCount,
                             dayHeaders: Array(["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"].prefix(dayCount)),
                             fetchedAt: now.addingTimeInterval(-300))
    }
}

/// In-memory classmates for the exchange screens; never reads the Keychain or Application Support.
final class ScheduleExchangeFixtureBackend: ScheduleExchangeBackend, @unchecked Sendable {
    private var entry = ScheduleExchangeAccountEntry(storageID: UUID(), preferences: ScheduleSharePreferences(customNickname: "小安"))
    private var list: [ExchangedSchedule]

    init() {
        let term = ScheduleShareTerm(containing: Date())
        func friend(_ name: String, busy: [(Int, ClosedRange<Int>)], days: [Int] = [0, 1, 2, 3, 4], term: ScheduleShareTerm = term) -> ExchangedSchedule {
            let periods = (1...10).map { ScheduleSharePayload.Period(id: "\($0)", start: ($0 + 7) * 60 + 10, end: ($0 + 8) * 60) }
            let slots = busy.flatMap { day, rows in rows.map { ScheduleSharePayload.Slot(day: day, period: $0, name: day % 2, room: nil, teacher: nil) } }
            let payload = ScheduleSharePayload(shareID: UUID(), term: term, createdAt: Date(), nickname: name, days: days, periods: periods,
                                               names: ["計算機概論", "線性代數"], rooms: [], teachers: [], slots: slots)
            return ExchangedSchedule(id: UUID(), payload: payload, importedAt: Date())
        }
        let ended = ScheduleShareTerm(containing: Date().addingTimeInterval(-200 * 24 * 60 * 60))
        list = ScheduleExchangeSamples.classmates(term: term, periods: [])
            .map { ExchangedSchedule(id: UUID(), payload: $0, importedAt: Date()) }
            + [friend("學長", busy: [(0, 3...4)], term: ended)]
    }

    func accountEntry(for account: String) throws -> ScheduleExchangeAccountEntry { entry }
    func savePreferences(_ preferences: ScheduleSharePreferences, for account: String) throws { entry.preferences = preferences }
    func load(storageID: UUID) throws -> [ExchangedSchedule] { list }
    func save(_ list: [ExchangedSchedule], storageID: UUID) throws { self.list = list }
    func removeAccount(_ account: String) throws { list = [] }
}

/// Synthetic classmates for looking at the exchange screens; names and courses are made up.
enum ScheduleExchangeSamples {
    private static let idPrefix = "5A3E0000-0000-4000-8000-"

    private typealias Class = (day: Int, rows: ClosedRange<Int>, name: String, room: String?, teacher: String?)
    private static let people: [(name: String, days: [Int], classes: [Class])] = [
        ("阿哲", [0, 1, 2, 3, 4], [(0, 0...1, "計算機概論", "格致大樓 E201", "王老師"),
                                   (2, 4...6, "資料結構", "格致大樓 E305", "林老師"),
                                   (4, 2...3, "線性代數", nil, nil)]),
        ("小芸", [0, 1, 2, 3], [(1, 0...2, "會計學", "綜合教學大樓 B101", nil),
                               (3, 5...7, "經濟學", nil, nil),
                               (0, 6...7, "英文（二）", nil, nil)]),
        ("Kevin", [0, 1, 2, 3, 4], [(0, 2...3, "微積分", nil, "陳老師"),
                                    (1, 5...6, "普通物理", nil, "張老師"),
                                    (3, 0...1, "程式設計", nil, nil),
                                    (4, 6...8, "體育", "體育館", nil)]),
        ("學姊 Amy", [0, 1, 2, 3, 4, 5], [(2, 0...2, "專題研究", "實驗室 R402", nil),
                                         (5, 1...3, "週末實習", nil, nil),
                                         (4, 0...1, "日文（一）", nil, nil)]),
        ("阿凱", [0, 1, 2, 3, 4], [(0, 4...4, "通識：電影賞析", nil, nil),
                                   (1, 1...2, "統計學", nil, nil),
                                   (3, 3...4, "行銷管理", nil, nil),
                                   (4, 4...5, "服務學習", nil, nil)]),
    ]

    static func isSample(_ payload: ScheduleSharePayload) -> Bool {
        payload.shareID.uuidString.hasPrefix(idPrefix)
    }

    /// Uses `periods` (normally the user's own table) so the samples line up with real period times.
    static func classmates(term: ScheduleShareTerm, periods: [ScheduleSharePayload.Period],
                           now: Date = Date()) -> [ScheduleSharePayload] {
        let periods = periods.isEmpty
            ? (1...10).map { ScheduleSharePayload.Period(id: "\($0)", start: ($0 + 7) * 60 + 10, end: ($0 + 8) * 60) }
            : periods
        func position(of value: String, in list: inout [String]) -> Int {
            if let index = list.firstIndex(of: value) { return index }
            list.append(value)
            return list.count - 1
        }
        return people.enumerated().map { offset, person in
            var names: [String] = [], rooms: [String] = [], teachers: [String] = []
            var slots: [ScheduleSharePayload.Slot] = []
            for item in person.classes {
                for row in item.rows where periods.indices.contains(row) {
                    slots.append(ScheduleSharePayload.Slot(
                        day: item.day, period: row, name: position(of: item.name, in: &names),
                        room: item.room.map { position(of: $0, in: &rooms) },
                        teacher: item.teacher.map { position(of: $0, in: &teachers) }))
                }
            }
            let id = UUID(uuidString: idPrefix + String(format: "%012d", offset + 1)) ?? UUID()
            return ScheduleSharePayload(shareID: id, term: term, createdAt: now, nickname: person.name,
                                        days: person.days, periods: periods, names: names, rooms: rooms,
                                        teachers: teachers, slots: slots)
        }
    }
}

extension ClassScheduleUIFixture {
    @MainActor static let exchangeStore = ScheduleExchangeStore(backend: ScheduleExchangeFixtureBackend(), account: "fixture")
}

struct ClassScheduleUIFixtureRoot: View {
    // Initialize once per launch; rebuilding the root must not reset a user's test selection.
    private static let defaults: UserDefaults = {
        let suite = "dev.niu.class-schedule-ui-fixture"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Fixture defaults unavailable")
        }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(ClassScheduleUIFixture.mode, forKey: "classSchedule.displayMode")
        return defaults
    }()

    var body: some View {
        NavigationStack {
            ClassScheduleView(fixtureSchedule: ClassScheduleUIFixture.schedule, defaults: Self.defaults)
        }
    }
}
#endif
