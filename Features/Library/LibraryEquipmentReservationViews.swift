import SwiftUI

// MARK: - Reservation list

/// 「我的預約」頁籤：搜尋、篩選與預約卡片。
struct LibraryEquipmentReservationList: View {
    @ObservedObject var model: LibraryEquipmentViewModel
    let onCancel: (LibraryEquipmentReservation) -> Void

    private var isBusy: Bool { model.isLoading || model.isMutating }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            searchField
            filters
            resultHeader
            content
            if model.needsVerification, model.reservationsUpdatedAt != nil {
                Button { model.acknowledgeVerification() } label: {
                    Text("我已核對最新紀錄")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .privacySensitive()
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜尋設備名稱、日期或時間", text: $model.reservationQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("搜尋我的預約")
            if !model.reservationQuery.isEmpty {
                Button { model.reservationQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .frame(minHeight: 48)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xsmall) {
                ForEach(LibraryReservationPeriod.allCases) { period in
                    Button { model.reservationPeriod = period } label: {
                        filterLabel(period.title, isSelected: model.reservationPeriod == period)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("日期篩選：\(period.title)")
                    .accessibilityAddTraits(model.reservationPeriod == period ? .isSelected : [])
                }
                if model.reservationEquipment.count > 1 || model.reservationEquipmentID != nil {
                    Menu {
                        Picker("設備篩選", selection: $model.reservationEquipmentID) {
                            Text("全部設備").tag(Optional<Int>.none)
                            ForEach(model.reservationEquipment) { Text($0.name).tag(Optional($0.id)) }
                        }
                    } label: {
                        filterLabel(selectedEquipmentName ?? "全部設備",
                                    isSelected: model.reservationEquipmentID != nil, showsMenu: true)
                    }
                    .accessibilityLabel("預約設備篩選，目前為\(selectedEquipmentName ?? "全部設備")")
                }
            }
        }
    }

    private var selectedEquipmentName: String? {
        model.reservationEquipment.first { $0.id == model.reservationEquipmentID }?.name
    }

    private func filterLabel(_ title: String, isSelected: Bool, showsMenu: Bool = false) -> some View {
        HStack(spacing: 4) {
            if isSelected {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
            }
            Text(title).lineLimit(1)
            if showsMenu {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
        }
        .font(.subheadline)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(isSelected ? Theme.Colors.accentSoft : Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay { Capsule().strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1) }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var resultHeader: some View {
        HStack {
            Text("顯示 \(model.filteredReservations.count) / \(model.reservations.count) 筆")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if model.hasReservationFilters {
                Button("清除條件") { model.resetReservationFilters() }
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.reservationsUpdatedAt == nil {
            Text(model.isLoading ? "正在取得預約紀錄…" : "尚未取得最新預約紀錄，請重新整理。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
        } else if model.reservations.isEmpty {
            ContentUnavailableView("目前沒有預約", systemImage: "calendar",
                description: Text("完成預約後，會在這裡顯示設備與時段。"))
        } else if model.filteredReservations.isEmpty {
            ContentUnavailableView("沒有符合條件的預約", systemImage: "magnifyingglass",
                description: Text("試試其他設備名稱、日期，或清除篩選條件。"))
        }
        // 尚未重新取得時仍列出既有紀錄，方便核對；取消按鈕在需要核對時會停用。
        LazyVStack(spacing: Theme.Spacing.small) {
            ForEach(model.filteredReservations) { record in
                LibraryEquipmentReservationCard(record: record,
                    canCancel: !(isBusy || model.needsVerification)) { onCancel(record) }
            }
        }
    }
}

// MARK: - Reservation card

struct LibraryEquipmentReservationCard: View {
    let record: LibraryEquipmentReservation
    let canCancel: Bool
    let onCancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                    dateBadge
                    details
                }
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    dateBadge
                    details
                }
            }
            Divider()
            footer
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
    }

    private var duration: String {
        LibraryEquipmentText.hours(record.end.timeIntervalSince(record.start) / 3600)
    }

    private var dateBadge: some View {
        VStack(spacing: 2) {
            Text(LibraryEquipmentText.relativeDay(record.start) ?? LibraryEquipmentText.shortWeekday(record.start))
                .font(.caption.weight(.semibold))
            Text(LibraryEquipmentDate.format(record.start, pattern: "M/d"))
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 6)
        .frame(minWidth: 60, minHeight: 60)
        .background(Theme.Colors.accentSoft,
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous))
        .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xsmall) {
                Text(record.equipmentName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusBadge
            }
            Label("\(LibraryEquipmentDate.format(record.start))（\(LibraryEquipmentDate.weekday(record.start))）",
                  systemImage: "calendar")
            Label("\(LibraryEquipmentText.timeRange(record.start, record.end)) · \(duration) 小時",
                  systemImage: "clock")
                .font(.subheadline.monospacedDigit())
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var statusBadge: some View {
        Label("已預約", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.Colors.success)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.Colors.success.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.small) {
                deadline
                Spacer(minLength: 0)
                cancelButton
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                deadline
                cancelButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var deadline: some View {
        if let keepUntil = record.keepUntil {
            Label("保留期限 \(LibraryEquipmentText.dateTime(keepUntil))", systemImage: "hourglass")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cancelButton: some View {
        Button(role: .destructive, action: onCancel) {
            Text("取消預約").font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered)
        .tint(Theme.Colors.error)
        .frame(minHeight: 44)
        .accessibilityLabel("取消 \(record.equipmentName)，\(LibraryEquipmentText.dateTime(record.start)) 的預約")
        .disabled(!canCancel)
    }
}
