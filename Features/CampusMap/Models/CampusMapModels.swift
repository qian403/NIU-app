import CoreGraphics
import Foundation

// 校園地圖資料與 Android 版共用：來源是 windlessme/niu-app-android 的
// app-content/campus-map，以 scripts/sync-campus-map.py 複製到 Resources/CampusMap。
// 座標單位為公尺，x 向東、y 向南。

// MARK: - Floor plans

nonisolated enum MapSpaceKind: Sendable {
    case room, corridor, stairs, elevator, restroom, shaft, terrace

    init(json value: String) {
        switch value {
        case "room": self = .room
        case "stairs": self = .stairs
        case "elevator": self = .elevator
        case "restroom": self = .restroom
        case "void": self = .shaft
        case "terrace": self = .terrace
        default: self = .corridor
        }
    }
}

/// 平面圖上的一個空間；`code` 與校方教室代碼一致，例如 教305。
nonisolated struct MapSpace: Identifiable, Hashable, Sendable {
    let id: String
    let kind: MapSpaceKind
    let points: [CGPoint]
    let isRect: Bool
    let code: String?
    /// 告示上的名稱，例如 薄膜實驗室、男廁。
    let name: String?
    let note: String?
    /// 校方也在用的其他代碼（告示上的 E505、格101）：可搜尋、課表比對，不顯示。
    let aka: [String]
    let bounds: CGRect

    var isRoom: Bool { kind == .room }

    /// 有代碼用代碼，否則用名稱；清單與卡片以此為標題。
    var label: String? { code ?? name }

    /// 去掉大樓字的代碼（教305 → 305）；E、格開頭的代碼保留原樣，回傳 nil。
    var shortCode: String? {
        guard let code, let first = code.unicodeScalars.first,
              first.value >= 0x2E80, !code.hasPrefix("格") else { return nil }
        return String(code.dropFirst())
    }

    /// 課表或搜尋可能用來稱呼這間教室的所有名稱。
    var names: [String] { (label.map { [$0] } ?? []) + aka }

    /// 代碼之下的名稱與備註，或名稱之下的備註。
    var details: [String] {
        [code != nil ? name : nil, note].compactMap { $0 }
    }
}

/// 往另一棟大樓的連通口。
nonisolated struct MapLink: Hashable, Sendable {
    let to: String
    let name: String
    let at: CGPoint
    let toward: CGPoint
}

nonisolated struct MapFloor: Identifiable, Hashable, Sendable {
    let id: String
    let outline: [CGPoint]
    /// 分成幾塊的樓層（綜合教學大樓兩翼）的每一環；整層一塊時只有 `outline`。
    let outlines: [[CGPoint]]
    let spaces: [MapSpace]
    let links: [MapLink]
    /// 樓層所屬單位，例如 環境工程學系，以及常用簡稱。
    let unit: String?
    let aliases: [String]
    let bounds: CGRect

    var rooms: [MapSpace] { spaces.filter(\.isRoom) }

    /// "B1" → 地下 1 樓，"3F" → 3 樓。
    var title: String {
        id.hasPrefix("B") ? "地下 \(id.dropFirst()) 樓" : "\(id.dropLast()) 樓"
    }

    func space(id: String) -> MapSpace? {
        spaces.first { $0.id == id }
    }

    /// `query`（已正規化）是否指這層的單位：環工、機械系、化學工程。
    func namesUnit(_ query: String) -> Bool {
        guard let unit else { return false }
        return CampusMapText.normalize(unit).contains(query) || aliases.contains { alias in
            let alias = CampusMapText.normalize(alias)
            return alias.contains(query) || query.contains(alias)
        }
    }

    /// 點到的最小房間；走廊等空間不可點選。
    func roomAt(_ point: CGPoint) -> MapSpace? {
        var hit: MapSpace?
        for space in spaces where space.isRoom && space.bounds.contains(point) {
            guard polygonContains(space.points, point) else { continue }
            if hit == nil || space.bounds.shortestSide < hit!.bounds.shortestSide {
                hit = space
            }
        }
        return hit
    }
}

nonisolated struct MapBuilding: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let floors: [MapFloor]
    /// 所有樓層共用同一個範圍，切換樓層時畫面不跳動。
    let bounds: CGRect

    var defaultFloorID: String {
        floor(id: "1F")?.id ?? floors.first?.id ?? ""
    }

    func floor(id: String) -> MapFloor? {
        floors.first { $0.id == id }
    }

    /// 地上 8 層，地下 1 層。
    var levels: String {
        let below = floors.filter { $0.id.hasPrefix("B") }.count
        let above = floors.count - below
        return below == 0 ? "地上 \(above) 層" : "地上 \(above) 層，地下 \(below) 層"
    }
}

nonisolated struct CampusRoomLocation: Identifiable, Hashable, Sendable {
    let building: MapBuilding
    let floor: MapFloor
    let space: MapSpace

    var id: String { "\(building.id)/\(space.id)" }
}

/// 依各樓層逃生圖繪製的大樓平面圖。
nonisolated struct CampusFloorPlans: Sendable {
    let buildings: [MapBuilding]

    func building(id: String) -> MapBuilding? {
        buildings.first { $0.id == id }
    }

    /// 從課表的教室文字（例如「教305」或「教 305（電腦教室）」）找出教室；
    /// 忽略空白與全形，取最長的符合名稱。
    func locate(_ text: String) -> CampusRoomLocation? {
        let normalized = CampusMapText.normalize(text)
        guard !normalized.isEmpty else { return nil }
        var match: CampusRoomLocation?
        var length = 0
        for building in buildings {
            for floor in building.floors {
                for space in floor.rooms where space.label != nil {
                    for name in space.names.map(CampusMapText.normalize)
                    where name.count > length && normalized.contains(name) {
                        match = CampusRoomLocation(building: building, floor: floor, space: space)
                        length = name.count
                    }
                }
            }
        }
        return match
    }

    /// 代碼、名稱或備註含 `query` 的空間，依大樓與樓層排序；只打數字也能找代碼
    /// （305 → 教305），打系名或簡稱能找到該系辦公室（環工 → 系辦公室）。
    func search(_ query: String) -> [CampusRoomLocation] {
        let q = CampusMapText.normalize(query)
        guard !q.isEmpty else { return [] }
        func hit(_ space: MapSpace) -> Bool {
            if let code = space.code.map(CampusMapText.normalize),
               code.contains(q) || (space.shortCode.map { CampusMapText.normalize($0).hasPrefix(q) } ?? false) {
                return true
            }
            return ([space.name, space.note] + space.aka).contains { text in
                text.map { CampusMapText.normalize($0).contains(q) } ?? false
            }
        }
        return buildings.flatMap { building in
            building.floors.flatMap { floor in
                floor.rooms.compactMap { space in
                    guard space.label != nil,
                          hit(space) || (space.note != nil && space.note == floor.unit && floor.namesUnit(q))
                    else { return nil }
                    return CampusRoomLocation(building: building, floor: floor, space: space)
                }
            }
        }
    }
}

// MARK: - Campus overview

nonisolated enum CampusAreaKind: String, Sendable {
    case sport, green, water, parking
}

nonisolated enum CampusRoadKind: String, Sendable, CaseIterable {
    case street, service, path
}

/// 總覽地圖上的一棟建築；`plan` 為有樓層平面圖時的大樓 ID。
nonisolated struct CampusOverviewBuilding: Identifiable, Hashable, Sendable {
    let id: Int
    let polygon: [CGPoint]
    let onCampus: Bool
    let name: String?
    let levels: Int?
    let plan: String?
    /// 司令台等只畫在地圖上、不列在建築清單的結構物為 false。
    let listed: Bool
    let bounds: CGRect
    /// 以面積加權的中心，名稱畫在這裡。
    let centre: CGPoint
}

nonisolated struct CampusArea: Sendable {
    let kind: CampusAreaKind
    let polygon: [CGPoint]
}

nonisolated struct CampusRoad: Sendable {
    let kind: CampusRoadKind
    let line: [CGPoint]
}

/// OpenStreetMap 的校園總覽，以校園中心為原點，北朝上。
/// 依 ODbL，畫面上必須保留 `attribution`。
nonisolated struct CampusOverview: Sendable {
    let attribution: String
    let boundary: [CGPoint]
    let buildings: [CampusOverviewBuilding]
    let areas: [CampusArea]
    let roads: [CampusRoad]
    /// 初始畫面：校園加上周圍一點街道。
    let campus: CGRect

    /// 點到的建築，校內優先。
    func buildingAt(_ point: CGPoint) -> CampusOverviewBuilding? {
        var hit: CampusOverviewBuilding?
        for building in buildings where building.bounds.contains(point) && polygonContains(building.polygon, point) {
            if hit == nil || (building.onCampus && !hit!.onCampus) { hit = building }
        }
        return hit
    }

    /// 名稱含 `query` 的校內建築。
    func searchBuildings(_ query: String) -> [CampusOverviewBuilding] {
        let q = CampusMapText.normalize(query)
        guard !q.isEmpty else { return [] }
        return buildings.filter { building in
            building.onCampus && (building.name.map { CampusMapText.normalize($0).contains(q) } ?? false)
        }
    }

    func building(id: Int) -> CampusOverviewBuilding? {
        buildings.first { $0.id == id }
    }

    /// 清單用：校內、可列出且有名稱，同名只列一次，依名稱排序。
    var listedBuildings: [CampusOverviewBuilding] {
        var seen = Set<String>()
        return buildings
            .filter { $0.onCampus && $0.listed && $0.name != nil && seen.insert($0.name!).inserted }
            .sorted { $0.name! < $1.name! }
    }
}

nonisolated struct CampusMapData: Sendable {
    let overview: CampusOverview
    let plans: CampusFloorPlans

    static let planFiles = ["jiaose", "gongxue", "shixi", "dianzi", "shihua", "gezhi", "zonghe", "tuzi", "dongwu"]

    /// 讀取 App 內建的地圖資料。
    static func bundled(_ bundle: Bundle = .main) throws -> CampusMapData {
        func read(_ name: String) throws -> Data {
            guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "CampusMap") else {
                throw CampusMapError.missing(name)
            }
            return try Data(contentsOf: url)
        }
        let decoder = JSONDecoder()
        let overview = try decoder.decode(OverviewJSON.self, from: read("campus")).model
        let buildings = try planFiles.map { try decoder.decode(BuildingJSON.self, from: read($0)).model }
        return CampusMapData(overview: overview, plans: CampusFloorPlans(buildings: buildings))
    }

    /// 平面圖的層數優先於 OpenStreetMap 的層數。
    func levels(of building: CampusOverviewBuilding) -> String? {
        if let plan = building.plan, let levels = plans.building(id: plan)?.levels { return levels }
        return building.levels.map { "地上 \($0) 層" }
    }
}

nonisolated enum CampusMapError: Error {
    case missing(String)
}

/// 每次啟動只解析一次；在背景執行緒讀檔與解析。
@MainActor
final class CampusMapLoader {
    static let shared = CampusMapLoader()

    private var task: Task<CampusMapData, Error>?

    func load() async throws -> CampusMapData {
        let task = self.task ?? Task.detached(priority: .userInitiated) { try CampusMapData.bundled() }
        self.task = task
        do {
            return try await task.value
        } catch {
            self.task = nil
            throw error
        }
    }
}

// MARK: - Text

nonisolated enum CampusMapText {
    /// 忽略空白、全半形與大小寫，讓「教 ３０５」「工b02」也能比對。
    static func normalize(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_Hant_TW"))
            .uppercased()
            .filter { !$0.isWhitespace }
    }

    /// 「格致大樓（電資學院）」在地圖上分兩行，只佔一個名稱的寬度。
    static func mapName(_ name: String) -> String {
        name.replacingOccurrences(
            of: #"\s*[（(]([^）)]+)[）)]\s*$"#,
            with: "\n$1",
            options: .regularExpression
        )
    }
}

// MARK: - Geometry

nonisolated func polygonContains(_ points: [CGPoint], _ point: CGPoint) -> Bool {
    var inside = false
    var j = points.count - 1
    for i in points.indices {
        let a = points[i], b = points[j]
        if (a.y > point.y) != (b.y > point.y),
           point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
            inside.toggle()
        }
        j = i
    }
    return inside
}

nonisolated func boundingRect(_ points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .null }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in points {
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

nonisolated extension CGRect {
    var shortestSide: CGFloat { min(width, height) }
    var longestSide: CGFloat { max(width, height) }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - JSON

private nonisolated func point(_ values: [Double]) -> CGPoint {
    CGPoint(x: values[0], y: values[1])
}

private nonisolated struct SpaceJSON: Decodable {
    let kind: String
    let rect: [Double]?
    let polygon: [[Double]]?
    let code: String?
    let name: String?
    let note: String?
    let aka: [String]?

    func model(id: String) -> MapSpace {
        let points: [CGPoint]
        if let rect, rect.count == 4 {
            let (x, y, w, h) = (rect[0], rect[1], rect[2], rect[3])
            points = [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
        } else {
            points = (polygon ?? []).map(point)
        }
        return MapSpace(
            id: id, kind: MapSpaceKind(json: kind), points: points, isRect: rect != nil,
            code: code, name: name, note: note, aka: aka ?? [], bounds: boundingRect(points)
        )
    }
}

private nonisolated struct LinkJSON: Decodable {
    let to: String
    let name: String
    let at: [Double]
    let toward: [Double]
}

private nonisolated struct FloorJSON: Decodable {
    let id: String
    let outline: [[Double]]
    let outlines: [[[Double]]]?
    let spaces: [SpaceJSON]
    let links: [LinkJSON]?
    let unit: String?
    let aliases: [String]?

    var model: MapFloor {
        let outline = outline.map(point)
        let parts = (outlines ?? []).map { $0.map(point) }
        let rings = parts.isEmpty ? [outline] : parts
        let spaces = spaces.enumerated().map { index, space in space.model(id: "\(id)#\(index)") }
        let bounds = (rings.map(boundingRect) + spaces.map(\.bounds)).reduce(CGRect.null) { $0.union($1) }
        return MapFloor(
            id: id, outline: outline, outlines: rings, spaces: spaces,
            links: (links ?? []).map { MapLink(to: $0.to, name: $0.name, at: point($0.at), toward: point($0.toward)) },
            unit: unit, aliases: aliases ?? [], bounds: bounds
        )
    }
}

private nonisolated struct BuildingJSON: Decodable {
    let id: String
    let name: String
    let floors: [FloorJSON]

    var model: MapBuilding {
        let floors = floors.map(\.model)
        let bounds = floors.dropFirst().reduce(floors.first?.bounds ?? .zero) { $0.union($1.bounds) }
        return MapBuilding(id: id, name: name, floors: floors, bounds: bounds)
    }
}

private nonisolated struct OverviewJSON: Decodable {
    struct Building: Decodable {
        let id: Int
        let polygon: [[Double]]
        let campus: Bool?
        let name: String?
        let levels: Int?
        let plan: String?
        let listed: Bool?
    }

    struct Area: Decodable {
        let kind: String
        let polygon: [[Double]]
    }

    struct Road: Decodable {
        let kind: String
        let line: [[Double]]
    }

    let attribution: String
    let boundary: [[Double]]
    let buildings: [Building]
    let areas: [Area]
    let roads: [Road]

    var model: CampusOverview {
        let boundary = boundary.map(point)
        return CampusOverview(
            attribution: attribution,
            boundary: boundary,
            buildings: buildings.map { building in
                let polygon = building.polygon.map(point)
                let bounds = boundingRect(polygon)
                return CampusOverviewBuilding(
                    id: building.id, polygon: polygon, onCampus: building.campus ?? false,
                    name: building.name, levels: building.levels, plan: building.plan,
                    listed: building.listed ?? true, bounds: bounds, centre: centroid(polygon, bounds: bounds)
                )
            },
            areas: areas.compactMap { area in
                CampusAreaKind(rawValue: area.kind).map { CampusArea(kind: $0, polygon: area.polygon.map(point)) }
            },
            roads: roads.compactMap { road in
                CampusRoadKind(rawValue: road.kind).map { CampusRoad(kind: $0, line: road.line.map(point)) }
            },
            campus: boundingRect(boundary).insetBy(dx: -60, dy: -60)
        )
    }

    private func centroid(_ polygon: [CGPoint], bounds: CGRect) -> CGPoint {
        var a = 0.0, x = 0.0, y = 0.0
        for i in polygon.indices {
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            let cross = p.x * q.y - q.x * p.y
            a += cross
            x += (p.x + q.x) * cross
            y += (p.y + q.y) * cross
        }
        return abs(a) < 1e-6 ? bounds.center : CGPoint(x: x / (3 * a), y: y / (3 * a))
    }
}
