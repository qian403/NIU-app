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
