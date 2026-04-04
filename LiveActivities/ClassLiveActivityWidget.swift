import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct ClassLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClassLiveActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.mode == "current" ? "本節課" : "下一堂")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(context.state.courseName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.classroom)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if context.state.mode == "current" {
                            Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(context.state.startDate, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.periodLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(progressText(context: context))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(context.state.teacher)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if let nextName = context.state.nextCourseName,
                           let nextRoom = context.state.nextClassroom,
                           let nextTime = context.state.nextStartDate {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("下堂：\(nextName)")
                                    .font(.caption2)
                                    .lineLimit(1)
                                Text("\(nextRoom) • \(nextTime.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } compactLeading: {
                if context.state.mode == "current" {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                } else {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                }
            } compactTrailing: {
                if context.state.mode == "current" {
                    Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                        .font(.caption2.monospacedDigit())
                } else {
                    Text(context.state.startDate, style: .time)
                        .font(.caption2.monospacedDigit())
                }
            } minimal: {
                if context.state.mode == "current" {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                } else {
                    Image(systemName: "clock.fill")
                    .font(.caption2)
                }
            }
            .widgetURL(URL(string: "niuapp://class-schedule"))
            .keylineTint(.mint)
        }
    }

    private func lockScreenView(_ context: ActivityViewContext<ClassLiveActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.state.mode == "current" ? "本節課：\(context.state.courseName)" : "下一堂：\(context.state.courseName)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if context.state.mode == "current" {
                    Text(timerInterval: context.state.startDate...context.state.endDate, countsDown: true)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(context.state.startDate, style: .time)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Label(context.state.classroom, systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
                Label(context.state.periodLabel, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(progressText(context: context))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(context.state.teacher)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let nextName = context.state.nextCourseName,
               let nextRoom = context.state.nextClassroom,
               let nextStart = context.state.nextStartDate {
                HStack(spacing: 8) {
                    Text("下一堂")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(nextName)
                        .font(.caption)
                        .lineLimit(1)
                    Text(nextRoom)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(nextStart, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func progressText(context: ActivityViewContext<ClassLiveActivityAttributes>) -> String {
        if context.state.mode == "current" {
            return "已上 \(elapsedLabel(from: context.state.startDate, to: Date()))"
        }
        return "\(context.state.startDate.formatted(date: .omitted, time: .shortened)) 開始"
    }

    private func elapsedLabel(from start: Date, to end: Date) -> String {
        let value = max(0, Int(end.timeIntervalSince(start)))
        let hour = value / 3600
        let minute = (value % 3600) / 60
        if hour > 0 {
            return "\(hour)h \(minute)m"
        }
        return "\(minute)m"
    }
}
#endif
