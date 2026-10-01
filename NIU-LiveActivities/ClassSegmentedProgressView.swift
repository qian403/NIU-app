import SwiftUI

/// One bar for consecutive periods of the same course. Each period is its own
/// timer-backed span with an equal share of the width, so the bar fills across
/// periods without an app wake; each node between spans is the break (下課).
struct ClassSegmentedProgressView: View {
    let segments: [ClosedRange<Date>]
    let tint: Color

    private let nodeSize: CGFloat = 7
    private let nodeSpacing: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let nodeSlot = nodeSize + nodeSpacing * 2
            let barWidth = max(0, proxy.size.width - nodeSlot * CGFloat(segments.count - 1))
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    if index > 0 {
                        Circle()
                            .strokeBorder(tint, lineWidth: 1.5)
                            .background(Circle().fill(tint.opacity(0.35)))
                            .frame(width: nodeSize, height: nodeSize)
                            .padding(.horizontal, nodeSpacing)
                    }
                    ProgressView(timerInterval: segments[index], countsDown: false)
                        .progressViewStyle(.linear)
                        .labelsHidden()
                        .tint(tint)
                        .frame(width: barWidth / CGFloat(segments.count))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: nodeSize + 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("課程進度，連續 \(segments.count) 節")
    }
}

#if DEBUG
#Preview("連續三節", traits: .fixedLayout(width: 320, height: 40)) {
    let start = Date().addingTimeInterval(-70 * 60)
    ClassSegmentedProgressView(
        segments: [
            start...start.addingTimeInterval(50 * 60),
            start.addingTimeInterval(60 * 60)...start.addingTimeInterval(110 * 60),
            start.addingTimeInterval(120 * 60)...start.addingTimeInterval(170 * 60),
        ],
        tint: .mint
    )
    .padding()
    .background(.black)
}
#endif
