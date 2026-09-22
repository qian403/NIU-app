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
                    VStack(alignment: .leading, spacing: 4) {
                        Label(activityStatusLabel(context), systemImage: activityStatusSymbol(context))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(activityStatusTint(context))
                            .labelStyle(.titleAndIcon)
                        Text(context.state.courseName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    .accessibilityElement(children: .combine)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        countdown(context: context)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                        if !context.isStale {
                            Text(context.state.mode == "current" ? "下課" : "開始")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Label(context.state.classroom, systemImage: "mappin.and.ellipse")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Label(context.state.periodLabel, systemImage: "clock")
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        courseProgress(context: context)

                        HStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(context.state.teacher)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if !context.isStale {
                                Text(progressText(context: context))
                                    .font(.caption2.monospacedDigit())
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } compactLeading: {
                Image(systemName: activityStatusSymbol(context))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(activityStatusTint(context))
                    .accessibilityLabel(activityStatusLabel(context))
            } compactTrailing: {
                countdown(context: context)
                    .font(.caption2.monospacedDigit())
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                    .frame(minWidth: 34, alignment: .trailing)
            } minimal: {
                Image(systemName: activityStatusSymbol(context))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(activityStatusTint(context))
                    .accessibilityLabel(activityStatusLabel(context))
            }
            .widgetURL(URL(string: "niuapp://class-schedule"))
            .keylineTint(activityStatusTint(context))
        }
    }

    private func activityStatusLabel(_ context: ActivityViewContext<ClassLiveActivityAttributes>) -> String {
        if context.isStale { return "課表待更新" }
        return context.state.mode == "current" ? "上課中" : "下一堂課"
    }

    private func activityStatusSymbol(_ context: ActivityViewContext<ClassLiveActivityAttributes>) -> String {
        if context.isStale { return "arrow.clockwise" }
        return context.state.mode == "current" ? "play.fill" : "clock.fill"
    }

    private func activityStatusTint(_ context: ActivityViewContext<ClassLiveActivityAttributes>) -> Color {
        if context.isStale { return .orange }
        return context.state.mode == "current" ? .mint : .cyan
    }

    private func lockScreenView(_ context: ActivityViewContext<ClassLiveActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.isStale ? "課程資訊待更新" : (context.state.mode == "current" ? "本節課：\(context.state.courseName)" : "下一堂：\(context.state.courseName)"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(context.isStale ? "待更新" : progressText(context: context))
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
                if !context.isStale {
                    Text(progressText(context: context))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
        if context.isStale {
            Label("開啟 App 更新課表", systemImage: "arrow.clockwise")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let configuration = courseProgressConfiguration(
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
            .tint(context.state.mode == "current" ? .mint : .cyan)
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
    isStale: Bool,
    startDate: Date,
    endDate: Date
) -> CourseProgressConfiguration? {
    guard !isStale, endDate > startDate else { return nil }
    return CourseProgressConfiguration(interval: startDate...endDate, countsDown: false)
}
