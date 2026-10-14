import Combine
import Foundation

enum CampusMapLoadState {
    case loading
    case loaded(CampusMapData)
    case failed
}

/// 開啟某棟大樓的平面圖，可附上要標示的教室。
struct CampusPlanRequest: Hashable, Identifiable {
    let building: String
    var room: String?

    var id: String { "\(building)/\(room ?? "")" }
}

@MainActor
final class CampusMapViewModel: ObservableObject {
    @Published private(set) var state: CampusMapLoadState = .loading
    @Published private(set) var selectedID: Int?
    @Published var query = ""

    var data: CampusMapData? {
        if case .loaded(let data) = state { return data }
        return nil
    }

    var selected: CampusOverviewBuilding? {
        selectedID.flatMap { data?.overview.building(id: $0) }
    }

    var isSearching: Bool { !CampusMapText.normalize(query).isEmpty }

    var buildingResults: [CampusOverviewBuilding] {
        data?.overview.searchBuildings(query) ?? []
    }

    var roomResults: [CampusRoomLocation] {
        Array((data?.plans.search(query) ?? []).prefix(30))
    }

    func load() async {
        guard data == nil else { return }
        state = .loading
        do {
            state = .loaded(try await CampusMapLoader.shared.load())
        } catch {
            state = .failed
        }
    }

    func select(_ building: CampusOverviewBuilding?) {
        selectedID = building?.id
    }

    /// 點到同一棟取消選取。
    func tap(_ building: CampusOverviewBuilding?) {
        selectedID = building?.id == selectedID ? nil : building?.id
    }
}

@MainActor
final class BuildingMapViewModel: ObservableObject {
    @Published private(set) var state: CampusMapLoadState = .loading
    @Published private(set) var floorID = ""
    @Published private(set) var selectedID: String?

    let buildingID: String
    private let initialRoom: String?

    init(buildingID: String, room: String?) {
        self.buildingID = buildingID
        initialRoom = room
    }

    var building: MapBuilding? {
        if case .loaded(let data) = state { return data.plans.building(id: buildingID) }
        return nil
    }

    var plans: CampusFloorPlans? {
        if case .loaded(let data) = state { return data.plans }
        return nil
    }

    var floor: MapFloor? { building?.floor(id: floorID) }

    var selected: MapSpace? {
        selectedID.flatMap { floor?.space(id: $0) }
    }

    /// 載入後若有指定教室，回傳該教室供畫面對準。
    func load() async -> MapSpace? {
        guard building == nil else { return nil }
        do {
            let data = try await CampusMapLoader.shared.load()
            state = .loaded(data)
        } catch {
            state = .failed
            return nil
        }
        guard let building else { return nil }
        if let room = initialRoom, let found = plans?.locate(room), found.building.id == building.id {
            floorID = found.floor.id
            selectedID = found.space.id
            return found.space
        }
        floorID = building.defaultFloorID
        return nil
    }

    func selectFloor(_ id: String, room: MapSpace? = nil) {
        floorID = id
        selectedID = room?.id
    }

    func select(_ room: MapSpace?) {
        selectedID = room?.id
    }

    /// 點到同一間取消標示。
    func tap(_ room: MapSpace?) {
        selectedID = room?.id == selectedID ? nil : room?.id
    }

    func search(_ query: String) -> [CampusRoomLocation] {
        (plans?.search(query) ?? []).filter { $0.building.id == buildingID }
    }
}
