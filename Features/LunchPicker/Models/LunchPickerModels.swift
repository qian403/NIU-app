import Foundation
import MapKit

enum LunchCategory: String, CaseIterable, Identifiable, Hashable {
    case noodles
    case rice
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noodles: "麵"
        case .rice: "飯"
        case .other: "其他"
        }
    }

    var emoji: String {
        switch self {
        case .noodles: "🍜"
        case .rice: "🍚"
        case .other: "🥪"
        }
    }

    var detail: String {
        switch self {
        case .noodles: "麵食、湯麵、乾麵"
        case .rice: "便當、丼飯、燴飯"
        case .other: "早午餐、輕食、點心"
        }
    }

    var dishes: [String] {
        switch self {
        case .noodles:
            ["義大利麵", "牛肉麵", "拉麵", "烏龍麵", "炸醬麵", "麻醬麵", "鍋燒意麵", "陽春麵", "涼麵", "擔仔麵", "米粉湯", "越南河粉"]
        case .rice:
            ["滷肉飯", "雞腿便當", "排骨飯", "咖哩飯", "炒飯", "丼飯", "燴飯", "雞肉飯", "石鍋拌飯", "自助餐", "壽司", "海南雞飯"]
        case .other:
            ["早午餐", "蛋餅", "三明治", "漢堡", "潛艇堡", "貝果", "蔥抓餅", "水餃", "鍋貼", "沙拉", "披薩", "墨西哥捲餅"]
        }
    }
}

/// 找店家的搜尋範圍。中心點固定，不讀取使用者位置，因此不需要定位權限。
enum LunchArea: String, CaseIterable, Identifiable, Hashable {
    case campus
    case station

    var id: String { rawValue }

    var title: String {
        switch self {
        case .campus: "宜大周邊"
        case .station: "宜蘭火車站"
        }
    }

    var distancePrefix: String {
        switch self {
        case .campus: "距宜大"
        case .station: "距火車站"
        }
    }

    var center: CLLocationCoordinate2D {
        switch self {
        case .campus: CLLocationCoordinate2D(latitude: 24.7461, longitude: 121.7475)
        case .station: CLLocationCoordinate2D(latitude: 24.7547, longitude: 121.7586)
        }
    }

    var radius: CLLocationDistance {
        switch self {
        case .campus: 1200
        case .station: 1000
        }
    }
}

struct Restaurant: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String?
    let area: LunchArea
    /// 與所屬範圍中心點的直線距離（公尺）。
    let distance: CLLocationDistance
    let mapItem: MKMapItem

    static func == (lhs: Restaurant, rhs: Restaurant) -> Bool {
        lhs.id == rhs.id && lhs.area == rhs.area && lhs.distance == rhs.distance
    }

    var distanceText: String {
        if distance < 1000 {
            return "約 \(max(50, Int((distance / 50).rounded()) * 50)) 公尺"
        }
        return String(format: "約 %.1f 公里", distance / 1000)
    }

    func openInMaps() {
        mapItem.openInMaps()
    }

    static func identifier(name: String, coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%@|%.4f|%.4f", name, coordinate.latitude, coordinate.longitude)
    }

    /// 合併多個範圍的結果：同一家店只留距離較近的那筆，再依範圍順序與距離排序。
    static func merge(_ lists: [[Restaurant]]) -> [Restaurant] {
        var best: [String: Restaurant] = [:]
        for restaurant in lists.joined() {
            if let existing = best[restaurant.id], existing.distance <= restaurant.distance { continue }
            best[restaurant.id] = restaurant
        }
        let order = Dictionary(uniqueKeysWithValues: LunchArea.allCases.enumerated().map { ($1, $0) })
        return best.values.sorted {
            let lhs = order[$0.area] ?? 0, rhs = order[$1.area] ?? 0
            return lhs != rhs ? lhs < rhs : $0.distance < $1.distance
        }
    }
}

enum RestaurantSearchFailure: Equatable {
    case offline
    case timedOut
    case throttled
    case unavailable

    var title: String {
        switch self {
        case .offline: "目前沒有網路連線"
        case .timedOut: "搜尋逾時"
        case .throttled: "搜尋太頻繁"
        case .unavailable: "暫時無法搜尋店家"
        }
    }

    var message: String {
        switch self {
        case .offline: "連上網路後再試一次。"
        case .timedOut: "Apple 地圖回應太慢，請稍後再試。"
        case .throttled: "Apple 地圖暫時限制搜尋次數，請稍等一下再試。"
        case .unavailable: "Apple 地圖目前沒有回應，請稍後再試。"
        }
    }
}

enum RestaurantSearchState: Equatable {
    case idle
    case loading
    case loaded([Restaurant])
    case empty
    case failed(RestaurantSearchFailure)
}

enum LunchPicker {
    /// 盡量避開上一次的結果，讓「重抽」一定會換一個；只有一個選項時才允許重複。
    static func pick<Element: Equatable, Generator: RandomNumberGenerator>(
        from options: [Element],
        avoiding previous: Element?,
        using generator: inout Generator
    ) -> Element? {
        let candidates = options.filter { $0 != previous }
        return (candidates.isEmpty ? options : candidates).randomElement(using: &generator)
    }

    static func pick<Element: Equatable>(from options: [Element], avoiding previous: Element?) -> Element? {
        var generator = SystemRandomNumberGenerator()
        return pick(from: options, avoiding: previous, using: &generator)
    }
}
