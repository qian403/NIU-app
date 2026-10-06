import SwiftUI

/// Opens the custom course editor for a new course (optionally on a weekday) or an existing one.
struct CustomCourseEditorRequest: Identifiable {
    let id = UUID()
    var course: CustomCourse?
    var weekday: Int?
}

struct CustomCourseEditorView: View {
    let schedule: ClassSchedule
    @ObservedObject var store: CustomCourseStore
    private let original: CustomCourse?
    private let courseID: UUID
    private let today: Date

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var classroom: String
    @State private var note: String
    @State private var weekdays: Set<Int>
    @State private var startRow: Int
    @State private var endRow: Int
    @State private var lastDay: Date
    @State private var showDeleteConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, classroom }

    init(schedule: ClassSchedule, store: CustomCourseStore, request: CustomCourseEditorRequest, today: Date) {
        self.schedule = schedule
        self.store = store
        self.today = today
        original = request.course
        courseID = request.course?.id ?? UUID()
        let course = request.course
        let rows = course?.periodRange(in: schedule.periods)
        _name = State(initialValue: course?.name ?? "")
        _classroom = State(initialValue: course?.classroom ?? "")
        _note = State(initialValue: course?.note ?? "")
        _weekdays = State(initialValue: Set(course?.weekdays ?? request.weekday.map { [$0] } ?? []))
        // New courses start at the first morning period rather than an early "0" period.
        let firstRow = schedule.periods.firstIndex { ($0.startMinutes ?? 0) >= 8 * 60 } ?? 0
        _startRow = State(initialValue: rows?.lowerBound ?? firstRow)
        _endRow = State(initialValue: rows?.upperBound ?? firstRow)
        _lastDay = State(initialValue: course.flatMap { CustomCourse.date(fromDay: $0.lastDay) }
                         ?? Self.defaultLastDay(from: today))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var draft: CustomCourse? {
        guard schedule.periods.indices.contains(startRow), schedule.periods.indices.contains(endRow) else { return nil }
        return CustomCourse(
            id: courseID,
            name: trimmedName,
            classroom: classroom.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            weekdays: weekdays.sorted(),
            startPeriodID: schedule.periods[startRow].id,
            endPeriodID: schedule.periods[max(startRow, endRow)].id,
            lastDay: CustomCourse.dayString(lastDay)
        )
    }

    private var conflict: String? {
        guard let draft, !weekdays.isEmpty else { return nil }
        return schedule.conflictMessage(for: draft, others: store.courses, today: today)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !weekdays.isEmpty && draft != nil && conflict == nil
    }

    private var isExpired: Bool {
        CustomCourse.dayString(lastDay) < CustomCourse.dayString(today)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("課程名稱", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .classroom }
                    TextField("地點（選填）", text: $classroom)
                        .focused($focusedField, equals: .classroom)
                    TextField("教師或備註（選填）", text: $note)
                }

                Section {
                    weekdayPicker
                    if schedule.periods.isEmpty {
                        Text("課表沒有節次資料，請先更新課表")
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                    } else {
                        Picker("開始節次", selection: $startRow) {
                            ForEach(schedule.periods.indices, id: \.self) { row in
                                Text(periodLabel(row)).tag(row)
                            }
                        }
                        Picker("結束節次", selection: $endRow) {
                            ForEach(schedule.periods.indices.filter { $0 >= startRow }, id: \.self) { row in
                                Text(periodLabel(row)).tag(row)
                            }
                        }
                    }
                } header: {
                    Text("上課時間")
                } footer: {
                    if let conflict {
                        Label("\(conflict)，請改選其他時段", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.error)
                    } else if weekdays.isEmpty {
                        Text("請至少選擇一天")
                    } else {
                        Text("\(CustomCourse.weekdaySummary(weekdays))・\(timeRangeLabel)")
                    }
                }

                Section {
                    DatePicker("到期日", selection: $lastDay, displayedComponents: .date)
                        .environment(\.calendar, ScheduleClock.calendar)
                        .environment(\.timeZone, ScheduleClock.calendar.timeZone)
                        .environment(\.locale, Locale(identifier: "zh_TW"))
                } header: {
                    Text("期限")
                } footer: {
                    if isExpired {
                        Label("這個日期已經過了，課程不會顯示在課表上", systemImage: "clock.badge.xmark")
                    } else {
                        Text("到期日當天仍會顯示，之後就不會再出現在課表上。")
                    }
                }

                if original != nil {
                    Section {
                        Button("刪除課程", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(original == nil ? "新增課程" : "編輯課程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        guard canSave, let draft else { return }
                        store.save(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .confirmationDialog("要刪除「\(original?.name ?? "")」嗎？", isPresented: $showDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("刪除課程", role: .destructive) {
                    if let original { store.delete(id: original.id) }
                    dismiss()
                }
            }
            .onChange(of: startRow) { _, newValue in
                if endRow < newValue { endRow = newValue }
            }
            .onAppear {
                if original == nil { focusedField = .name }
            }
        }
    }

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            Text("星期")
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { weekday in
                    let isSelected = weekdays.contains(weekday)
                    Button {
                        if isSelected { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                    } label: {
                        Text(CustomCourse.shortWeekdayLabels[weekday])
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(isSelected ? Color.white : Theme.Colors.label)
                            .frame(width: 38, height: 38)
                            .background(isSelected ? Theme.Colors.accent : Theme.Colors.tertiaryFill, in: Circle())
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(CustomCourse.weekdayHeaders[weekday])
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func periodLabel(_ row: Int) -> String {
        let period = schedule.periods[row]
        let time = period.startTimeLabel.isEmpty ? "" : "  \(period.startTimeLabel)–\(period.endTimeLabel)"
        return period.displayPeriodLabel + time
    }

    private var timeRangeLabel: String {
        guard schedule.periods.indices.contains(startRow), schedule.periods.indices.contains(endRow) else { return "" }
        return CustomCourse.periodSummary(schedule.periods[startRow...max(startRow, endRow)])
    }

    /// NIU semesters end in January and June; this is only a starting point the user can change.
    private static func defaultLastDay(from date: Date) -> Date {
        let calendar = ScheduleClock.calendar
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 2026, month = parts.month ?? 1
        let end = month >= 8 ? DateComponents(year: year + 1, month: 1, day: 31)
            : month == 1 ? DateComponents(year: year, month: 1, day: 31)
            : DateComponents(year: year, month: 6, day: 30)
        return calendar.date(from: end) ?? date
    }
}
