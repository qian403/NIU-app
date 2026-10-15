import SwiftUI

/// 一棟大樓一次一層：平面圖填滿畫面，樓層選單浮在右上，底部抽屜列出本層教室。
struct BuildingMapView: View {
    @StateObject private var model: BuildingMapViewModel
    @State private var zoom = MapZoom.identity
    @State private var mapSize: CGSize = .zero
    @State private var drawerOpen = false
    @State private var searching = false
    /// 最後對準的房間；畫面尺寸改變（旋轉）時重新對準，使用者手動操作後清除。
    @State private var aimed: MapSpace?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var peek: CGFloat = 96

    init(buildingID: String, room: String? = nil) {
        _model = StateObject(wrappedValue: BuildingMapViewModel(buildingID: buildingID, room: room))
    }

    private var padding: EdgeInsets {
        EdgeInsets(top: 68, leading: 20, bottom: peek + 20, trailing: 20)
    }

    var body: some View {
        content
            .background(Theme.Colors.groupedBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if let building = model.building {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text(building.name)
                                .font(.headline)
                            Text(building.levels)
                                .font(.caption2)
                                .foregroundStyle(Theme.Colors.secondaryLabel)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            searching = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("搜尋教室")
                    }
                }
            }
            .navigationTitle(model.building?.name ?? "校園地圖")
            .sheet(isPresented: $searching) {
                if let building = model.building {
                    BuildingRoomSearch(building: building, search: model.search) { found in
                        searching = false
                        drawerOpen = false
                        model.selectFloor(found.floor.id, room: found.space)
                        focus(found.space)
                    }
                }
            }
            .task {
                if let room = await model.load() {
                    focus(room)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("校園地圖載入失敗", systemImage: "map")
        case .loaded:
            if let building = model.building, let floor = model.floor {
                plan(building, floor)
            } else {
                ContentUnavailableView("找不到這棟大樓", systemImage: "building.2")
            }
        }
    }

    private func plan(_ building: MapBuilding, _ floor: MapFloor) -> some View {
        ZoomableMap(zoom: $zoom, minScale: 1, maxScale: 6, margin: 0) {
            aimed = nil
        } onTap: { canvas in
            let frame = FloorFrame(bounds: building.bounds, floor: floor.bounds, size: mapSize, padding: padding)
            model.tap(floor.roomAt(frame.toMetres(canvas)))
        } content: { zoom in
            FloorMapCanvas(building: building, floor: floor, selectedID: model.selectedID, padding: padding, zoom: zoom)
        }
        .accessibilityElement()
        .accessibilityLabel("\(building.name)\(floor.title)平面圖")
        .accessibilityHint("本層教室列在下方清單")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            mapSize = size
            if let aimed { focus(aimed, animated: false) }
        }
        // 鍵盤收起時不改變平面圖的框，已對準的教室才不會偏掉。
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .topTrailing) {
            FloorPicker(floors: building.floors, selectedID: floor.id) { id in
                guard id != floor.id else { return }
                model.selectFloor(id)
                fly(.identity)
            }
            .padding(Theme.Spacing.small)
        }
        .overlay(alignment: .bottomTrailing) {
            MapFitButton(label: "顯示整層") { fly(.identity) }
                .padding(.trailing, Theme.Spacing.small)
                .padding(.bottom, peek + Theme.Spacing.small)
        }
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                FloorDrawer(
                    floor: floor,
                    selected: model.selected,
                    open: $drawerOpen,
                    peek: peek,
                    maxHeight: proxy.size.height * 0.6,
                    onClear: { model.select(nil) },
                    onPick: { room in
                        drawerOpen = false
                        model.select(room)
                        focus(room)
                    }
                )
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    /// 把房間置中於可見區域並放大 2.4 倍。
    private func focus(_ space: MapSpace, animated: Bool = true) {
        guard mapSize != .zero, let building = model.building else {
            aimed = space
            return
        }
        let frame = FloorFrame(bounds: building.bounds, floor: model.floor?.bounds, size: mapSize, padding: padding)
        let target = MapZoom.centring(frame.toCanvas(space.bounds.center), at: frame.area.center, scale: 2.4)
            .clamped(to: mapSize, margin: 0)
        if animated { fly(target) } else { zoom = target }
        aimed = space
    }

    private func fly(_ target: MapZoom) {
        aimed = nil
        if reduceMotion {
            zoom = target
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { zoom = target }
        }
    }
}

// MARK: - Floor picker

/// 平常只顯示目前樓層，點開列出全部樓層（高樓層在上）。
private struct FloorPicker: View {
    let floors: [MapFloor]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            Picker("樓層", selection: Binding(get: { selectedID }, set: onSelect)) {
                ForEach(floors.reversed()) { floor in
                    Text(floor.title).tag(floor.id)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(selectedID)
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.label)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.Colors.secondaryLabel)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(minWidth: 44, minHeight: 44)
            .mapFloating()
        }
        .accessibilityLabel("樓層，目前\(floors.first { $0.id == selectedID }?.title ?? selectedID)")
    }
}

// MARK: - Drawer

/// 收起時顯示樓層摘要或標示中的教室，往上拉列出本層有編號的教室。
private struct FloorDrawer: View {
    let floor: MapFloor
    let selected: MapSpace?
    @Binding var open: Bool
    let peek: CGFloat
    let maxHeight: CGFloat
    let onClear: () -> Void
    let onPick: (MapSpace) -> Void

    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var numbered: [MapSpace] {
        floor.rooms.filter { $0.label != nil }.sorted { $0.label! < $1.label! }
    }

    private var height: CGFloat {
        let base = open ? max(maxHeight, peek) : peek
        return min(max(base - drag, peek), max(maxHeight, peek))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if height > peek + 1 {
                list
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Theme.CornerRadius.xlarge, topTrailingRadius: Theme.CornerRadius.xlarge,
                                   style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.1), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(reduceMotion ? nil : Theme.Animation.standard, value: open)
    }

    private var header: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.vertical, Theme.Spacing.xsmall)
                .accessibilityHidden(true)
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: selected == nil ? "square.3.layers.3d" : "door.left.hand.open")
                    .foregroundStyle(selected == nil ? Color.indigo : Color.blue)
                    .frame(width: 36, height: 36)
                    .background(
                        (selected == nil ? Color.indigo : Color.blue).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.map { $0.label ?? "未編號空間" } ?? floor.title)
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.label)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if selected != nil {
                    Button(action: onClear) {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                            .frame(width: 30, height: 30)
                            .background(Theme.Colors.tertiaryFill, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消標示")
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.bottom, Theme.Spacing.xsmall)
        }
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
        // 標題列直接改變抽屜高度，不受清單捲動位置影響。標題列會跟著抽屜移動，
        // 以全域座標量拖曳距離，才不會因自身位移而來回抖動。
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    let velocity = value.predictedEndTranslation.height - value.translation.height
                    let current = height
                    // 開關狀態沒變時也要滑回定位，不直接跳回去。
                    withAnimation(reduceMotion ? nil : Theme.Animation.standard) {
                        drag = 0
                        if abs(velocity) > 120 {
                            open = velocity < 0
                        } else {
                            open = current > (peek + maxHeight) / 2
                        }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: open ? "收起本層教室" : "展開本層教室") { open.toggle() }
    }

    private var subtitle: String? {
        if let selected {
            return ([floor.title] + selected.details + [floor.zone(of: selected)?.description].compactMap { $0 })
                .joined(separator: "・")
        }
        return floor.unit
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text("本層教室")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                    .accessibilityAddTraits(.isHeader)
                if numbered.isEmpty {
                    Text("這一層還沒有教室編號。")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(numbered) { room in
                            Button {
                                onPick(room)
                            } label: {
                                CampusRoomRow(
                                    title: room.label ?? "",
                                    subtitle: room.details.joined(separator: "・"),
                                    marked: room.id == selected?.id
                                )
                                .padding(.horizontal, Theme.Spacing.medium)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("在平面圖上標示")
                            if room.id != numbered.last?.id {
                                Divider().padding(.leading, Theme.Spacing.medium)
                            }
                        }
                    }
                    .background(Theme.Colors.groupedBackground,
                                in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.top, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.large)
        }
    }
}

// MARK: - Room search

private struct BuildingRoomSearch: View {
    let building: MapBuilding
    let search: (String) -> [CampusRoomLocation]
    let onPick: (CampusRoomLocation) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let results = Array(search(query).prefix(30))
        NavigationStack {
            Group {
                if CampusMapText.normalize(query).isEmpty {
                    ContentUnavailableView(
                        "搜尋教室",
                        systemImage: "magnifyingglass",
                        description: Text("輸入教室號碼、名稱或系所，例如 305。")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        Button {
                            onPick(result)
                        } label: {
                            CampusRoomRow(
                                title: result.space.label ?? "",
                                subtitle: ([result.floor.title] + result.space.details).joined(separator: "・")
                            )
                        }
                        .accessibilityHint("在平面圖上標示")
                    }
                    .listStyle(.insetGrouped)
                    .scrollDismissesKeyboard(.immediately)
                }
            }
            .navigationTitle("搜尋\(building.name)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜尋\(building.name)的教室"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        BuildingMapView(buildingID: "jiaose", room: "教305")
    }
}
