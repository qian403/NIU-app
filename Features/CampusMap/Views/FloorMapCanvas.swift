import SwiftUI

/// 把大樓的公尺座標對到畫布。寬的大樓放在直向畫布時順時針轉 90 度（西側朝上）；
/// 同一棟的每層樓共用同一個框，切換樓層不跳動。
struct FloorFrame {
    let size: CGSize
    /// 留給浮在平面圖上的控制項的空間。
    let padding: EdgeInsets
    let rotated: Bool
    /// 每公尺的點數
    let scale: CGFloat
    let transform: CGAffineTransform

    init(bounds: CGRect, size: CGSize, padding: EdgeInsets) {
        self.size = size
        self.padding = padding
        let area = Self.area(size, padding)
        rotated = bounds.width > bounds.height && area.height > area.width
        let w = rotated ? bounds.height : bounds.width
        let h = rotated ? bounds.width : bounds.height
        scale = max(min(area.width / max(w, 0.01), area.height / max(h, 0.01)), 0.01)
        transform = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(rotationAngle: rotated ? .pi / 2 : 0))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: area.midX, y: area.midY))
    }

    var area: CGRect { Self.area(size, padding) }

    func toCanvas(_ metres: CGPoint) -> CGPoint { metres.applying(transform) }
    func toMetres(_ canvas: CGPoint) -> CGPoint { canvas.applying(transform.inverted()) }

    static func area(_ size: CGSize, _ padding: EdgeInsets) -> CGRect {
        CGRect(
            x: padding.leading, y: padding.top,
            width: max(size.width - padding.leading - padding.trailing, 1),
            height: max(size.height - padding.top - padding.bottom, 1)
        )
    }
}

/// 一層樓的平面圖。標籤以畫面點數繪製，縮放時字級不變，房間放大到放得下時才出現。
struct FloorMapCanvas: View {
    let building: MapBuilding
    let floor: MapFloor
    let selectedID: String?
    let padding: EdgeInsets
    let zoom: MapZoom

    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = 11

    private static let gap: CGFloat = 0.18, radius: CGFloat = 0.45

    private static let order: [MapSpaceKind] = [.terrace, .corridor, .shaft, .room, .restroom, .stairs, .elevator]

    var body: some View {
        Canvas { context, size in
            let frame = FloorFrame(bounds: building.bounds, size: size, padding: padding)
            let t = frame.transform.concatenating(zoom.transform)
            let k = frame.scale * zoom.scale // 每公尺的畫面點數

            var outline = Path()
            for ring in floor.outlines {
                outline.addPath(Path(polygon: ring))
            }
            outline = outline.applying(t)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.12), radius: 4))
                layer.fill(outline, with: .color(Palette.surface))
            }
            context.stroke(outline, with: .color(Theme.Colors.separator), lineWidth: 1)

            for kind in Self.order {
                for space in floor.spaces where space.kind == kind {
                    drawSpace(space, in: context, t: t, k: k)
                }
            }
            for link in floor.links {
                drawLink(link, in: context, frame: frame, t: t)
            }
            for space in floor.spaces where space.kind == .room || space.kind == .restroom {
                drawLabel(space, in: context, frame: frame, t: t, k: k)
            }
        }
    }

    // MARK: Spaces

    private func drawSpace(_ space: MapSpace, in context: GraphicsContext, t: CGAffineTransform, k: CGFloat) {
        let on = space.id == selectedID
        let (fill, edge): (Color, Color?) = switch space.kind {
        case .terrace: (Palette.terrace, nil)
        case .corridor: (Palette.surface, nil)
        case .shaft: (Theme.Colors.groupedBackground, Palette.fillStrong)
        case .room: on ? (Theme.Colors.accent, Theme.Colors.accent) : (Theme.Colors.accentSoft, Theme.Colors.accent.opacity(0.3))
        case .restroom: (Palette.restroom, Palette.restroomEdge)
        case .stairs, .elevator: (Palette.fillStrong, Theme.Colors.tertiaryLabel.opacity(0.35))
        }
        let flat = space.kind == .corridor || space.kind == .terrace
        let width: CGFloat = on ? 2 : 1
        if flat || !space.isRect {
            // 多邊形共用牆面；裁切後的描邊讓它們像方塊一樣內縮。
            let path = Path(polygon: space.points).applying(t)
            var clipped = context
            clipped.clip(to: path)
            clipped.fill(path, with: .color(fill))
            if !flat {
                clipped.stroke(path, with: .color(edge ?? fill), lineWidth: (Self.gap * k + width) * 2)
                clipped.stroke(path, with: .color(Palette.surface), lineWidth: Self.gap * k * 2)
            }
        } else {
            let tile = Path(
                roundedRect: space.bounds.insetBy(dx: Self.gap, dy: Self.gap),
                cornerRadius: Self.radius
            ).applying(t)
            context.fill(tile, with: .color(fill))
            if let edge {
                context.stroke(tile, with: .color(edge), lineWidth: width)
            }
        }

        let b = space.bounds
        var lines = Path()
        switch space.kind {
        case .stairs:
            let across = b.width >= b.height
            var p = (across ? b.minX : b.minY) + 0.8
            let end = (across ? b.maxX : b.maxY) - 0.8
            while p < end {
                lines.move(to: across ? CGPoint(x: p, y: b.minY + 0.5) : CGPoint(x: b.minX + 0.5, y: p))
                lines.addLine(to: across ? CGPoint(x: p, y: b.maxY - 0.5) : CGPoint(x: b.maxX - 0.5, y: p))
                p += 0.45
            }
        case .elevator, .shaft:
            let m: CGFloat = space.kind == .elevator ? 0.4 : 0.8
            let r = b.insetBy(dx: m, dy: m)
            lines.move(to: CGPoint(x: r.minX, y: r.minY))
            lines.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            lines.move(to: CGPoint(x: r.maxX, y: r.minY))
            lines.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        default:
            return
        }
        context.stroke(lines.applying(t), with: .color(Theme.Colors.tertiaryLabel.opacity(0.35)), lineWidth: 1)
    }

    // MARK: Labels

    /// 先畫完整代碼，放不下就去掉大樓字（教305 → 305），再縮小到畫面 7 pt 為止；
    /// 只有名稱的房間最多換三行。長名稱留在抽屜裡。
    private func drawLabel(_ space: MapSpace, in context: GraphicsContext, frame: FloorFrame, t: CGAffineTransform, k: CGFloat) {
        guard let label = space.label else { return }
        let box = space.bounds
        let width = (frame.rotated ? box.height : box.width) * k - 4
        let height = (frame.rotated ? box.width : box.height) * k - 2
        guard width > 0, height > 0 else { return }
        let on = space.id == selectedID
        let color: Color = on ? .white : space.isRoom ? Theme.Colors.label : Theme.Colors.secondaryLabel
        let weight: Font.Weight = on || space.code != nil ? .semibold : .regular

        func layout(_ text: String, _ size: CGFloat) -> GraphicsContext.ResolvedText {
            context.resolve(
                Text(text).font(.system(size: size, weight: weight)).foregroundStyle(color)
            )
        }
        func fits(_ measured: CGSize) -> Bool {
            measured.width <= width && measured.height <= height
        }

        var shown: (text: GraphicsContext.ResolvedText, size: CGSize)?
        let options = [label] + (space.shortCode.map { [$0] } ?? [])
        for (index, text) in options.enumerated() {
            let resolved = layout(text, fontSize)
            let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
            if fits(measured) {
                shown = (resolved, measured)
                break
            }
            let shrink = min(width / measured.width, height / measured.height)
            if index == options.count - 1, fontSize * shrink >= 7 {
                let small = layout(text, fontSize * shrink * 0.98)
                let size = small.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
                if fits(size) { shown = (small, size) }
            }
        }
        if shown == nil, space.code == nil {
            var size = fontSize
            while size >= 7 {
                let resolved = context.resolve(
                    Text(label).font(.system(size: size, weight: weight)).foregroundStyle(color)
                )
                let line = layout("字", size).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).height
                let measured = resolved.measure(in: CGSize(width: width, height: .infinity))
                if fits(measured), measured.height <= line * 3.2 {
                    shown = (resolved, measured)
                    break
                }
                size *= 0.9
            }
        }
        guard let shown else { return }
        let centre = box.center.applying(t)
        context.draw(
            shown.text,
            in: CGRect(
                x: centre.x - shown.size.width / 2, y: centre.y - shown.size.height / 2,
                width: shown.size.width, height: shown.size.height
            )
        )
    }

    // MARK: Links

    /// 「往…」膠囊，箭頭指向另一棟大樓；膠囊留在樓內，箭頭尖端在門口。
    /// 穿過南北牆的連通口改成直式一字一行，放得進窄走廊。
    private func drawLink(_ link: MapLink, in context: GraphicsContext, frame: FloorFrame, t: CGAffineTransform) {
        var d = link.toward
        if frame.rotated { d = CGPoint(x: -d.y, y: d.x) }
        let length = max(hypot(d.x, d.y), 0.001)
        d = CGPoint(x: d.x / length, y: d.y / length)
        let upright = abs(d.y) > abs(d.x)
        let label = "往\(link.name)"
        let text = context.resolve(
            Text(upright ? label.map(String.init).joined(separator: "\n") : label)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(Color.indigo)
        )
        let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
        let arrow: CGFloat = 10, pad: CGFloat = 6, gap: CGFloat = 4
        let w = upright ? max(measured.width, arrow) + pad : measured.width + arrow + gap + pad * 2
        let h = upright ? measured.height + arrow + gap + pad * 2 : max(measured.height, arrow) + pad
        let at = link.at.applying(t)
        let centre = CGPoint(x: at.x - d.x * w / 2, y: at.y - d.y * h / 2)
        let pill = CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
        context.fill(Path(roundedRect: pill, cornerRadius: min(w, h) / 2), with: .color(Color.indigo.opacity(0.15)))
        // 文字在遠離門口的一端，箭頭在門口。
        let towards = upright ? d.y > 0 : d.x > 0
        let textAt: CGPoint, arrowAt: CGPoint
        if upright {
            textAt = CGPoint(x: centre.x, y: towards ? pill.minY + pad + measured.height / 2 : pill.maxY - pad - measured.height / 2)
            arrowAt = CGPoint(x: centre.x, y: towards ? pill.maxY - pad - arrow / 2 : pill.minY + pad + arrow / 2)
        } else {
            textAt = CGPoint(x: towards ? pill.minX + pad + measured.width / 2 : pill.maxX - pad - measured.width / 2, y: centre.y)
            arrowAt = CGPoint(x: towards ? pill.maxX - pad - arrow / 2 : pill.minX + pad + arrow / 2, y: centre.y)
        }
        context.draw(text, at: textAt)
        let tip = CGPoint(x: arrowAt.x + d.x * arrow / 2, y: arrowAt.y + d.y * arrow / 2)
        let back = CGPoint(x: tip.x - d.x * arrow, y: tip.y - d.y * arrow)
        let side = CGPoint(x: -d.y * arrow * 0.45, y: d.x * arrow * 0.45)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: back.x + side.x, y: back.y + side.y))
        head.addLine(to: CGPoint(x: back.x - side.x, y: back.y - side.y))
        head.closeSubpath()
        context.fill(head, with: .color(Color.indigo))
    }

    private enum Palette {
        static let surface = Color(.secondarySystemGroupedBackground)
        static let fillStrong = Color(.systemGray5)
        static let restroom = Color.teal.opacity(0.16)
        static let restroomEdge = Color.teal.opacity(0.3)
        static let terrace = Color.green.opacity(0.14)
    }
}

extension Path {
    init(polygon points: [CGPoint]) {
        self.init()
        guard !points.isEmpty else { return }
        addLines(points)
        closeSubpath()
    }
}
