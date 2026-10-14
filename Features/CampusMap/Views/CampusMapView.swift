import SwiftUI

/// 全校總覽地圖；有樓層平面圖的建築可以進入平面圖。
struct CampusMapView: View {
    @StateObject private var model = CampusMapViewModel()
    /// 以清單取代地圖；下次開啟時沿用。
    @AppStorage("campusMap.listed") private var listed = false
    @State private var zoom = MapZoom.identity
    @State private var mapSize: CGSize = .zero
    @State private var pendingFocus: Int?
    @State private var plan: CampusPlanRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let padding = EdgeInsets(top: 16, leading: 16, bottom: 88, trailing: 16)

    var body: some View {
        content
            .background(Theme.Colors.groupedBackground.ignoresSafeArea())
            .navigationTitle("校園地圖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        listed.toggle()
                        if listed { model.select(nil) }
                    } label: {
                        Image(systemName: listed ? "map" : "list.bullet")
                    }
                    .accessibilityLabel(listed ? "以地圖顯示" : "以清單顯示")
                }
            }
            .searchable(
                text: $model.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜尋建築、教室，例如 教305"
            )
            .navigationDestination(item: $plan) { request in
                BuildingMapView(buildingID: request.building, room: request.room)
            }
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("校園地圖載入失敗", systemImage: "map")
        case .loaded(let data):
            if model.isSearching {
                CampusMapSearchResults(model: model) { building in
                    listed = false
                    focusSoon(building)
                } openRoom: { room in
                    plan = CampusPlanRequest(building: room.building.id, room: room.space.label)
                }
            } else if listed {
                buildingList(data)
            } else {
                map(data)
            }
        }
    }

    // MARK: Map

    private func map(_ data: CampusMapData) -> some View {
        ZoomableMap(zoom: $zoom, minScale: 1, maxScale: 12, margin: 0) { metres in
            let frame = OverviewFrame(campus: data.overview.campus, size: mapSize, padding: padding)
            model.tap(data.overview.buildingAt(frame.toMetres(metres)))
        } content: { zoom in
            CampusOverviewCanvas(map: data.overview, selectedID: model.selectedID, padding: padding, zoom: zoom)
        }
        .accessibilityElement()
        .accessibilityLabel("國立宜蘭大學校園地圖")
        .accessibilityHint("可切換為清單顯示，逐一瀏覽建築")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            mapSize = size
            if let id = pendingFocus, let building = data.overview.building(id: id) {
                pendingFocus = nil
                focus(building, in: data)
            }
        }
        .overlay(alignment: .bottom) {
            Group {
                if let building = model.selected {
                    CampusBuildingCard(
                        building: building,
                        levels: data.levels(of: building),
                        onClose: { model.select(nil) },
                        onPlan: building.plan.map { id in { plan = CampusPlanRequest(building: id) } }
                    )
                    .id(building.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HStack(alignment: .bottom) {
                        Spacer()
                        VStack(alignment: .trailing, spacing: Theme.Spacing.xxsmall) {
                            MapFitButton(label: "顯示整個校園") { fly(.identity) }
                            Text(data.overview.attribution)
                                .font(.caption2)
                                .foregroundStyle(Theme.Colors.secondaryLabel)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.bottom, Theme.Spacing.small)
            .animation(reduceMotion ? nil : Theme.Animation.standard, value: model.selectedID)
        }
    }

    /// 地圖還沒排版（例如從清單切回）時，等尺寸確定再對準。
    private func focusSoon(_ building: CampusOverviewBuilding) {
        model.select(building)
        if !listed, mapSize != .zero, let data = model.data {
            focus(building, in: data)
        } else {
            pendingFocus = building.id
        }
    }

    /// 把建築置中，放大到輪廓夠清楚。
    private func focus(_ building: CampusOverviewBuilding, in data: CampusMapData) {
        let frame = OverviewFrame(campus: data.overview.campus, size: mapSize, padding: padding)
        let area = frame.area
        let size = building.bounds.longestSide * frame.scale
        let scale = min(max(area.shortestSide * 0.45 / max(size, 1), 1), 6)
        fly(MapZoom.centring(frame.toCanvas(building.centre), at: area.center, scale: scale)
            .clamped(to: mapSize, margin: 0))
    }

    private func fly(_ target: MapZoom) {
        if reduceMotion {
            zoom = target
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { zoom = target }
        }
    }

    // MARK: List

    private func buildingList(_ data: CampusMapData) -> some View {
        let named = data.overview.listedBuildings
        let planned = named.filter { $0.plan != nil }
        let others = named.filter { $0.plan == nil }
        return List {
            if !planned.isEmpty {
                Section("有樓層平面圖") {
                    ForEach(planned) { row($0, data: data) }
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { row($0, data: data) }
                } header: {
                    Text("其他建築")
                } footer: {
                    Text(data.overview.attribution)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.small)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ building: CampusOverviewBuilding, data: CampusMapData) -> some View {
        Button {
            if let id = building.plan {
                plan = CampusPlanRequest(building: id)
            } else {
                listed = false
                focusSoon(building)
            }
        } label: {
            CampusBuildingRow(
                name: building.name ?? "未命名建築",
                subtitle: data.levels(of: building),
                hasPlan: building.plan != nil
            )
        }
        .accessibilityHint(building.plan != nil ? "開啟樓層平面圖" : "在地圖上顯示位置")
    }
}

// MARK: - Components

struct CampusBuildingRow: View {
    let name: String
    let subtitle: String?
    let hasPlan: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "building.2.fill")
                .font(.body)
                .foregroundStyle(hasPlan ? Color.indigo : Theme.Colors.secondaryLabel)
                .frame(width: 32, height: 32)
                .background(
                    (hasPlan ? Color.indigo : Color.gray).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.xsmall, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(Theme.Colors.label)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.tertiaryLabel)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct CampusBuildingCard: View {
    let building: CampusOverviewBuilding
    let levels: String?
    let onClose: () -> Void
    let onPlan: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(onPlan != nil ? Color.indigo : Theme.Colors.secondaryLabel)
                    .frame(width: 36, height: 36)
                    .background(
                        (onPlan != nil ? Color.indigo : Color.gray).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(building.name ?? "未命名建築")
                        .font(.headline)
                        .foregroundStyle(Theme.Colors.label)
                    Text([levels, onPlan == nil ? "尚無樓層平面圖" : "有樓層平面圖"].compactMap { $0 }.joined(separator: "・"))
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                        .frame(width: 30, height: 30)
                        .background(Theme.Colors.tertiaryFill, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉")
            }
            if let onPlan {
                Button(action: onPlan) {
                    Label("查看樓層平面圖", systemImage: "square.3.layers.3d")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Theme.CornerRadius.medium))
            }
        }
        .padding(Theme.Spacing.medium)
        .mapFloating(cornerRadius: Theme.CornerRadius.large)
    }
}

/// 建築與教室的搜尋結果。
private struct CampusMapSearchResults: View {
    @ObservedObject var model: CampusMapViewModel
    let showBuilding: (CampusOverviewBuilding) -> Void
    let openRoom: (CampusRoomLocation) -> Void

    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        let buildings = model.buildingResults
        let rooms = model.roomResults
        if buildings.isEmpty && rooms.isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else {
            List {
                if !buildings.isEmpty {
                    Section("建築") {
                        ForEach(buildings) { building in
                            Button {
                                model.query = ""
                                dismissSearch()
                                showBuilding(building)
                            } label: {
                                CampusBuildingRow(
                                    name: building.name ?? "未命名建築",
                                    subtitle: model.data?.levels(of: building),
                                    hasPlan: building.plan != nil
                                )
                            }
                            .accessibilityHint("在地圖上顯示位置")
                        }
                    }
                }
                if !rooms.isEmpty {
                    Section("教室") {
                        ForEach(rooms) { room in
                            Button {
                                openRoom(room)
                            } label: {
                                CampusRoomRow(
                                    title: room.space.label ?? "",
                                    subtitle: (["\(room.building.name) \(room.floor.title)"] + room.space.details)
                                        .joined(separator: "・")
                                )
                            }
                            .accessibilityHint("在樓層平面圖上標示")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
        }
    }
}

struct CampusRoomRow: View {
    let title: String
    let subtitle: String?
    var marked = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.Colors.label)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                }
            }
            Spacer(minLength: 0)
            if marked {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.accent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(marked ? .isSelected : [])
    }
}

#Preview {
    NavigationStack {
        CampusMapView()
    }
}
