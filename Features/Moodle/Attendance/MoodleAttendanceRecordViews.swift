import SwiftUI

struct MoodleAttendanceContent: View {
    let state: MoodleAttendanceViewModel.State
    let sections: [MoodleAttendanceSection]
    let refreshError: String?
    let retry: () async -> Void

    @State private var selectedSectionID: Int?

    var body: some View {
        Group {
            switch state {
            case .idle where sections.isEmpty,
                 .loading where sections.isEmpty:
                AttendanceLoadingView()
            case .failed(let message) where sections.isEmpty:
                AttendanceFailureView(message: message, retry: retry)
            default:
                loadedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear(perform: selectFirstSectionIfNeeded)
        .onChange(of: sections.map(\.id)) { _, _ in
            selectFirstSectionIfNeeded()
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if sections.isEmpty {
            AttendanceEmptyView(retry: retry)
        } else {
            ScrollView {
                LazyVStack(spacing: 18) {
                    if let refreshError {
                        AttendanceRefreshErrorBanner(message: refreshError, retry: retry)
                    }

                    if sections.count > 1 {
                        AttendanceSectionPicker(
                            sections: sections,
                            selection: $selectedSectionID
                        )
                    }

                    if let selectedSection {
                        AttendanceLedgerView(section: selectedSection)
                            .id(selectedSection.id)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .animation(.easeInOut(duration: 0.24), value: selectedSectionID)
        }
    }

    private var selectedSection: MoodleAttendanceSection? {
        sections.first(where: { $0.id == selectedSectionID }) ?? sections.first
    }

    private func selectFirstSectionIfNeeded() {
        guard !sections.isEmpty else {
            selectedSectionID = nil
            return
        }

        if !sections.contains(where: { $0.id == selectedSectionID }) {
            selectedSectionID = sections[0].id
        }
    }
}

private struct AttendanceLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在整理點名冊")
                .font(.headline)
            Text("同步本學期的出席紀錄…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AttendanceFailureView: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("點名冊無法開啟", systemImage: "person.crop.rectangle.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("再試一次") {
                Task { await retry() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct AttendanceEmptyView: View {
    let retry: () async -> Void

    var body: some View {
        ScrollView {
            ContentUnavailableView {
                Label("這學期還沒有點名冊", systemImage: "list.clipboard")
            } description: {
                Text("老師建立點名活動後，紀錄會自動整理在這裡。")
            } actions: {
                Button("重新整理") {
                    Task { await retry() }
                }
            }
            .frame(minHeight: 420)
        }
    }
}

private struct AttendanceRefreshErrorBanner: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AttendancePalette.warning)
                .frame(width: 36, height: 36)
                .background(AttendancePalette.warning.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("目前顯示上次同步的紀錄")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("重試") {
                Task { await retry() }
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(AttendancePalette.warning.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct AttendanceSectionPicker: View {
    let sections: [MoodleAttendanceSection]
    @Binding var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("點名冊")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1.2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sections) { section in
                        let isSelected = selection == section.id
                        Button {
                            selection = section.id
                        } label: {
                            Text(section.moduleName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .background(
                                    isSelected ? AttendancePalette.ink : Color(.secondarySystemGroupedBackground),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityLabel(section.accessibilityTitle)
                    }
                }
            }
        }
    }
}

private struct AttendanceLedgerView: View {
    let section: MoodleAttendanceSection

    var body: some View {
        VStack(spacing: 16) {
            AttendanceOverview(section: section)
            AttendanceRecordBook(section: section)
        }
    }
}

private struct AttendanceOverview: View {
    let section: MoodleAttendanceSection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    identity
                    Spacer(minLength: 10)
                    rate
                }

                VStack(alignment: .leading, spacing: 12) {
                    identity
                    HStack {
                        Spacer()
                        rate
                    }
                }
            }

            attendanceProgress

            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    metrics
                }
            } else {
                HStack(spacing: 0) {
                    AttendanceOverviewMetric(value: section.presentCount, label: "出席", color: AttendancePalette.presentHero)
                    divider
                    AttendanceOverviewMetric(value: section.absentCount, label: "缺席", color: AttendancePalette.absentHero)
                    divider
                    AttendanceOverviewMetric(value: section.pendingCount, label: "待確認", color: AttendancePalette.pendingHero)
                    divider
                    AttendanceOverviewMetric(value: section.total, label: "總堂數", color: .white)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: section.source == .webService ? "checkmark.icloud" : "arrow.triangle.2.circlepath.icloud")
                Text(section.source == .webService ? "已和 M 園區同步" : "已透過相容模式同步")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.52))
        }
        .padding(20)
        .background {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(
                    colors: [AttendancePalette.ink, AttendancePalette.navy],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .stroke(.white.opacity(0.055), lineWidth: 24)
                    .frame(width: 190, height: 190)
                    .offset(x: 72, y: 86)

                Circle()
                    .fill(AttendancePalette.highlight.opacity(0.08))
                    .frame(width: 92, height: 92)
                    .offset(x: 26, y: 34)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: AttendancePalette.ink.opacity(0.15), radius: 18, y: 10)
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("本學期點名冊")
                .font(.caption.weight(.black))
                .tracking(1.2)
                .foregroundStyle(AttendancePalette.highlight)

            Text(section.moduleName)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if !section.sectionName.isEmpty {
                Text(section.sectionName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var metrics: some View {
        AttendanceOverviewMetric(value: section.presentCount, label: "出席", color: AttendancePalette.presentHero)
        AttendanceOverviewMetric(value: section.absentCount, label: "缺席", color: AttendancePalette.absentHero)
        AttendanceOverviewMetric(value: section.pendingCount, label: "待確認", color: AttendancePalette.pendingHero)
        AttendanceOverviewMetric(value: section.total, label: "總堂數", color: .white)
    }

    @ViewBuilder
    private var rate: some View {
        if section.resolvedCount > 0 {
            VStack(alignment: .trailing, spacing: -2) {
                Text(section.attendanceRate, format: .percent.precision(.fractionLength(0)))
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("已結算出席率")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text("—")
                    .font(.largeTitle.weight(.black))
                    .foregroundStyle(.white.opacity(0.6))
                Text("尚無已結算紀錄")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var attendanceProgress: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(AttendancePalette.highlight)
                    .frame(
                        width: section.resolvedCount > 0
                            ? proxy.size.width * section.attendanceRate
                            : 0
                    )
            }
        }
        .frame(height: 6)
        .accessibilityLabel("已結算出席率")
        .accessibilityValue(
            section.resolvedCount > 0
                ? section.attendanceRate.formatted(.percent.precision(.fractionLength(0)))
                : "尚無資料"
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 32)
    }
}

private struct AttendanceOverviewMetric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AttendanceRecordBook: View {
    let section: MoodleAttendanceSection

    @State private var filter: AttendanceRecordFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            recordBookHeader
            Divider()
                .padding(.horizontal, 16)
            filters

            if filteredRecords.isEmpty {
                emptyFilterState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(monthGroups) { group in
                        AttendanceMonthSection(group: group)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: filter)
    }

    private var recordBookHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("點名明細")
                    .font(.headline)
                Text("依日期由新到舊排列")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(section.records.count) 筆")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.09), in: Capsule())
                .contentTransition(.numericText())
        }
        .padding(16)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AttendanceRecordFilter.allCases) { option in
                    let count = option.count(in: section.records)
                    Button {
                        filter = option
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.icon)
                                .font(.system(size: 10, weight: .bold))
                            Text(option.title)
                            if option != .all {
                                Text("\(count)")
                                    .monospacedDigit()
                                    .foregroundStyle(filter == option ? .white.opacity(0.72) : .secondary)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(filter == option ? Color.white : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            filter == option ? option.selectionBackground : Color.primary.opacity(0.055),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                    .accessibilityLabel("\(option.title)，\(count) 筆")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter.emptyIcon)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(filter.tint)
            Text(filter.emptyMessage)
                .font(.subheadline.weight(.semibold))
            if filter != .all {
                Button("查看全部紀錄") {
                    filter = .all
                }
                .font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private var filteredRecords: [MoodleAttendanceRecord] {
        section.records
            .filter(filter.matches)
            .sorted { $0.date > $1.date }
    }

    private var monthGroups: [AttendanceMonthGroup] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: filteredRecords) { record in
            let components = calendar.dateComponents([.year, .month], from: record.date)
            return (components.year ?? 0) * 100 + (components.month ?? 0)
        }

        return grouped
            .sorted { $0.key > $1.key }
            .map { key, records in
                let year = key / 100
                let month = key % 100
                let date = calendar.date(from: DateComponents(year: year, month: month))
                return AttendanceMonthGroup(
                    id: key,
                    title: date?.formatted(.dateTime.year().month(.wide)) ?? "\(year) 年 \(month) 月",
                    records: records.sorted { $0.date > $1.date }
                )
            }
    }
}

private enum AttendanceRecordFilter: String, CaseIterable, Identifiable {
    case all
    case present
    case absent
    case pending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .present: "出席"
        case .absent: "缺席"
        case .pending: "待確認"
        }
    }

    var icon: String {
        switch self {
        case .all: "line.3.horizontal.decrease"
        case .present: "checkmark"
        case .absent: "xmark"
        case .pending: "clock"
        }
    }

    var emptyIcon: String {
        switch self {
        case .all: "list.clipboard"
        case .present: "checkmark.circle"
        case .absent: "checkmark.shield"
        case .pending: "clock.badge.checkmark"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "老師尚未建立點名紀錄"
        case .present: "目前沒有出席紀錄"
        case .absent: "太好了，目前沒有缺席紀錄"
        case .pending: "沒有待確認的紀錄"
        }
    }

    var tint: Color {
        switch self {
        case .all: AttendancePalette.ink
        case .present: AttendancePalette.present
        case .absent: AttendancePalette.absent
        case .pending: AttendancePalette.pending
        }
    }

    var selectionBackground: Color {
        switch self {
        case .all: AttendancePalette.ink
        case .present: AttendancePalette.presentSelection
        case .absent: AttendancePalette.absentSelection
        case .pending: AttendancePalette.pendingSelection
        }
    }

    func matches(_ record: MoodleAttendanceRecord) -> Bool {
        switch (self, record.status) {
        case (.all, _), (.present, .present), (.absent, .absent), (.pending, .pending): true
        default: false
        }
    }

    func count(in records: [MoodleAttendanceRecord]) -> Int {
        records.filter(matches).count
    }
}

private struct AttendanceMonthGroup: Identifiable {
    let id: Int
    let title: String
    let records: [MoodleAttendanceRecord]
}

private struct AttendanceMonthSection: View {
    let group: AttendanceMonthGroup

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(group.title)
                    .font(.caption.weight(.bold))
                Spacer()
                Text("\(group.records.count) 堂")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.035))

            ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                AttendanceRecordRow(record: record)

                if index < group.records.count - 1 {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
    }
}

private struct AttendanceRecordRow: View {
    let record: MoodleAttendanceRecord
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            dateStamp

            Rectangle()
                .fill(record.status.tint)
                .frame(width: 3)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 6) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 7) {
                        recordTitle
                        AttendanceStatusBadge(record: record)
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        recordTitle
                        Spacer(minLength: 4)
                        AttendanceStatusBadge(record: record)
                    }
                }

                if !record.timeText.isEmpty {
                    Label(record.timeText, systemImage: "clock")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if record.scoreText?.nilIfBlank != nil || record.remarks?.nilIfBlank != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        if let score = record.scoreText?.nilIfBlank {
                            detailLabel(icon: "number", text: "分數 \(score)")
                        }
                        if let remarks = record.remarks?.nilIfBlank {
                            detailLabel(icon: "text.bubble", text: remarks)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var recordTitle: some View {
        Text(record.description?.nilIfBlank ?? "課堂點名")
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dateStamp: some View {
        VStack(spacing: 1) {
            Text("\(Calendar.autoupdatingCurrent.component(.day, from: record.date))")
                .font(.title2.weight(.black))
                .monospacedDigit()
            Text(record.date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 42)
    }

    private func detailLabel(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var accessibilitySummary: String {
        var parts = [
            record.date.formatted(date: .complete, time: .omitted),
            record.timeText,
            record.description?.nilIfBlank ?? "課堂點名",
            record.statusLabel
        ]
        if let score = record.scoreText?.nilIfBlank {
            parts.append("分數 \(score)")
        }
        if let remarks = record.remarks?.nilIfBlank {
            parts.append("備註 \(remarks)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "，")
    }
}

private struct AttendanceStatusBadge: View {
    let record: MoodleAttendanceRecord
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: record.status.icon)
                .font(.caption2.weight(.black))
            Text(record.statusLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(record.status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(record.status.tint.opacity(0.11), in: Capsule())
        .frame(
            maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 110,
            alignment: .leading
        )
    }
}

private extension MoodleAttendanceRecord.Status {
    var tint: Color {
        switch self {
        case .present: AttendancePalette.present
        case .absent: AttendancePalette.absent
        case .pending: AttendancePalette.pending
        }
    }

    var icon: String {
        switch self {
        case .present: "checkmark"
        case .absent: "xmark"
        case .pending: "clock"
        }
    }
}

private extension MoodleAttendanceSection {
    var accessibilityTitle: String {
        sectionName.nilIfBlank.map { "\(moduleName)，\($0)" } ?? moduleName
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum AttendancePalette {
    static let ink = Color(red: 0.055, green: 0.105, blue: 0.17)
    static let navy = Color(red: 0.095, green: 0.20, blue: 0.31)
    static let highlight = Color(red: 1.0, green: 0.69, blue: 0.26)

    static let present = adaptive(
        light: UIColor(red: 0.02, green: 0.38, blue: 0.20, alpha: 1),
        dark: UIColor(red: 0.35, green: 0.86, blue: 0.57, alpha: 1)
    )
    static let absent = adaptive(
        light: UIColor(red: 0.68, green: 0.08, blue: 0.11, alpha: 1),
        dark: UIColor(red: 0.98, green: 0.45, blue: 0.47, alpha: 1)
    )
    static let pending = adaptive(
        light: UIColor(red: 0.46, green: 0.25, blue: 0.01, alpha: 1),
        dark: UIColor(red: 1.0, green: 0.68, blue: 0.22, alpha: 1)
    )

    static let presentSelection = Color(red: 0.02, green: 0.38, blue: 0.20)
    static let absentSelection = Color(red: 0.68, green: 0.08, blue: 0.11)
    static let pendingSelection = Color(red: 0.46, green: 0.25, blue: 0.01)

    static let presentHero = Color(red: 0.42, green: 0.90, blue: 0.63)
    static let absentHero = Color(red: 1.0, green: 0.50, blue: 0.52)
    static let pendingHero = Color(red: 1.0, green: 0.73, blue: 0.30)
    static let warning = Color(red: 0.88, green: 0.39, blue: 0.16)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}
