import ActivityKit
import SwiftUI
import WidgetKit

struct ClassLiveActivityContentView<LockScreenContent: View>: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<ClassLiveActivityAttributes>
    @ViewBuilder var lockScreenContent: () -> LockScreenContent

    var body: some View {
        switch activityFamily {
        case .small:
            ClassWatchLiveActivityView(state: context.state, isStale: context.isStale)
        case .medium:
            lockScreenContent()
        @unknown default:
            lockScreenContent()
        }
    }
}

struct ClassWatchLiveActivityView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let state: ClassLiveActivityAttributes.ContentState
    let isStale: Bool

    private var presentation: ClassWatchActivityPresentation {
        ClassWatchActivityPresentation(state: state, isStale: isStale)
    }

    private var tint: Color {
        if presentation.needsRefresh { return .orange }
        return state.mode == "current" ? .mint : .cyan
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            card(courseLines: 2)
            card(courseLines: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    private func card(courseLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Label(presentation.statusLabel, systemImage: presentation.statusSymbol)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let period = presentation.periodLabel {
                    Text(period)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .font(.caption2.weight(.medium))
            .accessibilityElement(children: .combine)

            Text(presentation.courseName)
                .font(.headline)
                .lineLimit(courseLines)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(presentation.courseName)

            if presentation.needsRefresh {
                Label("開啟 iPhone 更新", systemImage: "iphone")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(presentation.classroom, systemImage: "mappin")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("教室：\(presentation.classroom)")
                    countdown
                        .layoutPriority(1)
                }
                .font(.caption2)

                if let interval = presentation.progressInterval {
                    ProgressView(timerInterval: interval, countsDown: false)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .labelsHidden()
                        .accessibilityLabel("課程進度")
                }
            }
        }
    }

    @ViewBuilder
    private var countdown: some View {
        if let end = presentation.countdownEnd {
            HStack(spacing: 3) {
                Text(presentation.countdownLabel)
                    .foregroundStyle(.white.opacity(0.75))
                Group {
                    if isLuminanceReduced {
                        Text(end, style: .time)
                    } else {
                        Text(timerInterval: min(Date(), end)...end, countsDown: true)
                    }
                }
                // Bound both formats so localized times cannot crowd out the classroom.
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 54, alignment: .trailing)
            }
            .monospacedDigit()
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }
}

#if DEBUG
#Preview("手錶：上課中", traits: .fixedLayout(width: 184, height: 100)) {
    ClassWatchLiveActivityView(state: watchPreviewState(mode: "current"), isStale: false)
        .background(.black)
}

#Preview("手錶：下一堂", traits: .fixedLayout(width: 172, height: 100)) {
    ClassWatchLiveActivityView(state: watchPreviewState(mode: "upcoming"), isStale: false)
        .background(.black)
}

#Preview("手錶：待更新", traits: .fixedLayout(width: 172, height: 100)) {
    ClassWatchLiveActivityView(state: watchPreviewState(mode: "current"), isStale: true)
        .background(.black)
}

private func watchPreviewState(mode: String) -> ClassLiveActivityAttributes.ContentState {
    let start = Date().addingTimeInterval(mode == "current" ? -1200 : 900)
    return .init(
        mode: mode,
        courseName: "資訊安全導論",
        classroom: "工102",
        teacher: "測試教師",
        periodLabel: "第3節",
        startDate: start,
        endDate: start.addingTimeInterval(3000)
    )
}
#endif
