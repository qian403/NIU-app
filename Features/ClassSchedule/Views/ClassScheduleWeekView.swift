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
    private let palette: [Color] = [.blue, .teal, .orange, .pink, .green, .indigo]

    private var gridRule: Color {
        Theme.Colors.separator.opacity(colorScheme == .dark ? 0.3 : 0.18)
    }

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
                            VStack(spacing: Theme.Spacing.small) {
                                Image(systemName: "calendar.badge.checkmark")
                                    .font(.largeTitle.weight(.light))
                                    .foregroundStyle(Theme.Colors.accent)
                                    .padding(20)
                                    .background(Theme.Colors.accentSoft, in: RoundedRectangle(cornerRadius: 24))
                                Text("這週沒有課").font(.headline)
                                Text("下拉即可更新課表")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, Theme.Spacing.medium)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(0, geometry.size.height - 24 - statusHeight))
                        } else if dynamicTypeSize.isAccessibilitySize {
                            ScrollView(.horizontal) {
                                timetable(layout: layout, now: now, metrics: metrics)
                            }
                        } else {
                            timetable(layout: layout, now: now, metrics: metrics)
                        }
                        updateStatus(layout: layout)
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

    private func updateStatus(layout: ClassScheduleWeekLayout) -> some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            if let first = layout.columns.first, let last = layout.columns.last {
                Text("\(first.dateLabel) – \(last.dateLabel)")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                    .accessibilityLabel("本週顯示日期，\(first.dateLabel)到\(last.dateLabel)")
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("更新中")
                } else if let cacheAgeText {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("更新於 \(displayCacheAgeText(cacheAgeText))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 4)
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
                VStack(spacing: 2) {
                    Text("節次").font(.caption2.weight(.medium))
                    Text("時間").font(.caption2)
                }
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                    .frame(width: metrics.gutterWidth)
                    .frame(height: metrics.headerHeight)
                    .overlay(alignment: .bottom) { gridRule.frame(height: 0.5) }
                ForEach(Array(layout.visibleRows), id: \.self) { row in
                    VStack(spacing: 2) {
                        Text(schedule.periods[row].id)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                        Text(schedule.periods[row].startTimeLabel).font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.Colors.tertiaryLabel)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, min(5, metrics.rowHeight * 0.08))
                    .frame(width: metrics.gutterWidth, height: metrics.rowHeight, alignment: .top)
                    .clipped()
                }
            }
            .frame(width: metrics.gutterWidth)
            .background(Theme.Colors.groupedBackground.opacity(0.6))
            ForEach(layout.columns) { column in
                let isToday = ScheduleClock.calendar.isDate(column.date, inSameDayAs: now)
                VStack(spacing: 0) {
                    header(column, isToday: isToday, height: metrics.headerHeight)
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(Array(layout.visibleRows), id: \.self) { _ in
                                Rectangle().fill(Color.clear)
                                    .frame(height: metrics.rowHeight)
                                    .overlay(alignment: .top) { gridRule.frame(height: 0.5) }
                            }
                        }
                        .background {
                            if isToday {
                                LinearGradient(
                                    colors: [
                                        Theme.Colors.accent.opacity(colorScheme == .dark ? 0.12 : 0.045),
                                        Theme.Colors.accent.opacity(colorScheme == .dark ? 0.04 : 0.015)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            }
                        }
                        .overlay(alignment: .leading) { gridRule.frame(width: 0.5) }
                        ForEach(layout.blocks.filter { $0.column == column.id }) { block in
                            let inset: CGFloat = metrics.columnWidth < 48 ? 2 : 3
                            let height = max(0, CGFloat(block.rows.count) * metrics.rowHeight - inset * 2)
                            courseBlock(block, layout: layout, height: height, width: metrics.columnWidth - inset * 2)
                                .frame(width: max(1, metrics.columnWidth - inset * 2), height: height)
                                .offset(x: inset, y: CGFloat(block.rows.lowerBound - layout.visibleRows.lowerBound) * metrics.rowHeight + inset)
                        }
                        if isToday, let position = layout.nowLinePosition(periods: schedule.periods, at: now) {
                            Rectangle().fill(Theme.Colors.error).frame(height: 1.5)
                                .overlay(alignment: .leading) {
                                    Circle().fill(Theme.Colors.error)
                                        .frame(width: 6, height: 6)
                                        .overlay { Circle().stroke(Theme.Colors.background, lineWidth: 1) }
                                }
                                .offset(y: CGFloat(position) * metrics.rowHeight)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(height: CGFloat(layout.visibleRows.count) * metrics.rowHeight)
                }
                .frame(width: metrics.columnWidth)
            }
        }
        .frame(height: metrics.gridHeight)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .strokeBorder(gridRule, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private func header(_ column: ClassScheduleWeekLayout.Column, isToday: Bool, height: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(column.shortLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isToday ? Theme.Colors.accent : Theme.Colors.secondaryLabel)
            Text(column.dateLabel)
                .font(.system(.caption, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : Theme.Colors.label)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background {
                    if isToday {
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.xsmall)
                            .fill(Theme.Colors.accent)
                    }
                }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.dateLabel)，\(column.header)\(isToday ? "，今天" : "")")
    }

    private func courseBlock(_ block: ClassScheduleWeekLayout.Block, layout: ClassScheduleWeekLayout,
                             height: CGFloat, width: CGFloat) -> some View {
        let colour = palette[ClassScheduleWeekLayout.stableColourIndex(for: block.course.name, paletteCount: palette.count)]
        let compact = width < 48
        let showsRoom = height >= 40 && !block.classrooms.isEmpty
        let showsTeacher = height >= 100 && !block.teachers.isEmpty
        let titleLines = height >= 110 ? 4 : (height >= 70 ? 3 : (height >= 48 ? 2 : 1))
        return NavigationLink {
            ClassScheduleCourseDestination(courseName: block.course.name)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(block.course.name)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(titleLines)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(2)
                if showsTeacher {
                    Text(block.teachers.joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if showsRoom {
                    Text(block.classrooms.joined(separator: "、"))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                }
            }
            .padding(.leading, compact ? 4 : 6)
            .padding(.trailing, compact ? 2 : 4)
            .padding(.vertical, height >= 48 ? 6 : 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                LinearGradient(
                    colors: [
                        colour.opacity(colorScheme == .dark ? 0.26 : 0.14),
                        colour.opacity(colorScheme == .dark ? 0.18 : 0.09)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.CornerRadius.xsmall)
                    .strokeBorder(colour.opacity(colorScheme == .dark ? 0.3 : 0.16), lineWidth: 0.5)
            }
            .overlay(alignment: .leading) { colour.frame(width: 2) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.xsmall))
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
