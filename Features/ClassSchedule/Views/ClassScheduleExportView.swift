import SwiftUI
import EventKit

struct ClassScheduleExportView: View {

    let schedule: ClassSchedule
    @Binding var isPresented: Bool

    @State private var semesterStart: Date = defaultSemesterStart()
    @State private var weekCount: Int = 18
    @State private var calendarName: String = "課表"
    @State private var createSeparateCalendar: Bool = true

    @State private var isExporting = false
    @State private var resultMessage: String?
    @State private var resultIsError = false
    @State private var showResult = false

    private let exportService = ClassScheduleExportService()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // Header description
                        Text("將課表匯出為每週重複的行事曆事件，方便在 iOS 行事曆中查看。")
                            .font(.system(size: 14, weight: .light))
                            .foregroundColor(.black.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)

                        // Semester start date
                        fieldSection(title: "學期開始日期") {
                            DatePicker(
                                "",
                                selection: $semesterStart,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                            .environment(\.locale, Locale(identifier: "zh_TW"))
                            .labelsHidden()
                        }

                        // Week count
                        fieldSection(title: "學期週數") {
                            HStack {
                                Text("\(weekCount) 週")
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Spacer()
                                Stepper("", value: $weekCount, in: 1...30)
                                    .labelsHidden()
                            }
                        }

                        // Calendar name
                        fieldSection(title: "行事曆") {
                            VStack(spacing: 10) {
                                Toggle(isOn: $createSeparateCalendar) {
                                    Text("建立獨立行事曆")
                                        .font(.system(size: 15))
                                        .foregroundColor(.primary)
                                }

                                if createSeparateCalendar {
                                    TextField("課表", text: $calendarName)
                                        .font(.system(size: 15))
                                        .textFieldStyle(.plain)
                                        .autocorrectionDisabled()
                                } else {
                                    Text("將匯出到目前的預設行事曆")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        // Preview info
                        previewInfo

                        // Export button
                        exportButton
                    }
                    .padding(Theme.Spacing.large)
                }
            }
            .navigationTitle("匯出至行事曆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { isPresented = false }
                        .foregroundColor(.primary)
                }
            }
            .alert(isPresented: $showResult) {
                Alert(
                    title: Text(resultIsError ? "匯出失敗" : "匯出成功"),
                    message: Text(resultMessage ?? ""),
                    dismissButton: .default(Text("確定")) {
                        if !resultIsError { isPresented = false }
                    }
                )
            }
        }
    }

    // MARK: - Field section

    private func fieldSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.black.opacity(0.5))

            content()
                .padding(Theme.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
    }

    // MARK: - Preview info

    private var previewInfo: some View {
        let totalCourses = countTotalCourseBlocks()
        return VStack(alignment: .leading, spacing: 8) {
            Text("預覽")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.black.opacity(0.5))

            HStack(spacing: 20) {
                infoChip(icon: "calendar.badge.clock",
                         text: "\(weekCount) 週")
                infoChip(icon: "book.closed",
                         text: "\(totalCourses) 門課")
                infoChip(icon: "arrow.clockwise",
                         text: "每週重複")
            }
        }
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.black.opacity(0.5))
            Text(text)
                .font(.system(size: 13, weight: .light))
                .foregroundColor(.black.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func countTotalCourseBlocks() -> Int {
        (0..<schedule.dayCount).reduce(0) { total, dayIndex in
            total + exportService.courseBlocks(for: dayIndex, in: schedule).count
        }
    }

    // MARK: - Export button

    private var exportButton: some View {
        Button {
            Task { await performExport() }
        } label: {
            HStack {
                if isExporting {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 16))
                }
                Text(isExporting ? "正在匯出…" : "匯出至行事曆")
                    .font(.system(size: 16, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(Theme.CornerRadius.medium)
        }
        .disabled(
            isExporting ||
            (createSeparateCalendar && calendarName.trimmingCharacters(in: .whitespaces).isEmpty)
        )
    }

    // MARK: - Export action

    private func performExport() async {
        isExporting = true
        let name = calendarName.trimmingCharacters(in: .whitespaces).isEmpty ? "課表" : calendarName
        let result = await exportService.export(
            schedule: schedule,
            semesterStart: semesterStart,
            weekCount: weekCount,
            calendarName: name,
            createSeparateCalendar: createSeparateCalendar
        )
        isExporting = false

        switch result {
        case .success(let count):
            resultMessage = "已成功建立 \(count) 個課程事件，將在 \(weekCount) 週內每週重複。"
            resultIsError = false
        case .permissionDenied:
            resultMessage = "未取得行事曆存取權限，請至「設定 → 隱私與安全性 → 行事曆」開啟存取權限。"
            resultIsError = true
        case .failure(let msg):
            resultMessage = "匯出失敗：\(msg)"
            resultIsError = true
        }
        showResult = true
    }

    // MARK: - Default semester start

    private static func defaultSemesterStart() -> Date {
        let now = Date()
        let cal = Calendar.current
        let month = cal.component(.month, from: now)
        let year  = cal.component(.year, from: now)

        // Semester 1 starts in early September, Semester 2 in mid-February
        var comps = DateComponents()
        comps.year  = year
        comps.day   = 1
        if month >= 8 {
            comps.month = 9   // First semester: September
        } else {
            comps.month = 2   // Second semester: February
        }
        return cal.date(from: comps) ?? now
    }
}
