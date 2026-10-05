import SwiftUI

struct ClassScheduleWeekView: View {
    let schedule: ClassSchedule
    let displayDayHeaders: [String]
    let isRefreshing: Bool
    let cacheAgeText: String?
    let refresh: () async -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 88
    @ScaledMetric(relativeTo: .caption2) private var gutterWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .caption) private var minimumColumnWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .caption) private var statusHeight: CGFloat = 28
    private let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green]

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now = displayDate(context.date)
                let layout = ClassScheduleWeekLayout(schedule: schedule, displayDayHeaders: displayDayHeaders, now: now)
                let metrics = ClassScheduleWeekLayout.GridMetrics(
                    availableSize: geometry.size, columns: layout.columns.count, rows: layout.visibleRows.count,
                    expanded: dynamicTypeSize.isAccessibilitySize, preferredRowHeight: rowHeight,
                    gutterWidth: gutterWidth, minimumColumnWidth: minimumColumnWidth, statusHeight: statusHeight
                )
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        if layout.blocks.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "calendar.badge.checkmark")
                                    .font(.largeTitle.weight(.light))
                                    .foregroundStyle(Color.accentColor)
                                Text("這週沒有課").font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: max(0, geometry.size.height - 24 - statusHeight))
                        } else if dynamicTypeSize.isAccessibilitySize {
                            ScrollView(.horizontal) {
                                timetable(layout: layout, now: now, metrics: metrics)
                            }
                        } else {
                            timetable(layout: layout, now: now, metrics: metrics)
                        }
                        updateStatus
                            .frame(height: statusHeight)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .refreshable { await refresh() }
            }
        }
    }

    private func displayDate(_ date: Date) -> Date {
        #if DEBUG
        if ClassScheduleUIFixture.requested { return ClassScheduleUIFixture.now }
        #endif
        return date
    }

    private var updateStatus: some View {
        HStack(spacing: 5) {
            if isRefreshing {
                ProgressView().controlSize(.mini)
                Text("更新中")
            } else if let cacheAgeText {
                Image(systemName: "clock.arrow.circlepath")
                Text("更新於 \(displayCacheAgeText(cacheAgeText))")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }

    private func displayCacheAgeText(_ text: String) -> String {
        #if DEBUG
        if ClassScheduleUIFixture.requested { return "5 分鐘前" }
        #endif
        return text
    }

    private func timetable(layout: ClassScheduleWeekLayout, now: Date,
                           metrics: ClassScheduleWeekLayout.GridMetrics) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                Text("節次").font(.caption2).foregroundStyle(.secondary)
                    .frame(height: metrics.headerHeight)
                ForEach(Array(layout.visibleRows), id: \.self) { row in
                    VStack(spacing: 2) {
                        Text(schedule.periods[row].id).font(.caption.bold())
                        Text(schedule.periods[row].startTimeLabel).font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: metrics.gutterWidth, height: metrics.rowHeight, alignment: .top)
                }
            }
            .frame(width: metrics.gutterWidth)
            ForEach(layout.columns) { column in
                let isToday = ScheduleClock.calendar.isDate(column.date, inSameDayAs: now)
                VStack(spacing: 0) {
                    header(column, isToday: isToday, height: metrics.headerHeight)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(Array(layout.visibleRows), id: \.self) { _ in
                                Rectangle().fill(Color.clear)
                                    .frame(height: metrics.rowHeight)
                                    .overlay(alignment: .top) { Divider() }
                            }
                        }
                        ForEach(layout.blocks.filter { $0.column == column.id }) { block in
                            let height = max(0, CGFloat(block.rows.count) * metrics.rowHeight - 4)
                            courseBlock(block, layout: layout, height: height)
                                .frame(width: max(1, metrics.columnWidth - 4), height: height)
                                .offset(x: 2, y: CGFloat(block.rows.lowerBound - layout.visibleRows.lowerBound) * metrics.rowHeight + 2)
                        }
                        if isToday, let position = layout.nowLinePosition(periods: schedule.periods, at: now) {
                            Rectangle().fill(.red).frame(height: 2)
                                .overlay(alignment: .leading) { Circle().fill(.red).frame(width: 6, height: 6) }
                                .offset(y: CGFloat(position) * metrics.rowHeight)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: CGFloat(layout.visibleRows.count) * metrics.rowHeight)
                }
                .frame(width: metrics.columnWidth)
                .background(isToday ? Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.05) : Color.clear)
            }
        }
        .frame(height: metrics.gridHeight)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func header(_ column: ClassScheduleWeekLayout.Column, isToday: Bool, height: CGFloat) -> some View {
        VStack(spacing: 3) {
            Text(column.shortLabel).font(.caption.bold())
            Text(column.dateLabel).font(.caption2.monospacedDigit())
        }
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .foregroundStyle(isToday ? Color(.systemBackground) : Color.primary)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(isToday ? Color.accentColor : Color.clear, in: Capsule())
        .padding(.horizontal, 2)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.dateLabel)，\(column.header)\(isToday ? "，今天" : "")")
    }

    private func courseBlock(_ block: ClassScheduleWeekLayout.Block, layout: ClassScheduleWeekLayout,
                             height: CGFloat) -> some View {
        let colour = palette[ClassScheduleWeekLayout.stableColourIndex(for: block.course.name, paletteCount: palette.count)]
        return NavigationLink {
            ClassScheduleCourseDestination(courseName: block.course.name)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(block.course.name)
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(height >= 60 ? 3 : (height >= 48 ? 2 : 1))
                    .minimumScaleFactor(0.8)
                if height >= 88, !block.teachers.isEmpty {
                    Text(block.teachers.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if height >= 32, !block.classrooms.isEmpty {
                    Text(block.classrooms.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 5)
            .padding(.trailing, 3)
            .padding(.vertical, height >= 44 ? 5 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colour.opacity(colorScheme == .dark ? 0.25 : 0.12))
            .overlay(alignment: .leading) { colour.frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.accessibilityLabel(for: block, periods: schedule.periods))
        .accessibilityHint("開啟 M 園區課程")
    }
}

/// Both schedule modes use the same destination; fixture launches stay entirely offline.
struct ClassScheduleCourseDestination: View {
    let courseName: String

    var body: some View {
        #if DEBUG
        if ClassScheduleUIFixture.requested {
            Text("離線課表展示，不連線至 M 園區。")
                .navigationTitle(courseName)
        } else {
            MoodleScheduleCourseView(courseName: courseName)
        }
        #else
        MoodleScheduleCourseView(courseName: courseName)
        #endif
    }
}
