import SwiftUI

struct DiverseHoursProgressBarShape: Shape {
    var jointOffset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 18 : 8

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let topY: CGFloat = 0
        let halfY: CGFloat = rect.height / 2
        let back_1: CGFloat = rect.width / 1.7

        path.move(to: CGPoint(x: 0, y: topY))
        path.addLine(to: CGPoint(x: rect.width, y: topY))
        path.addLine(to: CGPoint(x: rect.width - jointOffset, y: halfY))
        path.addLine(to: CGPoint(x: back_1, y: halfY))
        path.addLine(to: CGPoint(x: back_1 - jointOffset, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

struct DiverseHoursProgressBarFilled: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            let fullWidth = geo.size.width
            let height = geo.size.height
            let width = fullWidth * progress

            let jointOffset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 18 : 8
            let effectiveOffset = jointOffset * 2

            let fillShape = Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: width, y: 0))
                path.addLine(to: CGPoint(x: width - effectiveOffset, y: height))
                path.addLine(to: CGPoint(x: 0, y: height))
                path.closeSubpath()
            }

            fillShape
                .fill(barColor(for: progress))
                .mask(DiverseHoursProgressBarShape())
        }
    }

    private func barColor(for progress: CGFloat) -> Color {
        if progress < 0.37 {
            return Color(red: 0.58, green: 0, blue: 0.24).opacity(0.6)
        } else if progress < 0.67 {
            return Color(red: 0.74, green: 0.75, blue: 0).opacity(0.6)
        } else {
            return Color(red: 0.42, green: 0.72, blue: 0.07).opacity(0.6)
        }
    }
}
