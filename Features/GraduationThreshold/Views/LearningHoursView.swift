import SwiftUI

/// 多元學習認證時數紀錄，資料來自學生服務平台（需校園網路）。
struct LearningHoursView: View {
    @StateObject private var vm = LearningHoursViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("時數紀錄")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .task { vm.start() }
        .onDisappear { vm.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.loadState {
        case .idle, .loading:
            VStack(spacing: Theme.Spacing.small) {
                ProgressView()
                Text("正在讀取時數紀錄…")
                    .font(.body)
                Text("首次讀取需連接校園網路")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message):
            ContentUnavailableView {
                Label("無法讀取時數紀錄", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重試", action: vm.refresh)
                    .buttonStyle(.borderedProminent)
            }

        case .loaded:
            if let snapshot = vm.snapshot {
                recordList(snapshot)
            }
        }
    }

    private func recordList(_ snapshot: LearningHoursSnapshot) -> some View {
        List {
            if !snapshot.summaries.isEmpty {
                Section {
                    abilityFilter(snapshot.summaries)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                if vm.filteredRecords.isEmpty {
                    Text(vm.selectedAbility == nil ? "尚無認證紀錄" : "此領域尚無認證紀錄")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(Array(vm.filteredRecords.enumerated()), id: \.offset) { _, record in
                        LearningHoursRecordRow(record: record)
                    }
                }
            } header: {
                Text(vm.selectedAbility.map { "\($0)・\(vm.filteredRecords.count) 筆" }
                     ?? "全部・\(vm.filteredRecords.count) 筆")
            }

            Section {
                AcademicRefreshFooter(
                    lastUpdated: snapshot.fetchedAt,
                    isRefreshing: vm.isRefreshing,
                    errorMessage: vm.lastRefreshError,
                    onRetry: vm.refresh
                )
                Text("更新時數紀錄需連接校園網路")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .refreshable { await vm.refreshAndWait() }
    }

    private func abilityFilter(_ summaries: [LearningHoursSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xsmall) {
                filterChip(title: "全部", detail: nil, ability: nil)
                ForEach(summaries) { summary in
                    filterChip(title: summary.ability,
                               detail: "\(formatHours(summary.earned)) / \(formatHours(summary.required))",
                               ability: summary.ability)
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)
        }
    }

    private func filterChip(title: String, detail: String?, ability: String?) -> some View {
        let selected = vm.selectedAbility == ability
        return Button {
            vm.selectedAbility = ability
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(selected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                    .fill(selected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "\(title)，已認證 \($0) 小時" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func formatHours(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

private struct LearningHoursRecordRow: View {
    let record: LearningHoursRecord

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(record.ability)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(Color.accentColor)
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.xsmall)
            Text("\(record.hours) 小時")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var dateText: String {
        record.startDate == record.endDate ? record.startDate : "\(record.startDate) – \(record.endDate)"
    }
}
