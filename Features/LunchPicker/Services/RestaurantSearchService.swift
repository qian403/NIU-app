import Foundation
import MapKit

protocol RestaurantSearching {
    func restaurants(serving dish: String, in area: LunchArea) async throws -> [Restaurant]
}

/// 以 Apple 地圖搜尋固定範圍內的店家；只送出菜色名稱與範圍，不含使用者位置或個人資料。
struct MapKitRestaurantSearchService: RestaurantSearching {
    /// 每個範圍最多保留的店家數，避免清單過長。
    private static let limit = 12

    func restaurants(serving dish: String, in area: LunchArea) async throws -> [Restaurant] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = dish
        request.region = MKCoordinateRegion(center: area.center,
                                            latitudinalMeters: area.radius * 2,
                                            longitudinalMeters: area.radius * 2)
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .bakery])

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        }

        // region 只是搜尋提示，Apple 地圖仍可能回傳範圍外的店家，所以再依距離過濾。
        let center = CLLocation(latitude: area.center.latitude, longitude: area.center.longitude)
        let restaurants = response.mapItems.compactMap { item -> Restaurant? in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let location = Self.location(of: item)
            let distance = location.distance(from: center)
            guard distance <= area.radius else { return nil }
            return Restaurant(id: Restaurant.identifier(name: name, coordinate: location.coordinate),
                              name: name,
                              address: Self.address(of: item),
                              area: area,
                              distance: distance,
                              mapItem: item)
        }
        return Array(restaurants.sorted { $0.distance < $1.distance }.prefix(Self.limit))
    }

    private static func location(of item: MKMapItem) -> CLLocation {
        if #available(iOS 26, *) {
            return item.location
        }
        let coordinate = item.placemark.coordinate
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private static func address(of item: MKMapItem) -> String? {
        if #available(iOS 26, *) {
            return item.address?.shortAddress ?? item.address?.fullAddress
        }
        return item.placemark.title
    }
}

extension RestaurantSearchFailure {
    init(error: Error) {
        let error = error as NSError
        if error.domain == MKError.errorDomain, error.code == MKError.Code.loadingThrottled.rawValue {
            self = .throttled
            return
        }
        let candidates = [error, error.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        for candidate in candidates where candidate.domain == NSURLErrorDomain {
            switch candidate.code {
            case NSURLErrorTimedOut:
                self = .timedOut
                return
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                self = .offline
                return
            default:
                break
            }
        }
        self = .unavailable
    }
}
