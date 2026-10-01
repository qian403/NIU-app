import SwiftUI

// MARK: - Booking form

/// 「預約設備」頁籤：日期 → 空間／設備 → 開始時間。
struct LibraryEquipmentBookingForm: View {
    @ObservedObject var model: LibraryEquipmentViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            LibraryEquipmentCard(step: 1, title: "選擇日期", subtitle: LibraryEquipmentText.dayTitle(model.date)) {
                LibraryEquipmentDayStrip(selection: model.date) { model.select(date: $0) }
            } accessory: {
                DatePicker("其他日期", selection: Binding(
                    get: { model.date }, set: { model.select(date: $0) }
                ), in: LibraryEquipmentDate.day(Date())..., displayedComponents: .date)
                .labelsHidden()
                .accessibilityLabel("選擇其他預約日期")
            }

            LibraryEquipmentCard(step: 2, title: "選擇空間或設備") {
                choices
            }

            LibraryEquipmentSlotSection(model: model)
        }
        .disabled(model.isLoading || model.isMutating)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 140),
                  spacing: Theme.Spacing.xsmall)]
    }

    @ViewBuilder private var choices: some View {
        if model.groups.isEmpty {
            placeholder(model.isLoading ? "正在查詢設備…" : "目前沒有可供單日時段預約的設備群組。")
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if model.groups.count > 1 {
                    caption("類別")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.xsmall) {
                        ForEach(model.groups) { group in
                            LibraryEquipmentChip(title: group.name, detail: "共 \(group.total) 項",
                                                 isSelected: group.id == model.groupID) {
                                model.select(groupID: group.id)
                            }
                        }
                    }
                } else if let group = model.selectedGroup {
                    Label(group.name, systemImage: "square.grid.2x2")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                caption("設備")
                if let equipment = model.schedule?.equipment, !equipment.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.xsmall) {
                        ForEach(equipment) { item in
                            LibraryEquipmentChip(title: item.name, isSelected: item.id == model.equipmentID) {
                                model.select(equipmentID: item.id)
                            }
                        }
                    }
                } else {
                    placeholder(model.isLoading ? "正在查詢設備…" : "此群組目前沒有可預約設備。")
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

// MARK: - Day strip

/// 未來兩週的日期捷徑；更遠的日期由卡片右上角的日期選擇器處理。
struct LibraryEquipmentDayStrip: View {
    let selection: Date
    let onSelect: (Date) -> Void

    private static let dayCount = 14

    private var days: [Date] {
        let today = LibraryEquipmentDate.day(Date())
        return (0..<Self.dayCount).compactMap {
            LibraryEquipmentDate.calendar.date(byAdding: .day, value: $0, to: today)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    ForEach(days, id: \.self) { day in
                        dayButton(day)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, value in
                withAnimation(Theme.Animation.standard) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = day == selection
        let relative = LibraryEquipmentText.relativeDay(day)
        return Button { onSelect(day) } label: {
            VStack(spacing: 2) {
                Text(relative ?? LibraryEquipmentText.shortWeekday(day))
                    .font(.caption.weight(.medium))
                Text(LibraryEquipmentDate.format(day, pattern: "d"))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(LibraryEquipmentDate.format(day, pattern: "M月"))
                    .font(.caption2)
                    .opacity(0.8)
            }
            .foregroundStyle(isSelected ? Color.white : (relative == "今天" ? Color.accentColor : Color.primary))
            .frame(minWidth: 54, minHeight: 68)
            .padding(.horizontal, 2)
            .background(isSelected ? Color.accentColor : Theme.Colors.tertiaryFill,
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(day)
        .accessibilityLabel("\(relative.map { "\($0)，" } ?? "")\(LibraryEquipmentDate.format(day, pattern: "M月d日"))，\(LibraryEquipmentDate.weekday(day))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Time slots

private enum LibraryEquipmentDayPeriod: CaseIterable, Identifiable {
    case morning, afternoon, evening

    var id: Self { self }

    var title: String {
        switch self {
        case .morning: return "上午"
        case .afternoon: return "下午"
        case .evening: return "晚上"
        }
    }

    func contains(_ minute: Int) -> Bool {
        switch self {
        case .morning: return minute < 12 * 60
        case .afternoon: return minute >= 12 * 60 && minute < 18 * 60
        case .evening: return minute >= 18 * 60
        }
    }
}

struct LibraryEquipmentSlotSection: View {
    @ObservedObject var model: LibraryEquipmentViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LibraryEquipmentCard(step: 3, title: "選擇開始時間", subtitle: subtitle) {
            if let policy = model.policy {
                slotContent(policy)
            } else {
                Text(model.isLoading ? "正在取得可預約時段…" : "選好設備後，這裡會顯示當日時段。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }

    private var subtitle: String? {
        guard let policy = model.policy else { return nil }
        return "開放 \(LibraryEquipmentDate.time(policy.openMinute))–\(LibraryEquipmentDate.time(policy.closeMinute)) · 每格 30 分鐘"
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 160 : 72),
                  spacing: Theme.Spacing.xsmall)]
    }

    @ViewBuilder private func slotContent(_ policy: LibraryEquipmentPolicy) -> some View {
        let all = model.slots
        let upcoming = all.filter { $0.state != .past }
        let past = all.filter { $0.state == .past }
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if policy.remainingHours < policy.minimumHours {
                LibraryEquipmentBanner(.warning, message: "剩餘額度不足以建立新的預約。")
            }

            if upcoming.isEmpty {
                Text("此日期已無尚未開始的時段，請選擇其他日期。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(hint(policy))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(LibraryEquipmentDayPeriod.allCases) { period in
                    let slots = upcoming.filter { period.contains($0.minute) }
                    if !slots.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                            Text(period.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, spacing: Theme.Spacing.xsmall) {
                                ForEach(slots) { slot in
                                    LibraryEquipmentSlotCell(slot: slot) { model.selectStart(slot.minute) }
                                }
                            }
                        }
                    }
                }
            }

            if !past.isEmpty {
                DisclosureGroup("已開始的時段（\(past.count)）") {
                    Text(past.map { LibraryEquipmentDate.time($0.minute) }.joined(separator: "、"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Spacing.xsmall)
                }
                .font(.subheadline)
            }

            quotaSummary(policy)

            DisclosureGroup("使用規則") {
                Text("每次 \(LibraryEquipmentText.hours(policy.minimumHours))–\(LibraryEquipmentText.hours(policy.maximumHours)) 小時，以 30 分鐘調整。預約需連續且不得跨過占用時段，並依圖書館規定報到。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Spacing.xsmall)
            }
            .font(.subheadline)
        }
    }

    private func hint(_ policy: LibraryEquipmentPolicy) -> String {
        if let label = model.selectedTimeLabel, model.selectionError == nil {
            return "已選 \(label)，可拖曳下方滑塊調整時長；點其他時間可重新選擇。"
        }
        return "點選開始時間，最短預約 \(LibraryEquipmentText.hours(policy.minimumHours)) 小時。"
    }

    private func quotaSummary(_ policy: LibraryEquipmentPolicy) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.xsmall) { quotaStats(policy) }
            VStack(spacing: Theme.Spacing.xsmall) { quotaStats(policy) }
        }
    }

    @ViewBuilder private func quotaStats(_ policy: LibraryEquipmentPolicy) -> some View {
        stat("校方剩餘額度", value: "\(LibraryEquipmentText.hours(policy.remainingHours)) 小時")
        stat("單次可預約", value: "\(LibraryEquipmentText.hours(policy.minimumHours))–\(LibraryEquipmentText.hours(policy.maximumHours)) 小時")
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.tertiaryFill,
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 單一 30 分鐘時段。可選時段為實心底，不可選時段為外框並附文字說明。
struct LibraryEquipmentSlotCell: View {
    let slot: LibraryEquipmentSlot
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(LibraryEquipmentDate.time(slot.minute))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .strikethrough(slot.state == .occupied && !slot.isSelected)
                Text(status)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(background, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(slot.state != .available && !slot.isSelected)
        .accessibilityLabel("\(LibraryEquipmentDate.time(slot.minute))，\(accessibilityStatus)")
        .accessibilityAddTraits(slot.isSelected ? .isSelected : [])
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
    }

    private var status: String {
        if slot.isSelected { return slot.isStart ? "開始" : "已選" }
        switch slot.state {
        case .available: return "可選"
        case .occupied: return "已占用"
        case .past: return "已開始"
        case .tooShort: return "空檔不足"
        case .quotaUnavailable: return "額度不足"
        }
    }

    private var accessibilityStatus: String {
        if slot.isSelected { return slot.isStart ? "已選為開始時間" : "已選時段" }
        if slot.state == .tooShort {
            return "空檔 \(LibraryEquipmentText.hours(minutes: slot.continuousMinutes)) 小時，不足最短預約時長"
        }
        return status
    }

    private var foreground: Color {
        if slot.isStart { return .white }
        if slot.isSelected { return .accentColor }
        return slot.state == .available ? .primary : Theme.Colors.tertiaryLabel
    }

    private var background: Color {
        if slot.isStart { return .accentColor }
        if slot.isSelected { return Theme.Colors.accentMedium }
        return slot.state == .available ? Theme.Colors.tertiaryFill : .clear
    }

    private var border: Color {
        if slot.isStart { return .clear }
        if slot.isSelected { return Color.accentColor.opacity(0.5) }
        return slot.state == .available ? .clear : Theme.Colors.separator.opacity(0.6)
    }
}

// MARK: - Booking bar

/// 底部固定的預約摘要：所選時段、時長與送出前核對。
struct LibraryEquipmentBookingBar: View {
    @ObservedObject var model: LibraryEquipmentViewModel
    let showReservations: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            summary
            durationPicker
            if let message = model.selectionMessage {
                Label(message, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionButton
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(maxWidth: 650)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedTimeLabel ?? "尚未選擇時段")
                    .font(.headline.monospacedDigit())
                Text("\(model.selectedEquipment?.name ?? "請選擇設備") · \(LibraryEquipmentText.dayTitle(model.date))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.selectedTimeLabel != nil {
                Text("\(LibraryEquipmentText.hours(minutes: model.durationMinutes)) 小時")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.accentSoft, in: Capsule())
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var durationPicker: some View {
        if let maximum = model.maximumDuration {
            if maximum > model.minimumDuration {
                durationSlider(maximum: maximum)
            } else {
                Text("此開始時間僅可預約 \(LibraryEquipmentText.hours(minutes: maximum)) 小時。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if model.selectedStartMinute == nil {
            Text("點選上方的開始時間，再拖曳滑塊調整時長。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 以 30 分鐘為一格的時長滑塊；上限已由 ViewModel 依額度、開放時間與下一個占用時段算出。
    private func durationSlider(maximum: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: Binding(
                get: { Double(model.durationMinutes) },
                set: { model.setDuration(Int(($0 / 30).rounded()) * 30) }
            ), in: Double(model.minimumDuration)...Double(maximum), step: 30) {
                Text("預約時長")
            } minimumValueLabel: {
                Image(systemName: "minus").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "plus").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .disabled(model.isLoading || model.isMutating)
            .accessibilityValue("\(LibraryEquipmentText.hours(minutes: model.durationMinutes)) 小時")
            .accessibilityHint("每次調整 30 分鐘，僅可選連續可預約的時長")
            HStack {
                Text("\(LibraryEquipmentText.hours(minutes: model.minimumDuration)) 小時")
                Spacer()
                Text("最多 \(LibraryEquipmentText.hours(minutes: maximum)) 小時")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var actionButton: some View {
        if model.needsVerification {
            Button(action: showReservations) {
                Text("查看我的預約並核對")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { model.prepareConfirmation() } label: {
                HStack(spacing: Theme.Spacing.xsmall) {
                    if model.isLoading { ProgressView() }
                    Text(model.isLoading ? "正在核對…" : "核對預約")
                    if !model.isLoading { Image(systemName: "arrow.right") }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isLoading || model.isMutating || model.selectionError != nil)
        }
    }
}
