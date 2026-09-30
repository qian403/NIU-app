import Foundation

struct ClassWatchActivityPresentation {
    let state: ClassLiveActivityAttributes.ContentState
    let isStale: Bool

    var needsRefresh: Bool {
        isStale || !["current", "upcoming"].contains(state.mode) || state.endDate <= state.startDate
    }

    var statusLabel: String {
        if needsRefresh { return "課表待更新" }
        return state.mode == "current" ? "上課中" : "下一堂課"
    }

    var statusSymbol: String {
        if needsRefresh { return "arrow.clockwise" }
        return state.mode == "current" ? "play.fill" : "clock.fill"
    }

    var courseName: String { nonempty(state.courseName) ?? "課程名稱未提供" }
    var classroom: String { nonempty(state.classroom) ?? "教室未提供" }
    var periodLabel: String? { nonempty(state.periodLabel) }

    var countdownLabel: String {
        state.mode == "current" ? "下課" : "上課"
    }

    var countdownEnd: Date? {
        guard !needsRefresh else { return nil }
        return state.mode == "current" ? state.endDate : state.startDate
    }

    var progressInterval: ClosedRange<Date>? {
        guard !needsRefresh else { return nil }
        return state.startDate...state.endDate
    }

    private func nonempty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
