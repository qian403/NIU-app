import SwiftUI

struct CampusBuildingsView: View {
    @StateObject private var model = CampusBuildingsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.medium) {
                if let building = model.building, let floor = model.floor {
                    selectorCard(building)
                    mapCard(building: building, floor: floor)
                    roomListCard(floor)
                    sourceFooter(building.source)
                }
            }
            .padding(Theme.Spacing.large)
        }
        .background(Theme.Colors.groupedBackground)
        .navigationTitle("大樓平面圖")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    // MARK: - Building & Floor

    private func selectorCard(_ building: CampusBuilding) -> some View {
        card {
            Picker("大樓", selection: Binding(
                get: { model.selectedBuildingID },
                set: { model.selectBuilding($0) }
            )) {
                ForEach(model.buildings) { building in
                    Text(building.name).tag(building.id)
                }
            }
            .pickerStyle(.segmented)

            Picker("樓層", selection: Binding(
                get: { model.selectedFloorID },
                set: { model.selectFloor($0) }
            )) {
                ForEach(building.floors) { floor in
                    Text(floor.id)
                        .accessibilityLabel(floor.title)
                        .tag(floor.id)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Map

    private func mapCard(building: CampusBuilding, floor: BuildingFloor) -> some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("\(building.name) \(floor.title)")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("可左右滑動")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.tertiaryLabel)
                    .accessibilityHidden(true)
            }

            FloorPlanGrid(floor: floor, highlightedSpaceID: model.highlightedSpaceID) { space in
                model.toggleHighlight(space)
            }

            FloorPlanLegend()
        }
    }

    // MARK: - Room List

    private func roomListCard(_ floor: BuildingFloor) -> some View {
        card {
            Text("本層教室與場館")
                .font(.headline)
                .foregroundStyle(Theme.Colors.label)
                .accessibilityAddTraits(.isHeader)

            if floor.rooms.isEmpty {
                Text("這一層沒有編號教室。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.secondaryLabel)
            } else {
                VStack(spacing: 0) {
                    ForEach(floor.rooms) { space in
                        roomRow(space)
                        if space.id != floor.rooms.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func roomRow(_ space: FloorSpace) -> some View {
        let isSelected = model.highlightedSpaceID == space.id

        return Button {
            model.toggleHighlight(space)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(space.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.Colors.label)
                    if let note = space.note {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.Colors.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, Theme.Spacing.xxsmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isSelected ? "取消在平面圖上標示" : "在平面圖上標示位置")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Source

    private func sourceFooter(_ source: BuildingMapSource) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            Text("依教務處公告〈\(source.title)〉（\(source.revisedOn)）整理，僅表示相對位置。教室代碼後第 1 碼為樓層，實際配置以現場及校方公告為準。")
                .font(.caption)
                .foregroundStyle(Theme.Colors.secondaryLabel)
            HStack(spacing: Theme.Spacing.medium) {
                Link(destination: source.pdfURL) {
                    Label("查看校方原圖", systemImage: "doc.richtext")
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                }
                Link(destination: source.pageURL) {
                    Label("教務處公告頁", systemImage: "safari")
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xxsmall)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            content()
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Floor Plan Grid

private struct FloorPlanGrid: View {
    let floor: BuildingFloor
    let highlightedSpaceID: String?
    let onSelect: (FloorSpace) -> Void

    @ScaledMetric(relativeTo: .caption) private var unitWidth: CGFloat = 60
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 52
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let spacing: CGFloat = 4

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(floor.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: spacing) {
                            ForEach(row) { space in
                                cell(space, height: isSpacerRow(row) ? rowHeight * 0.45 : rowHeight)
                                    .id(space.id)
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xxsmall)
                .id(floor.id)
            }
            // 讓平面圖可以捲到卡片邊緣，不被內距截斷
            .contentMargins(.horizontal, Theme.Spacing.medium, for: .scrollContent)
            .padding(.horizontal, -Theme.Spacing.medium)
            .onAppear { scroll(proxy, to: highlightedSpaceID, animated: false) }
            .onChange(of: highlightedSpaceID) { _, id in scroll(proxy, to: id, animated: !reduceMotion) }
        }
    }

    private func isSpacerRow(_ row: [FloorSpace]) -> Bool {
        row.allSatisfy { $0.kind == .gap || $0.kind == .passage }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String?, animated: Bool) {
        guard let id else { return }
        if animated {
            withAnimation(Theme.Animation.standard) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    @ViewBuilder
    private func cell(_ space: FloorSpace, height: CGFloat) -> some View {
        let width = unitWidth * space.span + spacing * max(space.span - 1, 0)

        if space.kind == .gap {
            Color.clear
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        } else if space.isRoom {
            let isSelected = highlightedSpaceID == space.id
            Button {
                onSelect(space)
            } label: {
                FloorSpaceLabel(space: space, isSelected: isSelected)
                    .frame(width: width, height: height)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText(space))
            .accessibilityHint(isSelected ? "取消標示" : "標示這個位置")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            FloorSpaceLabel(space: space, isSelected: false)
                .frame(width: width, height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(space.kind == .external ? "相鄰建物，\(space.name)" : space.name)
        }
    }

    private func accessibilityText(_ space: FloorSpace) -> String {
        let kind = space.kind == .classroom ? "教室" : "場館"
        return [space.name, "\(floor.title)\(kind)", space.note].compactMap { $0 }.joined(separator: "，")
    }
}

private struct FloorSpaceLabel: View {
    let space: FloorSpace
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            shape
                .fill(fill)
                .overlay(shape.strokeBorder(stroke, style: strokeStyle))

            Text(space.name)
                .font(space.isRoom ? .caption.weight(.bold) : .caption2)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if space.note != nil {
                Circle()
                    .fill(isSelected ? Color.white : Color.orange)
                    .frame(width: 6, height: 6)
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.CornerRadius.xsmall, style: .continuous)
    }

    private var fill: Color {
        if isSelected { return Theme.Colors.accent }
        switch space.kind {
        case .classroom: return Theme.Colors.accentSoft
        case .venue: return Color.indigo.opacity(0.14)
        case .utility: return Theme.Colors.tertiaryFill
        case .passage, .external, .gap: return .clear
        }
    }

    private var stroke: Color {
        switch space.kind {
        case .classroom: return isSelected ? Theme.Colors.accent : Theme.Colors.accentMedium
        case .venue: return Color.indigo.opacity(0.35)
        case .utility, .gap: return .clear
        case .passage, .external: return Theme.Colors.separator
        }
    }

    private var strokeStyle: StrokeStyle {
        space.kind == .passage || space.kind == .external
            ? StrokeStyle(lineWidth: 1, dash: [3, 3])
            : StrokeStyle(lineWidth: isSelected ? 2 : 1)
    }

    private var textColor: Color {
        if isSelected { return .white }
        switch space.kind {
        case .classroom, .venue: return Theme.Colors.label
        default: return Theme.Colors.secondaryLabel
        }
    }
}

private struct FloorPlanLegend: View {
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: Theme.Spacing.xsmall, alignment: .leading)],
            alignment: .leading,
            spacing: Theme.Spacing.xxsmall
        ) {
            items
        }
        .font(.caption2)
        .foregroundStyle(Theme.Colors.secondaryLabel)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var items: some View {
        swatch("教室", fill: Theme.Colors.accentSoft, stroke: Theme.Colors.accentMedium)
        swatch("場館", fill: Color.indigo.opacity(0.14), stroke: Color.indigo.opacity(0.35))
        swatch("樓梯・廁所", fill: Theme.Colors.tertiaryFill, stroke: .clear)
        swatch("通道・相鄰建物", fill: .clear, stroke: Theme.Colors.separator, dashed: true)
        HStack(spacing: 4) {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
            Text("有使用備註")
        }
    }

    private func swatch(_ title: String, fill: Color, stroke: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : []))
                )
                .frame(width: 12, height: 12)
            Text(title)
        }
    }
}

#Preview {
    NavigationStack {
        CampusBuildingsView()
    }
}
