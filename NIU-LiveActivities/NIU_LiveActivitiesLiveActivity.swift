import ActivityKit
import WidgetKit
import SwiftUI

@available(iOSApplicationExtension 16.1, *)
struct NIU_LiveActivitiesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClassLiveActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.isStale ? "待更新" : (context.state.mode == "current" ? "本節課" : "下一堂"))
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
                        Text(progressText(context: context))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
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
                    VStack(spacing: 5) {
                        courseProgress(context: context)
                        HStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(context.state.teacher)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(progressText(context: context))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
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
                countdown(context: context)
                    .font(.caption2.monospacedDigit())
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
                Text(context.isStale ? "課程資訊待更新" : (context.state.mode == "current" ? "本節課：\(context.state.courseName)" : "下一堂：\(context.state.courseName)"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(progressText(context: context))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(context.state.classroom, systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
                Label(context.state.periodLabel, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            courseProgress(context: context)

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func courseProgress(context: ActivityViewContext<ClassLiveActivityAttributes>) -> some View {
        if let configuration = courseProgressConfiguration(
            mode: context.state.mode,
            isStale: context.isStale,
            startDate: context.state.startDate,
            endDate: context.state.endDate
        ) {
            // Keep the timer-backed view mounted while the course is upcoming. Its
            // value stays at zero until startDate, then advances without an app wake.
            ProgressView(
                timerInterval: configuration.interval,
                countsDown: configuration.countsDown
            )
            .progressViewStyle(.linear)
            .tint(.mint)
            .accessibilityLabel("課程進度")
        }
    }

    private func progressText(context: ActivityViewContext<ClassLiveActivityAttributes>) -> String {
        if context.isStale { return "開啟 App 更新課表" }
        if context.state.mode == "current" {
            return "\(context.state.endDate.formatted(date: .omitted, time: .shortened)) 下課"
        }
        return "\(context.state.startDate.formatted(date: .omitted, time: .shortened)) 開始"
    }

    @ViewBuilder
    private func countdown(context: ActivityViewContext<ClassLiveActivityAttributes>) -> some View {
        if context.isStale {
            Text("待更新")
        } else {
            let end = context.state.mode == "current" ? context.state.endDate : context.state.startDate
            Text(timerInterval: min(Date(), end)...end, countsDown: true, showsHours: false)
                .monospacedDigit()
        }
    }
}

private struct CourseProgressConfiguration {
    let interval: ClosedRange<Date>
    let countsDown: Bool
}

private func courseProgressConfiguration(
    mode _: String,
    isStale _: Bool,
    startDate: Date,
    endDate: Date
) -> CourseProgressConfiguration? {
    guard endDate > startDate else { return nil }
    return CourseProgressConfiguration(interval: startDate...endDate, countsDown: false)
}
