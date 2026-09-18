import Foundation
import Combine
import WidgetKit

@MainActor
final class AcademicCalendarViewModel: ObservableObject {
    @Published private(set) var currentSemester: String
    @Published private(set) var availableYears: [Int]
    @Published private(set) var currentCalendar: SemesterCalendar?
    @Published var selectedMonth: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var sourceLabel = ""
    @Published private(set) var statusMessage: String?
    @Published private(set) var isNotPublished = false
    private let store: AcademicCalendarStore
    private var requestID = UUID()
    private var observedYear: Int
    private var observedMonth: Int
    private var followsCurrentYear = true

    init(store: AcademicCalendarStore = .shared, now: Date = Date()) {
        self.store = store
        observedYear = CampusCalendarDate.academicYear(at: now)
        observedMonth = CampusCalendarDate.calendar.component(.month, from: now)
        currentSemester = String(observedYear)
        availableYears = [observedYear]
        selectedMonth = observedMonth
    }

    var displayTitle: String { "\(currentSemester) 學年度行事曆" }
    var displayPeriodLabel: String { "\(currentSemester) 學年度" }
    var allEvents: [CalendarEvent] { currentCalendar?.events ?? [] }
    var todayEvents: [CalendarEvent] { allEvents.filter { $0.contains(Date()) } }

    func selectMonth(_ month: Int) { selectedMonth = month }

    func switchSemester(to value: String) {
        guard let year = Int(value), year != Int(currentSemester) else { return }
        requestID = UUID()
        currentSemester = value
        followsCurrentYear = year == observedYear
        selectedMonth = followsCurrentYear ? observedMonth : nil
        currentCalendar = nil
        sourceLabel = ""
        statusMessage = nil
        isNotPublished = false
    }

    /// Returns whether the selected year changed; the view's task(id:) then loads it.
    @discardableResult
    func handleDateChange(now: Date = Date()) -> Bool {
        let year = CampusCalendarDate.academicYear(at: now)
        let month = CampusCalendarDate.calendar.component(.month, from: now)
        if followsCurrentYear && selectedMonth == observedMonth { selectedMonth = month }
        let changed = followsCurrentYear && year != observedYear
        observedYear = year
        observedMonth = month
        availableYears = Array(Set(availableYears + [year])).sorted(by: >)
        if changed {
            switchSemester(to: String(year))
            followsCurrentYear = true
        }
        return changed
    }

    func reload(force: Bool = false, now: Date = Date()) async {
        guard let year = Int(currentSemester) else { return }
        let id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        let cached = await store.cached(year: year)
        guard !Task.isCancelled, requestID == id else { return }
        apply(cached)
        let fresh = await store.refresh(year: year, now: now, force: force)
        guard !Task.isCancelled, requestID == id else { return }
        apply(fresh)
        WidgetCenter.shared.reloadTimelines(ofKind: "NIU_CompactWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "NIU_LiveActivities")
    }

    private func apply(_ result: CampusCalendarResult) {
        availableYears = Array(Set(result.availableYears + [observedYear])).sorted(by: >)
        currentCalendar = result.document.map { document in
            SemesterCalendar(semester: String(document.academicYear), academicYear: String(document.academicYear),
                             semesterNumber: 0, title: "\(document.academicYear) 學年度行事曆",
                             events: document.events.map { CalendarEvent($0, document: document) }
                                .sorted { ($0.startDate, $0.id) < ($1.startDate, $1.id) })
        }
        sourceLabel = result.document == nil ? "" : result.statusText
        if result.notice != nil, let checked = result.checkedAt {
            sourceLabel += " · 上次同步 \(CampusCalendarDate.format(checked, "M/d HH:mm"))"
        }
        statusMessage = result.notice
        isNotPublished = result.isNotPublished
    }
}
