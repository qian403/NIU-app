import Combine
import Foundation

@MainActor
final class CampusBuildingsViewModel: ObservableObject {
    let buildings: [CampusBuilding]

    @Published private(set) var selectedBuildingID: String
    @Published private(set) var selectedFloorID: String
    @Published private(set) var highlightedSpaceID: String?

    init() {
        let buildings = CampusBuildingCatalog.buildings
        self.buildings = buildings
        let first = buildings.first
        selectedBuildingID = first?.id ?? ""
        selectedFloorID = first?.defaultFloorID ?? ""
    }

    var building: CampusBuilding? {
        buildings.first { $0.id == selectedBuildingID }
    }

    var floor: BuildingFloor? {
        building?.floor(id: selectedFloorID)
    }

    func selectBuilding(_ id: String) {
        guard id != selectedBuildingID, let building = buildings.first(where: { $0.id == id }) else { return }
        selectedBuildingID = id
        selectedFloorID = building.defaultFloorID
        highlightedSpaceID = nil
    }

    func selectFloor(_ id: String) {
        guard id != selectedFloorID else { return }
        selectedFloorID = id
        highlightedSpaceID = nil
    }

    func toggleHighlight(_ space: FloorSpace) {
        guard space.isRoom else { return }
        highlightedSpaceID = highlightedSpaceID == space.id ? nil : space.id
    }
}
