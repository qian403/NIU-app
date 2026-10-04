import SwiftUI

struct EventRegistration_Tab1_View: View {
    @ObservedObject var viewModel: EventRegistration_Tab1_ViewModel
    var showApplied: () -> Void = {}
    var onBatchRegister: (([EventData]) -> Void)? = nil
    @State private var selectedEvent: EventData?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize { controls }
            EventListScaffold(
                items: viewModel.filteredEvents,
                totalCount: viewModel.events.count,
                phase: viewModel.phase,
                updatedAt: viewModel.updatedAt,
                searchText: $viewModel.searchText,
                searchHint: "可搜尋活動編號、名稱、主辦單位或內容",
                emptyTitle: "目前沒有可報名的活動",
                emptySymbol: "calendar.badge.exclamationmark",
                filteredEmptyTitle: viewModel.hasNoFavorites ? "還沒有收藏的活動" : nil,
                scrollingControls: dynamicTypeSize.isAccessibilitySize ? AnyView(
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        controls
                        if viewModel.isSelecting { selectionActions }
                    }
                ) : nil,
                reload: viewModel.reload,
                refresh: viewModel.refresh
            ) { event in
                eventRow(event)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isSelecting && !dynamicTypeSize.isAccessibilitySize { selectionActions }
        }
        .disabled(viewModel.isBusy)
        .onAppear { viewModel.synchronizeFavorites() }
        .onDisappear { viewModel.cancelSelection() }
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

    private var controls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        return layout {
            Toggle(isOn: $viewModel.favoritesOnly) {
                Label("只看收藏", systemImage: "heart.fill")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
            }
            .toggleStyle(.button)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Button {
                if viewModel.isSelecting { viewModel.cancelSelection() }
                else { viewModel.beginSelection() }
            } label: {
                Text(viewModel.isSelecting ? "取消選取" : "選取")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
            }
            .disabled(!viewModel.isSelecting && viewModel.filteredEvents.isEmpty)
        }
        .padding(.horizontal)
    }

    private func eventRow(_ event: EventData) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    if viewModel.isSelecting { viewModel.toggleSelection(event) }
                    else { selectedEvent = event }
                } label: {
                    let cardLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                    cardLayout {
                        if viewModel.isSelecting {
                            Image(systemName: viewModel.selectedIDs.contains(event.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(Color.accentColor)
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityHidden(true)
                        }
                        EventRow(event: event)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    viewModel.beginSelection(event)
                })
                .accessibilityValue(viewModel.isSelecting ? (viewModel.selectedIDs.contains(event.id) ? "已選取" : "未選取") : "")
                .accessibilityHint(viewModel.isSelecting ? "切換選取狀態" : "顯示活動詳情；也可長按進入多選")
                .accessibilityAction(named: Text(viewModel.selectedIDs.contains(event.id) ? "取消選取" : "選取活動")) {
                    viewModel.toggleSelection(event)
                }

                favoriteButton(event)
            }

            EventStatusBadge(text: event.event_state, color: event.stateColor)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private func favoriteButton(_ event: EventData) -> some View {
        let isFavorite = viewModel.favoriteIDs.contains(event.id)
        return Button { viewModel.toggleFavorite(event) } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(isFavorite ? Color.red : Color.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isFavorite ? "取消收藏" : "收藏")：\(event.name)")
        .accessibilityValue(isFavorite ? "已收藏" : "未收藏")
    }

    private var selectionActions: some View {
        VStack(spacing: 4) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout())
            layout {
                Text("已選取 \(viewModel.selectedIDs.count) 個活動")
                    .font(.subheadline.weight(.semibold))
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Button { viewModel.selectAllVisible() } label: {
                    Text("全選目前篩選").frame(minHeight: 44)
                }
                .disabled(viewModel.filteredEvents.isEmpty)
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) { batchButtons }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { batchButtons }
                        VStack(alignment: .leading, spacing: 0) { batchButtons }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(viewModel.selectedIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder private var batchButtons: some View {
        Button { viewModel.favoriteSelection(true) } label: {
            Label("加入收藏", systemImage: "heart.fill").frame(minHeight: 44)
        }
        Button { viewModel.favoriteSelection(false) } label: {
            Label("取消收藏", systemImage: "heart.slash").frame(minHeight: 44)
        }
        if let onBatchRegister {
            Button {
                let events = viewModel.batchRegistrationEvents()
                if !events.isEmpty { onBatchRegister(events) }
            } label: {
                Label("批次報名", systemImage: "person.badge.plus").frame(minHeight: 44)
            }
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
    var filteredEmptyTitle: String? = nil
    var scrollingControls: AnyView? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let reload: () -> Void
    let refresh: () async -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // All controls scroll together so large text never consumes the list viewport.
                ScrollView {
                    VStack(spacing: Theme.Spacing.small) {
                        scrollingControls
                        EventSearchField(text: $searchText, hint: searchHint)
                        if totalCount == 0 { emptyContent }
                        else { listContents }
                    }
                }
                .refreshable { await refresh() }
            } else {
                VStack(spacing: 0) {
                    EventSearchField(text: $searchText, hint: searchHint)
                    if totalCount == 0 { emptyContent }
                    else {
                        ScrollView { listContents }
                            .refreshable { await refresh() }
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch phase {
        case .idle, .loading:
            ProgressView("正在載入活動…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EventLoadFailureView(message: message, retry: reload)
        case .loaded:
            ContentUnavailableView {
                Label(filteredEmptyTitle ?? emptyTitle, systemImage: filteredEmptyTitle == nil ? emptySymbol : "heart")
            } description: {
                Text(filteredEmptyTitle == nil ? "校方目前沒有列出活動。" : "點選活動旁的星號即可收藏，或關閉「只看收藏」查看所有活動。")
            } actions: {
                Button("重新整理", action: reload)
            }
        }
    }

    private var listContents: some View {
        LazyVStack(spacing: Theme.Spacing.small) {
            EventListStatus(phase: phase, updatedAt: updatedAt, retry: reload)
            if items.isEmpty {
                if let filteredEmptyTitle {
                    ContentUnavailableView(filteredEmptyTitle, systemImage: "heart",
                        description: Text("點選活動旁的星號即可收藏，或關閉「只看收藏」查看所有活動。"))
                } else {
                    ContentUnavailableView.search(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
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
/// Activity details stay separate from the card’s favorite button.
struct EventRow: View {
    let event: EventData

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            Text(event.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            EventInfoLine(icon: "number", text: "活動編號：\(event.eventSerialID)")
            EventInfoLine(icon: "building.2", text: event.department)
            EventInfoLine(icon: "calendar", text: event.eventTime.replacingOccurrences(of: "\n", with: " "))
            EventInfoLine(icon: "mappin.and.ellipse", text: event.eventLocation)
            EventInfoLine(icon: "person.3", text: event.eventPeople.replacingOccurrences(of: "\n", with: " "))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
