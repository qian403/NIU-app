import SwiftUI

struct EventRegistration_Tab1_View: View {
    @ObservedObject var viewModel: EventRegistration_Tab1_ViewModel
    var showApplied: () -> Void = {}
    @State private var selectedEvent: EventData?

    var body: some View {
        EventListScaffold(
            items: viewModel.filteredEvents,
            totalCount: viewModel.events.count,
            phase: viewModel.phase,
            updatedAt: viewModel.updatedAt,
            searchText: $viewModel.searchText,
            searchHint: "可搜尋活動編號、名稱、主辦單位或內容",
            emptyTitle: "目前沒有可報名的活動",
            emptySymbol: "calendar.badge.exclamationmark",
            reload: viewModel.reload,
            refresh: viewModel.refresh
        ) { event in
            Button { selectedEvent = event } label: { EventRow(event: event) }
                .buttonStyle(.plain)
                .accessibilityHint("顯示活動詳情")
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailView(event: event) { _ in
                viewModel.register(event)
            }
        }
        .alert(viewModel.alert?.title ?? "", isPresented: Binding(
            get: { viewModel.alert != nil },
            set: { if !$0 { viewModel.alert = nil } }
        ), presenting: viewModel.alert) { alert in
            if alert.kind != .failure {
                Button("查看已報名活動") { showApplied() }
            }
            Button("好", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

// MARK: - 共用列表外框

/// Keeps loading, offline failure, an empty school list and no search matches visibly distinct.
struct EventListScaffold<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let totalCount: Int
    let phase: EventLoadPhase
    let updatedAt: Date?
    @Binding var searchText: String
    let searchHint: String
    let emptyTitle: String
    let emptySymbol: String
    let reload: () -> Void
    let refresh: () async -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            EventSearchField(text: $searchText, hint: searchHint)
            content
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var content: some View {
        if totalCount == 0 {
            switch phase {
            case .idle, .loading:
                ProgressView("正在載入活動…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                EventLoadFailureView(message: message, retry: reload)
            case .loaded:
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptySymbol)
                } description: {
                    Text("校方目前沒有列出活動。")
                } actions: {
                    Button("重新整理", action: reload)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.small) {
                    EventListStatus(phase: phase, updatedAt: updatedAt, retry: reload)
                    if items.isEmpty {
                        ContentUnavailableView.search(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .refreshable { await refresh() }
        }
    }
}

struct EventSearchField: View {
    @Binding var text: String
    let hint: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜尋活動編號或關鍵字", text: $text)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .accessibilityHint(hint)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("清除搜尋")
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, Theme.Spacing.xsmall)
    }
}

/// One fixed row above the list, so refreshing never shifts the cards.
struct EventListStatus: View {
    let phase: EventLoadPhase
    let updatedAt: Date?
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("正在更新…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("更新失敗：\(message)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("重試", action: retry)
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
            case .idle, .loaded:
                if let updatedAt {
                    Text("更新於 \(updatedAt.formatted(date: .omitted, time: .shortened))・下拉可重新整理")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
    }
}

struct EventLoadFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("無法載入活動", systemImage: "exclamationmark.icloud")
        } description: {
            Text(message)
        } actions: {
            Button("重試", action: retry)
                .buttonStyle(.borderedProminent)
            if let url = EventRegistrationClient.websiteURL {
                Link("改用網頁開啟", destination: url)
            }
        }
    }
}

struct EventStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(color)
    }
}

struct EventInfoLine: View {
    let icon: String
    let text: String
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 22

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

extension EventData {
    var stateColor: Color {
        switch event_state {
        case let state where state.contains("報名中"): return .green
        case let state where state.contains("已額滿"): return .red
        case let state where state.contains("即將開始"): return .orange
        default: return .gray
        }
    }
}

// MARK: - 活動列表項目
struct EventRow: View {
    let event: EventData

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                EventStatusBadge(text: event.event_state, color: event.stateColor)
            }
            EventInfoLine(icon: "number", text: "活動編號：\(event.eventSerialID)")
            EventInfoLine(icon: "building.2", text: event.department)
            EventInfoLine(icon: "calendar", text: event.eventTime.replacingOccurrences(of: "\n", with: " "))
            EventInfoLine(icon: "mappin.and.ellipse", text: event.eventLocation)
            EventInfoLine(icon: "person.3", text: event.eventPeople.replacingOccurrences(of: "\n", with: " "))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
