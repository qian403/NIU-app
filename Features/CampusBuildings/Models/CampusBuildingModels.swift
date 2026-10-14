import Foundation

struct CampusBuilding: Identifiable, Hashable {
    let id: String
    let name: String
    let floors: [BuildingFloor]
    let source: BuildingMapSource

    var defaultFloorID: String {
        floors.first { $0.id == "1F" }?.id ?? floors.first?.id ?? ""
    }

    func floor(id: String) -> BuildingFloor? {
        floors.first { $0.id == id }
    }
}

/// 校方公告的原始圖面；`revisedOn` 取自圖面右下角日期。
struct BuildingMapSource: Hashable {
    let title: String
    let pdfURL: URL
    let pageURL: URL
    let revisedOn: String
}

struct BuildingFloor: Identifiable, Hashable {
    let id: String
    let rows: [[FloorSpace]]

    /// 依列與欄的位置補上穩定 ID；教室與場館直接用名稱。
    init(id: String, rows: [[FloorSpace]]) {
        self.id = id
        self.rows = rows.enumerated().map { rowIndex, row in
            row.enumerated().map { columnIndex, space in
                space.withID(space.isRoom ? space.name : "\(id)-\(rowIndex)-\(columnIndex)")
            }
        }
    }

    var title: String {
        if id.hasPrefix("B") { return "地下 \(id.dropFirst()) 樓" }
        return "\(id.dropLast()) 樓"
    }

    var rooms: [FloorSpace] {
        rows.flatMap { $0 }.filter(\.isRoom)
    }
}

struct FloorSpace: Identifiable, Hashable {
    enum Kind: Hashable {
        /// 有校方教室編號的空間
        case classroom
        /// 有名稱但沒有教室編號的場館或單位
        case venue
        /// 樓梯、電梯、廁所、機房等設施
        case utility
        /// 川堂、中庭、出入口等通行空間
        case passage
        /// 相鄰的其他建物
        case external
        /// 只用來對齊版面的空白
        case gap
    }

    private(set) var id: String
    let name: String
    let kind: Kind
    let note: String?
    let span: Double

    var isRoom: Bool { kind == .classroom || kind == .venue }

    fileprivate func withID(_ id: String) -> FloorSpace {
        var copy = self
        copy.id = id
        return copy
    }

    static func classroom(_ name: String, note: String? = nil) -> FloorSpace {
        FloorSpace(id: name, name: name, kind: .classroom, note: note, span: 1)
    }

    static func venue(_ name: String, span: Double = 1) -> FloorSpace {
        FloorSpace(id: name, name: name, kind: .venue, note: nil, span: span)
    }

    static func utility(_ name: String, span: Double = 1) -> FloorSpace {
        FloorSpace(id: "", name: name, kind: .utility, note: nil, span: span)
    }

    static func passage(_ name: String, span: Double = 1) -> FloorSpace {
        FloorSpace(id: "", name: name, kind: .passage, note: nil, span: span)
    }

    static func external(_ name: String) -> FloorSpace {
        FloorSpace(id: "", name: name, kind: .external, note: nil, span: 1)
    }

    static func gap(span: Double = 1) -> FloorSpace {
        FloorSpace(id: "", name: "", kind: .gap, note: nil, span: span)
    }
}

struct CampusRoomMatch: Identifiable, Hashable {
    let building: CampusBuilding
    let floor: BuildingFloor
    let space: FloorSpace

    var id: String { "\(building.id)/\(space.id)" }
}

// MARK: - Catalog

/// 依教務處「教室平面圖」頁公告的 PDF 整理，只表示相對位置，不是等比例圖。
/// 教室編號規則依校方註記：代碼後第 1 碼為樓層，後兩碼為教室序號。
enum CampusBuildingCatalog {
    static let buildings: [CampusBuilding] = [jiaose, zonghe]

    private static let sourcePageURL = URL(string: "https://academic.niu.edu.tw/p/412-1003-465.php")!

    static func search(_ query: String) -> [CampusRoomMatch] {
        let keyword = normalize(query)
        guard !keyword.isEmpty else { return [] }
        let roomKeyword = keyword.hasSuffix("教室") && keyword.count > 2 ? String(keyword.dropLast(2)) : keyword

        return buildings.flatMap { building in
            building.floors.flatMap { floor in
                floor.rooms.compactMap { space -> CampusRoomMatch? in
                    let name = normalize(space.name)
                    let note = normalize(space.note ?? "")
                    let matches = name.contains(keyword)
                        || name.contains(roomKeyword)
                        || (!note.isEmpty && note.contains(keyword))
                    return matches ? CampusRoomMatch(building: building, floor: floor, space: space) : nil
                }
            }
        }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_Hant_TW"))
            .uppercased()
            .replacingOccurrences(of: "综", with: "綜")
            .filter { !$0.isWhitespace && $0 != "・" }
    }

    // MARK: 教穡大樓

    private static let jiaose: CampusBuilding = {
        let generalElective = "通識選修優先排課"
        let pbl = "PBL 問題行動導向優先"
        let humanities = "人文經典閱讀優先"
        let career = "職涯教育專業教室"
        let foreignLanguages = "外語學系優先排課"
        let notes: [Int: String] = [
            101: "學生休息室", 104: generalElective, 105: generalElective,
            106: generalElective, 107: generalElective,
            206: pbl, 207: pbl, 208: "環境與永續發展優先", 209: humanities, 210: humanities,
            214: career, 311: career, 401: foreignLanguages, 412: foreignLanguages
        ]
        func room(_ number: Int) -> FloorSpace {
            .classroom("教\(number)", note: notes[number])
        }

        var floors = [
            BuildingFloor(id: "B1", rows: [
                [.gap(), .venue("原住民族學生資源中心", span: 2), .gap(), .utility("機房", span: 2), .gap(), .utility("樓梯")],
                [.gap(), .passage("地下室中庭", span: 4), .utility("庫房"), .gap(), .utility("樓梯")]
            ])
        ]
        for level in 1...4 {
            let base = level * 100
            let core: FloorSpace = (2...3).contains(level) ? .utility("樓梯・洗手間") : .utility("樓梯")
            let backRow: [FloorSpace] = [level >= 3 ? room(base + 11) : .gap()]
                + (6...10).reversed().map { room(base + $0) }
                + [level == 2 ? room(214) : .gap(), core]
            let frontRow: [FloorSpace] = [level >= 3 ? room(base + 12) : .gap()]
                + (1...5).map { room(base + $0) }
                + [.gap(), core]
            floors.append(BuildingFloor(id: "\(level)F", rows: [
                backRow,
                [level == 1 ? .passage("正門") : .gap(), .gap(span: 7)],
                frontRow
            ]))
        }

        return CampusBuilding(
            id: "jiaose",
            name: "教穡大樓",
            floors: floors,
            source: BuildingMapSource(
                title: "國立宜蘭大學教穡大樓教室編號及位置圖",
                pdfURL: URL(string: "https://academic.niu.edu.tw/var/file/3/1003/img/215/770697857.pdf")!,
                pageURL: sourcePageURL,
                revisedOn: "2024/05/23"
            )
        )
    }()

    // MARK: 綜合教學大樓

    private static let zonghe: CampusBuilding = {
        let notes: [Int: String] = [203: "進修推廣組辦公室", 303: "教師休息室"]
        func room(_ number: Int) -> FloorSpace {
            .classroom("綜\(number)", note: notes[number])
        }

        var floors = [
            BuildingFloor(id: "B1", rows: [
                [.gap(), .classroom("綜B102"), .classroom("綜B101"), .gap(span: 6)],
                [.gap(), .venue("萬斌廳", span: 2), .venue("交誼廳"), .passage("台階"), .gap(span: 3), .passage("川堂")]
            ])
        ]
        for level in 1...4 {
            let base = level * 100
            let backCore: FloorSpace = switch level {
            case 1: .utility("樓梯・電梯")
            case 4: .utility("女廁")
            default: .utility("男廁")
            }
            let frontCore: FloorSpace = level == 1 ? .utility("電梯") : .utility("男廁・女廁")
            floors.append(BuildingFloor(id: "\(level)F", rows: [
                [.utility("樓梯"), room(base + 6), room(base + 5), room(base + 4), backCore,
                 .passage("川堂"), .utility("樓梯"), .passage("戶外川堂"), .external("行政大樓")],
                [.gap(span: 9)],
                [room(base + 1), .passage("川堂"), .utility("樓梯"), frontCore, room(base + 2), room(base + 3),
                 .utility("樓梯"), .passage("戶外川堂"), .external("行政大樓")]
            ]))
        }

        return CampusBuilding(
            id: "zonghe",
            name: "綜合教學大樓",
            floors: floors,
            source: BuildingMapSource(
                title: "國立宜蘭大學綜合教學大樓教室編號及位置圖",
                pdfURL: URL(string: "https://academic.niu.edu.tw/var/file/3/1003/img/215/546203924.pdf")!,
                pageURL: sourcePageURL,
                revisedOn: "2024/05/23"
            )
        )
    }()
}
