import SwiftUI

/// 地圖的縮放與平移：畫面座標 = 畫布座標 × scale + offset。
struct MapZoom: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let identity = MapZoom()

    func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    func toCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    var transform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset.width, ty: offset.height)
    }

    /// 把畫布上的 `point` 放大 `scale` 倍後移到畫面的 `target`。
    static func centring(_ point: CGPoint, at target: CGPoint, scale: CGFloat) -> MapZoom {
        MapZoom(scale: scale, offset: CGSize(width: target.x - point.x * scale, height: target.y - point.y * scale))
    }

    /// 讓畫布（含 `margin` 留白）不會被拖離畫面。
    func clamped(to size: CGSize, margin: CGFloat) -> MapZoom {
        func axis(_ offset: CGFloat, _ length: CGFloat) -> CGFloat {
            let low = length - (length + margin) * scale
            let high = margin * scale
            return low <= high ? min(max(offset, low), high) : (low + high) / 2
        }
        return MapZoom(scale: scale, offset: CGSize(width: axis(offset.width, size.width), height: axis(offset.height, size.height)))
    }
}

/// 可雙指縮放、拖曳與點選的地圖。`zoom` 用動畫改變時，畫布會逐格重畫。
struct ZoomableMap<Content: View>: View {
    @Binding var zoom: MapZoom
    let minScale: CGFloat
    let maxScale: CGFloat
    /// 畫布四周可拖出的留白，單位為畫布座標。
    let margin: CGFloat
    var onInteraction: () -> Void = {}
    /// 點選位置，已換成未縮放的畫布座標。
    let onTap: (CGPoint) -> Void
    @ViewBuilder let content: (MapZoom) -> Content

    @State private var size: CGSize = .zero
    @State private var lastTranslation: CGSize?
    @State private var lastMagnification: CGFloat?

    var body: some View {
        AnimatedZoom(zoom: zoom, content: content)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    onTap(zoom.toCanvas(value.location))
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let last = lastTranslation ?? .zero
                        if lastTranslation == nil { onInteraction() }
                        lastTranslation = value.translation
                        var next = zoom
                        next.offset.width += value.translation.width - last.width
                        next.offset.height += value.translation.height - last.height
                        apply(next)
                    }
                    .onEnded { _ in lastTranslation = nil }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { value in
                            let last = lastMagnification ?? 1
                            if lastMagnification == nil { onInteraction() }
                            lastMagnification = value.magnification
                            let scale = min(max(zoom.scale * value.magnification / last, minScale), maxScale)
                            let anchor = value.startLocation
                            let factor = scale / zoom.scale
                            apply(MapZoom(
                                scale: scale,
                                offset: CGSize(
                                    width: anchor.x - (anchor.x - zoom.offset.width) * factor,
                                    height: anchor.y - (anchor.y - zoom.offset.height) * factor
                                )
                            ))
                        }
                        .onEnded { _ in lastMagnification = nil }
                    )
            )
    }

    private func apply(_ next: MapZoom) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            zoom = next.clamped(to: size, margin: margin)
        }
    }
}

/// 讓 SwiftUI 在動畫中插值縮放值，Canvas 才會跟著逐格重畫。
private struct AnimatedZoom<Content: View>: View, Animatable {
    var zoom: MapZoom
    let content: (MapZoom) -> Content

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(zoom.scale, AnimatablePair(zoom.offset.width, zoom.offset.height)) }
        set {
            zoom = MapZoom(scale: newValue.first, offset: CGSize(width: newValue.second.first, height: newValue.second.second))
        }
    }

    var body: some View {
        content(zoom)
    }
}

/// 浮在地圖上的圓角控制項底。
struct MapFloatingBackground: ViewModifier {
    var cornerRadius: CGFloat = Theme.CornerRadius.pill

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

extension View {
    func mapFloating(cornerRadius: CGFloat = Theme.CornerRadius.pill) -> some View {
        modifier(MapFloatingBackground(cornerRadius: cornerRadius))
    }
}

/// 地圖右下角的「顯示整個範圍」按鈕。
struct MapFitButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.Colors.label)
                .frame(width: 44, height: 44)
                .mapFloating()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
