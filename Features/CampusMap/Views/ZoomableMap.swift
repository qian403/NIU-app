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

/// 可雙指縮放、拖曳與點選的地圖。手勢交給原生 UIScrollView（縮放跟著手指、拖曳有慣性與回彈），
/// 畫布再依 `zoom` 重畫，字級不會跟著放大變糊；`zoom` 用動畫改變時，畫布會逐格重畫。
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

    var body: some View {
        AnimatedZoom(zoom: zoom, content: content)
            .overlay {
                MapGestureSurface(
                    zoom: $zoom, minScale: minScale, maxScale: maxScale, margin: margin,
                    onInteraction: onInteraction, onTap: onTap
                )
            }
    }
}

/// 透明的 UIScrollView，只負責手勢；內容視圖大小等於畫布，縮放倍率與捲動位置換算成 `MapZoom`。
private struct MapGestureSurface: UIViewRepresentable {
    @Binding var zoom: MapZoom
    let minScale: CGFloat
    let maxScale: CGFloat
    let margin: CGFloat
    let onInteraction: () -> Void
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MapScrollView {
        let view = MapScrollView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.decelerationRate = .normal
        view.bouncesZoom = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = true
        view.canvas.backgroundColor = .clear
        view.addSubview(view.canvas)
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layout() }

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: MapScrollView, context: Context) {
        context.coordinator.parent = self
        view.minimumZoomScale = minScale
        view.maximumZoomScale = maxScale
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: MapGestureSurface
        weak var view: MapScrollView?
        /// 程式設定縮放／位置時不回寫 `zoom`。
        private var applying = false

        init(_ parent: MapGestureSurface) {
            self.parent = parent
        }

        private var interacting: Bool {
            guard let view else { return false }
            return view.isTracking || view.isDragging || view.isDecelerating || view.isZooming || view.isZoomBouncing
        }

        /// 尺寸改變時重設內容大小，再套用目前的 `zoom`。
        func layout() {
            guard let view, view.bounds.size != .zero else { return }
            if view.canvas.bounds.size != view.bounds.size {
                applying = true
                let scale = view.zoomScale
                view.zoomScale = 1
                view.canvas.frame = CGRect(origin: .zero, size: view.bounds.size)
                view.contentSize = view.bounds.size
                view.zoomScale = scale
                applying = false
            }
            sync()
        }

        /// 把 `zoom` 套到捲動視圖；使用者正在操作時以手勢為準。
        func sync() {
            guard let view, view.bounds.size != .zero, !interacting else { return }
            let zoom = parent.zoom
            let offset = CGPoint(x: -zoom.offset.width, y: -zoom.offset.height)
            guard abs(view.zoomScale - zoom.scale) > 0.0001
                    || abs(view.contentOffset.x - offset.x) > 0.5
                    || abs(view.contentOffset.y - offset.y) > 0.5
            else { return }
            applying = true
            view.zoomScale = min(max(zoom.scale, view.minimumZoomScale), view.maximumZoomScale)
            updateInsets()
            view.contentOffset = offset
            applying = false
        }

        /// 留白隨縮放倍率等比例，與 `MapZoom.clamped` 的範圍一致。
        private func updateInsets() {
            guard let view else { return }
            let m = parent.margin * view.zoomScale
            let size = view.bounds.size
            let content = CGSize(width: size.width * view.zoomScale, height: size.height * view.zoomScale)
            let h = max(m, (size.width - content.width) / 2)
            let v = max(m, (size.height - content.height) / 2)
            view.contentInset = UIEdgeInsets(top: v, left: h, bottom: v, right: h)
        }

        private func publish() {
            guard let view, !applying else { return }
            let next = MapZoom(
                scale: view.zoomScale,
                offset: CGSize(width: -view.contentOffset.x, height: -view.contentOffset.y)
            )
            guard next != parent.zoom else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { parent.zoom = next }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.canvas }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.onInteraction() }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { parent.onInteraction() }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { publish() }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if !applying { updateInsets() }
            publish()
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            parent.onTap(recognizer.location(in: view.canvas))
        }

        /// 雙擊放大兩倍；已放到最大時恢復原狀。
        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            parent.onInteraction()
            let point = recognizer.location(in: view.canvas)
            if view.zoomScale * 2 > view.maximumZoomScale + 0.001 {
                view.setZoomScale(max(1, view.minimumZoomScale), animated: true)
            } else {
                let scale = view.zoomScale * 2
                let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }
    }
}

final class MapScrollView: UIScrollView {
    let canvas = UIView()
    var onLayout: () -> Void = {}

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout()
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
