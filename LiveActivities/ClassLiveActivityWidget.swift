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
            } compactLeading: {
                if context.state.mode == "current" {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                } else {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                }
            } compactTrailing: {
                Text(compactTrailingText(context: context))
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
                Text(context.state.mode == "current" ? "本節課：\(context.state.courseName)" : "下一堂：\(context.state.courseName)")
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

    private func progressText(context: ActivityViewContext<ClassLiveActivityAttributes>) -> String {
        if context.state.mode == "current" {
            return "\(context.state.endDate.formatted(date: .omitted, time: .shortened)) 下課"
        }
        return "\(context.state.startDate.formatted(date: .omitted, time: .shortened)) 開始"
    }

    private func compactTrailingText(context: ActivityViewContext<ClassLiveActivityAttributes>) -> String {
        if context.state.mode == "current" {
            let minutes = max(0, Int(context.state.endDate.timeIntervalSinceNow / 60.0.rounded(.down)))
            return minutes > 0 ? "\(minutes)m" : context.state.endDate.formatted(date: .omitted, time: .shortened)
        }
        return context.state.startDate.formatted(date: .omitted, time: .shortened)
    }
}
#endif
