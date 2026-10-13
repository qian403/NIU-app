import SwiftUI

struct LunchPickerView: View {
    @StateObject private var model = LunchPickerViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.medium) {
                categoryCard
                if let category = model.category {
                    dishCard(category)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let dish = model.dish {
                    restaurantCard(dish)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(Theme.Spacing.large)
            .animation(reduceMotion ? nil : Theme.Animation.fast, value: model.category)
            .animation(reduceMotion ? nil : Theme.Animation.fast, value: model.dish)
            .animation(reduceMotion ? nil : Theme.Animation.fast, value: model.restaurantState)
        }
        .background(Theme.Colors.groupedBackground)
        .navigationTitle("午餐吃什麼")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if model.category != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重來") { model.reset() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: model.resultCount)
        .onChange(of: model.resultCount) {
            AccessibilityNotification.Announcement(announcement).post()
        }
        .onDisappear { model.cancel() }
    }

    // MARK: - Step 1

    private var categoryCard: some View {
        card {
            stepHeader(number: 1, title: "先決定吃麵、飯還是其他")

            HStack(spacing: Theme.Spacing.xsmall) {
                ForEach(LunchCategory.allCases) { category in
                    categoryButton(category)
                }
            }

            rollButton(
                title: model.category == nil ? "隨機選類別" : "重抽類別",
                symbol: "dice",
                isRolling: model.rollingStage == .category
            ) {
                model.rollCategory(animated: !reduceMotion)
            }
        }
    }

    private func categoryButton(_ category: LunchCategory) -> some View {
        let isShuffling = model.rollingStage == .category && model.shuffleText == "\(category.emoji) \(category.title)"
        let isSelected = model.rollingStage == .category ? isShuffling : model.category == category

        return Button {
            model.choose(category)
        } label: {
            VStack(spacing: Theme.Spacing.xxsmall) {
                Text(category.emoji)
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text(category.title)
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.label)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? Color.orange.opacity(0.18) : Theme.Colors.tertiaryFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                    .strokeBorder(isSelected ? Color.orange : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityHint(category.detail)
        .accessibilityAddTraits(model.category == category ? .isSelected : [])
    }

    // MARK: - Step 2

    private func dishCard(_ category: LunchCategory) -> some View {
        card {
            stepHeader(number: 2, title: "從「\(category.title)」裡挑一道")

            VStack(spacing: Theme.Spacing.xxsmall) {
                Text(dishResultText)
                    .font(.largeTitle.bold())
                    .foregroundStyle(model.dish == nil && model.rollingStage != .dish
                                     ? Theme.Colors.tertiaryLabel : Theme.Colors.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.identity)
                if let dish = model.dish, model.rollingStage == nil {
                    Text("今天中午就吃\(dish)吧！")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .accessibilityElement(children: .combine)

            rollButton(
                title: model.dish == nil ? "抽一道\(category.title)" : "換一道",
                symbol: "shuffle",
                isRolling: model.rollingStage == .dish
            ) {
                model.rollDish(animated: !reduceMotion)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text("候選清單")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: Theme.Spacing.xsmall)],
                          spacing: Theme.Spacing.xsmall) {
                    ForEach(category.dishes, id: \.self) { dish in
                        dishChip(dish)
                    }
                }
            }
        }
    }

    private func dishChip(_ dish: String) -> some View {
        let isHighlighted = model.rollingStage == .dish ? model.shuffleText == dish : model.dish == dish

        return Text(dish)
            .font(.footnote)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(isHighlighted ? Color.white : Theme.Colors.label)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xsmall)
            .background(
                Capsule(style: .continuous)
                    .fill(isHighlighted ? Color.orange : Theme.Colors.tertiaryFill)
            )
            .accessibilityAddTraits(model.dish == dish ? .isSelected : [])
    }

    private var dishResultText: String {
        if model.rollingStage == .dish, let text = model.shuffleText { return text }
        return model.dish ?? "還沒決定"
    }

    // MARK: - Step 3

    private func restaurantCard(_ dish: String) -> some View {
        card {
            stepHeader(number: 3, title: "去哪裡吃\(dish)")

            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text("搜尋範圍（可複選）")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                HStack(spacing: Theme.Spacing.xsmall) {
                    ForEach(LunchArea.allCases) { area in
                        areaToggle(area)
                    }
                }
            }

            restaurantContent(dish)

            Text("店家資料來自 Apple 地圖，營業時間與菜單請以店家公告為準。")
                .font(.caption)
                .foregroundStyle(Theme.Colors.tertiaryLabel)
        }
    }

    private func areaToggle(_ area: LunchArea) -> some View {
        let isOn = model.restaurantAreas.contains(area)
        let isLast = isOn && model.restaurantAreas.count == 1

        return Button {
            model.toggle(area)
        } label: {
            Label(area.title, systemImage: isOn ? "checkmark.circle.fill" : "circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isOn ? Color.orange : Theme.Colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                        .fill(isOn ? Color.orange.opacity(0.18) : Theme.Colors.tertiaryFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRolling)
        .accessibilityLabel(area.title)
        .accessibilityHint(isLast ? "至少要保留一個搜尋範圍" : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private func restaurantContent(_ dish: String) -> some View {
        switch model.restaurantState {
        case .idle:
            rollButton(title: "找賣\(dish)的店", symbol: "magnifyingglass", isRolling: false) {
                model.searchRestaurants()
            }
        case .loading:
            Button {} label: {
                HStack(spacing: Theme.Spacing.xsmall) {
                    ProgressView()
                    Text("搜尋中…")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(true)
        case .empty:
            searchMessage(symbol: "fork.knife",
                          title: "範圍內沒找到賣\(dish)的店",
                          detail: "可以加選其他範圍，或回上一步換一道菜。")
            retryButton(title: "重新搜尋")
        case .failed(let failure):
            searchMessage(symbol: "exclamationmark.triangle", title: failure.title, detail: failure.message)
            retryButton(title: "重試")
        case .loaded(let restaurants):
            if let picked = model.pickedRestaurant {
                pickedRestaurantBanner(picked)
            }
            rollButton(title: model.pickedRestaurant == nil ? "隨機挑一家" : "換一家",
                       symbol: "dice",
                       isRolling: false) {
                model.pickRestaurant()
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text("找到 \(restaurants.count) 家")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                LazyVStack(spacing: 0) {
                    ForEach(restaurants) { restaurant in
                        restaurantRow(restaurant)
                        if restaurant.id != restaurants.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func pickedRestaurantBanner(_ restaurant: Restaurant) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            Text("就去這家吧！")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.secondaryLabel)
            Text(restaurant.name)
                .font(.title2.bold())
                .foregroundStyle(Theme.Colors.label)
            Text("\(restaurant.area.distancePrefix)\(restaurant.distanceText)")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.secondaryLabel)
            Button {
                restaurant.openInMaps()
            } label: {
                Label("在地圖中開啟", systemImage: "map")
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private func restaurantRow(_ restaurant: Restaurant) -> some View {
        let isPicked = model.pickedRestaurant == restaurant

        return Button {
            restaurant.openInMaps()
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
                    Text(restaurant.name)
                        .font(isPicked ? .body.weight(.semibold) : .body)
                        .foregroundStyle(isPicked ? Color.orange : Theme.Colors.label)
                    Text("\(restaurant.area.distancePrefix)\(restaurant.distanceText)")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                    if let address = restaurant.address {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.tertiaryLabel)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isPicked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                }
                Image(systemName: "map")
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Spacing.xsmall)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("在地圖中開啟")
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private func searchMessage(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.Colors.secondaryLabel)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Colors.label)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func retryButton(title: String) -> some View {
        Button {
            model.searchRestaurants()
        } label: {
            Label(title, systemImage: "arrow.clockwise")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .disabled(model.isRolling)
    }

    private var announcement: String {
        if let restaurant = model.pickedRestaurant { return "挑中\(restaurant.name)" }
        if let dish = model.dish { return "抽到\(dish)" }
        if let category = model.category { return "抽到\(category.title)" }
        return ""
    }

    // MARK: - Components

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            content()
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func stepHeader(number: Int, title: String) -> some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Text("\(number)")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.orange))
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.Colors.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("步驟 \(number)，\(title)")
        .accessibilityAddTraits(.isHeader)
    }

    private func rollButton(title: String, symbol: String, isRolling: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(isRolling ? "抽籤中…" : title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(model.isRolling)
    }
}

#Preview {
    NavigationStack {
        LunchPickerView()
    }
}
