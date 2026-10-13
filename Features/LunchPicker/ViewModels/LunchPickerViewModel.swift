import Foundation
import Combine

@MainActor
final class LunchPickerViewModel: ObservableObject {
    enum Stage: Equatable {
        case category
        case dish
    }

    @Published private(set) var category: LunchCategory?
    @Published private(set) var dish: String? {
        didSet {
            if dish != oldValue { clearRestaurants() }
        }
    }
    /// 抽籤動畫進行中顯示的暫時文字；結束後清空。
    @Published private(set) var shuffleText: String?
    @Published private(set) var rollingStage: Stage?
    /// 每次抽出最終結果時遞增，供觸覺回饋與無障礙公告使用。
    @Published private(set) var resultCount = 0

    @Published private(set) var restaurantAreas: Set<LunchArea>
    @Published private(set) var restaurantState: RestaurantSearchState = .idle
    @Published private(set) var pickedRestaurant: Restaurant?

    private let restaurantSearch: RestaurantSearching
    private let defaults: UserDefaults
    private var rollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// 每次發出或作廢搜尋時遞增，避免較舊的回應覆蓋新的狀態。
    private var searchGeneration = 0

    private static let areasKey = "lunchPicker.restaurantAreas"

    /// 每一格的間隔逐漸變長，模擬轉盤減速。
    private static let shuffleDelays: [UInt64] = [50, 55, 60, 70, 80, 95, 115, 140, 170, 210].map { $0 * 1_000_000 }

    var isRolling: Bool { rollingStage != nil }

    /// 預設服務在 init 內建立：預設參數於非隔離環境求值，無法直接呼叫 MainActor 的初始化器。
    init(restaurantSearch: RestaurantSearching? = nil, defaults: UserDefaults = .standard) {
        self.restaurantSearch = restaurantSearch ?? MapKitRestaurantSearchService()
        self.defaults = defaults
        let stored = (defaults.string(forKey: Self.areasKey) ?? "")
            .split(separator: ",")
            .compactMap { LunchArea(rawValue: String($0)) }
        restaurantAreas = stored.isEmpty ? [.campus] : Set(stored)
    }

    deinit {
        rollTask?.cancel()
        searchTask?.cancel()
    }

    func rollCategory(animated: Bool) {
        let previous = category
        guard let result = LunchPicker.pick(from: LunchCategory.allCases, avoiding: previous) else { return }
        roll(.category, animated: animated, frames: LunchCategory.allCases.map { "\($0.emoji) \($0.title)" }) { [weak self] in
            self?.category = result
            self?.dish = nil
        }
    }

    func rollDish(animated: Bool) {
        guard let category else { return }
        let options = category.dishes
        guard let result = LunchPicker.pick(from: options, avoiding: dish) else { return }
        roll(.dish, animated: animated, frames: options) { [weak self] in
            self?.dish = result
        }
    }

    func choose(_ category: LunchCategory) {
        cancel()
        guard self.category != category else { return }
        self.category = category
        dish = nil
    }

    func reset() {
        cancel()
        category = nil
        dish = nil
    }

    func cancel() {
        rollTask?.cancel()
        rollTask = nil
        rollingStage = nil
        shuffleText = nil
        if restaurantState == .loading { clearRestaurants() }
    }

    // MARK: - Restaurants

    /// 至少保留一個範圍；已搜尋過時，改變範圍會直接重新搜尋。
    func toggle(_ area: LunchArea) {
        var areas = restaurantAreas
        if areas.contains(area) {
            guard areas.count > 1 else { return }
            areas.remove(area)
        } else {
            areas.insert(area)
        }
        restaurantAreas = areas
        defaults.set(LunchArea.allCases.filter(areas.contains).map(\.rawValue).joined(separator: ","), forKey: Self.areasKey)
        if restaurantState != .idle { searchRestaurants() }
    }

    func searchRestaurants() {
        guard let dish else { return }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let areas = LunchArea.allCases.filter(restaurantAreas.contains)
        pickedRestaurant = nil
        restaurantState = .loading

        searchTask = Task { [weak self, restaurantSearch] in
            let state: RestaurantSearchState
            do {
                var lists: [[Restaurant]] = []
                for area in areas {
                    lists.append(try await restaurantSearch.restaurants(serving: dish, in: area))
                    try Task.checkCancellation()
                }
                let restaurants = Restaurant.merge(lists)
                state = restaurants.isEmpty ? .empty : .loaded(restaurants)
            } catch {
                state = .failed(RestaurantSearchFailure(error: error))
            }
            guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
            self.restaurantState = state
            self.searchTask = nil
        }
    }

    func pickRestaurant() {
        guard case .loaded(let restaurants) = restaurantState,
              let result = LunchPicker.pick(from: restaurants, avoiding: pickedRestaurant) else { return }
        pickedRestaurant = result
        resultCount += 1
    }

    private func clearRestaurants() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        restaurantState = .idle
        pickedRestaurant = nil
    }

    private func roll(_ stage: Stage, animated: Bool, frames: [String], commit: @escaping () -> Void) {
        cancel()
        guard animated, !frames.isEmpty else {
            commit()
            resultCount += 1
            return
        }

        rollingStage = stage
        rollTask = Task { [weak self] in
            var last: String?
            for delay in Self.shuffleDelays {
                let frame = LunchPicker.pick(from: frames, avoiding: last)
                last = frame
                self?.shuffleText = frame
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            commit()
            self.shuffleText = nil
            self.rollingStage = nil
            self.rollTask = nil
            self.resultCount += 1
        }
    }
}
