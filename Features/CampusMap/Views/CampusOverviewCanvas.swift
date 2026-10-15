import SwiftUI

/// 把總覽地圖的公尺座標對到畫布，北朝上，校園置中於 `padding` 留下的區域。
struct OverviewFrame {
    let size: CGSize
    let padding: EdgeInsets
    let scale: CGFloat
    let offset: CGPoint

    init(campus: CGRect, size: CGSize, padding: EdgeInsets) {
        self.size = size
        self.padding = padding
        let area = FloorFrame.area(size, padding)
        scale = max(min(area.width / campus.width, area.height / campus.height), 0.01)
        offset = CGPoint(x: area.midX - campus.midX * scale, y: area.midY - campus.midY * scale)
    }

    var area: CGRect { FloorFrame.area(size, padding) }

    var transform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.x, ty: offset.y)
    }

    func toCanvas(_ metres: CGPoint) -> CGPoint { metres.applying(transform) }
    func toMetres(_ canvas: CGPoint) -> CGPoint { canvas.applying(transform.inverted()) }
}

/// 全校總覽：建築、道路與綠地。名稱以固定字級繪製、互不重疊，選取的建築優先。
struct CampusOverviewCanvas: View {
    let map: CampusOverview
    let selectedID: Int?
    let padding: EdgeInsets
    let zoom: MapZoom

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = 11

    var body: some View {
        Canvas { context, size in
            let frame = OverviewFrame(campus: map.campus, size: size, padding: padding)
            let t = frame.transform.concatenating(zoom.transform)
            let k = frame.scale * zoom.scale // 每公尺的畫面點數
            let dark = colorScheme == .dark

            context.fill(Path(polygon: map.boundary).applying(t), with: .color(campusFill))
            for area in map.areas {
                let color: Color = switch area.kind {
                case .sport: Color.green.opacity(dark ? 0.26 : 0.18)
                case .green: Color.green.opacity(dark ? 0.16 : 0.12)
                case .water: Color.cyan.opacity(0.2)
                case .parking: Theme.Colors.tertiaryFill
                }
                context.fill(Path(polygon: area.polygon).applying(t), with: .color(color))
            }

            // 道路在畫面上保持可讀的寬度，放大後不小於實際寬度。
            func width(_ kind: CampusRoadKind) -> CGFloat {
                switch kind {
                case .street: max(7 * k, 5)
                case .service: max(3.5 * k, 3)
                case .path: max(1.2 * k, 1.5)
                }
            }
            func line(_ points: [CGPoint]) -> Path {
                var path = Path()
                path.addLines(points)
                return path.applying(t)
            }
            for kind in CampusRoadKind.allCases.reversed() where kind != .path {
                for road in map.roads where road.kind == kind {
                    context.stroke(line(road.line), with: .color(Theme.Colors.separator),
                                   style: StrokeStyle(lineWidth: width(kind) + 2, lineCap: .round, lineJoin: .round))
                }
            }
            for kind in CampusRoadKind.allCases.reversed() {
                let color = kind == .path ? surface.opacity(0.9) : surface
                for road in map.roads where road.kind == kind {
                    context.stroke(line(road.line), with: .color(color),
                                   style: StrokeStyle(lineWidth: width(kind), lineCap: .round, lineJoin: .round))
                }
            }

            for building in map.buildings {
                let on = building.id == selectedID
                let (fill, edge): (Color, Color) = on
                    ? (Theme.Colors.accent, Theme.Colors.accent)
                    : building.plan != nil
                    ? (Color.indigo.opacity(dark ? 0.45 : 0.3), Color.indigo)
                    : building.onCampus
                    ? (Theme.Colors.accentSoft, Theme.Colors.accent.opacity(0.3))
                    : (Color(.systemGray5), Theme.Colors.separator)
                let path = Path(polygon: building.polygon).applying(t)
                context.fill(path, with: .color(fill))
                context.stroke(path, with: .color(edge), lineWidth: on ? 2 : 1)
            }
            context.stroke(Path(polygon: map.boundary).applying(t), with: .color(Theme.Colors.accent), lineWidth: 2)

            drawLabels(in: context, size: size, t: t, k: k)
        }
    }

    private var surface: Color { Color(.secondarySystemGroupedBackground) }

    /// 校內底色比校外的畫布亮一點。
    private var campusFill: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .secondarySystemGroupedBackground
                : UIColor(red: 0.984, green: 0.984, blue: 0.992, alpha: 1)
        })
    }

    private func drawLabels(in context: GraphicsContext, size: CGSize, t: CGAffineTransform, k: CGFloat) {
        var taken: [CGRect] = []
        func place(_ rect: CGRect) -> Bool {
            if taken.contains(where: { $0.intersects(rect) }) { return false }
            taken.append(rect.insetBy(dx: -2, dy: -2))
            return true
        }
        // 選取的優先，接著是有平面圖的、有別名的（格致大樓即電資學院），其餘在後；司令台等最後。
        func rank(_ b: CampusOverviewBuilding) -> Int {
            b.id == selectedID ? 0 : b.plan != nil ? 1 : b.name!.contains("（") ? 2 : b.listed ? 3 : 4
        }
        let named = map.buildings
            .filter { $0.onCampus && $0.name != nil }
            .sorted { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b) : a.bounds.longestSide > b.bounds.longestSide
            }
        let visible = CGRect(origin: .zero, size: size)

        for building in named {
            let on = building.id == selectedID
            let at = building.centre.applying(t)
            let half = CGSize(width: building.bounds.width * k / 2, height: building.bounds.height * k / 2)
            // 先放在建築上，放不下改放四周，再縮一級字，西側密集的建築在全校畫面也保有名稱。
            for size in [fontSize, fontSize * 0.85] {
                let lines = CampusMapText.mapName(building.name!)
                    .split(separator: "\n")
                    .map { labelText(String($0), size: size, on: on, plan: building.plan != nil) }
                let sizes = lines.map {
                    context.resolve($0).measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
                }
                let w = sizes.map(\.width).max() ?? 0, h = sizes.map(\.height).reduce(0, +)
                let dx = half.width + w / 2, dy = half.height + h / 2
                let moves = [
                    CGSize.zero, CGSize(width: 0, height: -dy), CGSize(width: 0, height: dy),
                    CGSize(width: -dx, height: 0), CGSize(width: dx, height: 0),
                    CGSize(width: dx, height: -dy), CGSize(width: -dx, height: -dy),
                    CGSize(width: dx, height: dy), CGSize(width: -dx, height: dy)
                ]
                var spot: CGRect?
                for move in moves {
                    let rect = CGRect(x: at.x + move.width - w / 2, y: at.y + move.height - h / 2, width: w, height: h)
                    // 只有置中的名稱可以超出畫面，移到旁邊的要留在畫面內。
                    if move != .zero, !visible.contains(rect) { continue }
                    if place(rect) {
                        spot = rect
                        break
                    }
                }
                if let spot {
                    var y = spot.minY
                    for (line, measured) in zip(lines, sizes) {
                        drawHalo(line, in: context, at: CGPoint(x: spot.midX, y: y + measured.height / 2), size: size,
                                 color: Theme.Colors.label)
                        y += measured.height
                    }
                    break
                }
            }
        }
    }

    private func labelText(_ text: String, size: CGFloat, on: Bool, plan: Bool) -> Text {
        // 選取的建築底色已是強調色，名稱改用深色加粗，不會藍字壓在藍底上。
        Text(text).font(.system(size: size, weight: on ? .heavy : plan ? .bold : .medium))
    }

    /// 文字四周描一圈畫布底色，壓在道路與建築上也看得清楚。
    private func drawHalo(_ label: Text, in context: GraphicsContext, at point: CGPoint, size: CGFloat, color: Color) {
        let halo = context.resolve(label.foregroundStyle(Color(.systemGroupedBackground)))
        let d = size / 12
        for offset in [CGSize(width: d, height: 0), CGSize(width: -d, height: 0), CGSize(width: 0, height: d), CGSize(width: 0, height: -d)] {
            context.draw(halo, at: CGPoint(x: point.x + offset.width, y: point.y + offset.height))
        }
        context.draw(context.resolve(label.foregroundStyle(color)), at: point)
    }
}
