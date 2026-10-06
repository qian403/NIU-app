import SwiftUI

// MARK: - Settings

struct ClassScheduleSettingsView: View {
    /// School data only; custom courses are checked against it, never merged into it.
    let schedule: ClassSchedule
    @ObservedObject var store: CustomCourseStore
    /// Reference "today" from the view model, so fixtures and production share one clock.
    let today: Date

    @Environment(\.dismiss) private var dismiss
    @State private var editorRequest: CustomCourseEditorRequest?
    @State private var showExportSheet = false
    @State private var showWallpaperSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.courses.isEmpty {
                        Text("尚未新增自訂課程")
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                    }
                    ForEach(sortedCourses) { course in
                        Button {
                            editorRequest = CustomCourseEditorRequest(course: course)
                        } label: {
                            CustomCourseRow(course: course, status: status(of: course), periods: schedule.periods)
                        }
                        .accessibilityHint("編輯課程")
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { sortedCourses[$0].id }
                        ids.forEach(store.delete)
                    }

                    Button {
                        editorRequest = CustomCourseEditorRequest()
                    } label: {
                        Label("新增課程", systemImage: "plus.circle.fill")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                } header: {
                    Text("自訂課程")
                } footer: {
                    Text("自訂課程只存在這支手機，不會傳送到學校系統。過了到期日就不會再顯示在課表上。")
                }

                Section {
                    Button {
                        showWallpaperSheet = true
                    } label: {
                        Label("製作課表桌布", systemImage: "photo.artframe")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                } header: {
                    Text("桌布")
                } footer: {
                    Text("選一張照片，自動把整週課表放在鎖定畫面時間下方，儲存成桌布。")
                }

                Section {
                    Button {
                        showExportSheet = true
                    } label: {
                        Label("匯出課表至行事曆", systemImage: "calendar.badge.plus")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                } header: {
                    Text("行事曆")
                } footer: {
                    Text("將學校課表匯出成 iOS 行事曆中每週重複的事件，不包含自訂課程。")
                }
            }
            .navigationTitle("課表設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editorRequest) { request in
                CustomCourseEditorView(schedule: schedule, store: store, request: request, today: today)
            }
            .sheet(isPresented: $showWallpaperSheet) {
                ClassScheduleWallpaperView(schedule: schedule, customCourses: store.courses, today: today)
            }
            .sheet(isPresented: $showExportSheet) {
                ClassScheduleExportView(schedule: schedule, isPresented: $showExportSheet)
            }
        }
    }

    /// Visible courses first, by weekday and period; expired ones last.
    private var sortedCourses: [CustomCourse] {
        let todayString = CustomCourse.dayString(today)
        return store.courses.sorted { lhs, rhs in
            let lhsExpired = lhs.lastDay < todayString, rhsExpired = rhs.lastDay < todayString
            if lhsExpired != rhsExpired { return !lhsExpired }
            let lhsKey = (lhs.weekdays.min() ?? 7, lhs.periodRange(in: schedule.periods)?.lowerBound ?? Int.max)
            let rhsKey = (rhs.weekdays.min() ?? 7, rhs.periodRange(in: schedule.periods)?.lowerBound ?? Int.max)
            return lhsKey != rhsKey ? lhsKey < rhsKey : lhs.name < rhs.name
        }
    }

    private func status(of course: CustomCourse) -> CustomCourseRow.Status {
        if !course.isActive(on: today) { return .expired }
        if course.periodRange(in: schedule.periods) == nil { return .missingPeriod }
        if schedule.conflictMessage(for: course, others: [], today: today) != nil { return .conflict }
        return .active
    }
}

// MARK: - Row

private struct CustomCourseRow: View {
    enum Status { case active, expired, conflict, missingPeriod }

    let course: CustomCourse
    let status: Status
    let periods: [ClassPeriod]

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(status == .expired ? Theme.Colors.secondaryLabel : Theme.Colors.label)
                Text(course.scheduleSummary(in: periods))
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                statusLabel
                    .font(.footnote)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .active:
            Text("顯示至 \(course.lastDayLabel)")
                .foregroundStyle(Theme.Colors.secondaryLabel)
        case .expired:
            Label("已於 \(course.lastDayLabel) 到期", systemImage: "clock.badge.xmark")
                .foregroundStyle(Theme.Colors.secondaryLabel)
        case .conflict:
            Label("與學校課程時段衝突，暫不顯示", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warning)
        case .missingPeriod:
            Label("課表已沒有所選節次，請重新設定", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warning)
        }
    }
}
