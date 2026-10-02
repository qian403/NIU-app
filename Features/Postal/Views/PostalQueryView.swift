import SwiftUI

struct PostalQueryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: PostalQueryViewModel
    @StateObject private var manualModel: PostalQueryViewModel
    @State private var showsOtherQuery = false
    private let accent = Color.brown

    init(model: PostalQueryViewModel? = nil, manualModel: PostalQueryViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? PostalQueryViewModel())
        _manualModel = StateObject(wrappedValue: manualModel ?? PostalQueryViewModel())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                if let ownName = model.ownName {
                    personalHeader(name: ownName)
                    PostalStatusSelector(selection: model.query.status) { model.selectOwnStatus($0) }
                    PostalQueryResults(model: model, isPersonal: true)
                    Button { showsOtherQuery = true } label: {
                        HStack {
                            Label("其他查詢", systemImage: "magnifyingglass")
                            Spacer()
                            Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 48)
                        .padding(.horizontal, Theme.Spacing.medium)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
                    }
                    .buttonStyle(.plain)
                    .tint(accent)
                    .accessibilityIdentifier("postal.otherQuery")
                    PostalQueryFooter(model: model)
                } else {
                    Text("尚無登入姓名，可輸入收件人、手機或郵件號碼查詢。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    PostalManualQueryContent(model: manualModel)
                }
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("郵件包裹查詢")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear(perform: prepareOwnMail)
        .onChange(of: appState.currentUser) { old, new in
            if old?.username != new?.username { clearManualQuery() }
            prepareOwnMail()
        }
        .onChange(of: appState.isAuthenticated) { _, authenticated in
            if !authenticated { clearManualQuery() }
            prepareOwnMail()
        }
        .onDisappear {
            model.reset()
            manualModel.reset()
        }
        .sheet(isPresented: $showsOtherQuery, onDismiss: { manualModel.cancelWork() }) {
            NavigationStack {
                ScrollView {
                    PostalManualQueryContent(model: manualModel)
                        .padding(Theme.Spacing.medium)
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("其他查詢")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsOtherQuery = false }
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func personalHeader(name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                Text("我的包裹").font(.title2.bold())
                refreshButton
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("我的包裹").font(.title2.bold())
                    Spacer()
                    refreshButton
                }
            }
            Text("收件人：\(name)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text("依登入姓名查詢")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button { model.search() } label: {
            Label("重新整理", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
        }
        .tint(accent)
        .disabled(model.isLoading)
        .accessibilityIdentifier("postal.refresh")
    }

    private func prepareOwnMail() {
        let hadOwnName = model.ownName != nil
        let user = appState.isAuthenticated ? appState.currentUser : nil
        model.prepare(account: user?.username, name: user?.name)
        // Preserve an in-progress manual query if the profile arrives after this screen opens.
        if !hadOwnName, model.ownName != nil, manualModel.query.canSearch {
            showsOtherQuery = true
        }
    }

    private func clearManualQuery() {
        showsOtherQuery = false
        manualModel.reset()
    }
}

private struct PostalManualQueryContent: View {
    @ObservedObject var model: PostalQueryViewModel
    @State private var showMoreFilters = false
    @FocusState private var focusedField: Field?
    private let accent = Color.brown
    private enum Field { case name, phone, tracking }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            searchCard
            PostalQueryResults(model: model, isPersonal: false)
            PostalQueryFooter(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label("查詢條件", systemImage: "magnifyingglass")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("收件人").font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    Image(systemName: "person").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("輸入收件人姓名", text: $model.query.name)
                        .textContentType(nil)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .name)
                        .submitLabel(.search)
                        .onSubmit(search)
                        .accessibilityLabel("收件人姓名")
                }
                .padding(14)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("領取狀態").font(.subheadline.weight(.medium))
                PostalStatusSelector(selection: model.query.status) { model.query.status = $0 }
            }

            DisclosureGroup(isExpanded: $showMoreFilters) {
                VStack(spacing: 12) {
                    extraField("手機號碼", placeholder: "輸入收件手機號碼", text: $model.query.phone, field: .phone)
                        .keyboardType(.phonePad)
                    extraField("郵件／包裹號碼", placeholder: "輸入郵件或包裹號碼", text: $model.query.trackingNumber, field: .tracking)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("至少填寫一項；多個條件會一起查詢。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 12)
            } label: {
                Text("更多查詢條件").font(.subheadline)
                    .frame(minHeight: 44)
            }
            .tint(accent)

            Button(action: search) {
                HStack(spacing: 8) {
                    if model.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(model.isLoading ? "正在查詢…" : "查詢郵件與包裹")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background(model.query.canSearch ? accent : Color.secondary,
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
            }
            .buttonStyle(.plain)
            .disabled(!model.query.canSearch || model.isLoading)
        }
        .padding(Theme.Spacing.medium)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.xlarge))
    }

    private func extraField(_ title: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(placeholder, text: text)
                .focused($focusedField, equals: field)
                .submitLabel(.search)
                .onSubmit(search)
                .accessibilityLabel(title)
                .padding(14)
                .background(Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
        }
    }

    private func search() {
        guard model.query.canSearch else { return }
        focusedField = nil
        model.search()
    }
}

private struct PostalStatusSelector: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selection: PostalStatus
    let onSelect: (PostalStatus) -> Void
    private let accent = Color.brown

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) { buttons }
            } else {
                HStack(spacing: 8) { buttons }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("領取狀態")
    }

    private var buttons: some View {
        ForEach(PostalStatus.allCases) { status in
            Button {
                onSelect(status)
            } label: {
                Label(status.title, systemImage: status.symbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(selection == status ? accent : Color.secondary)
                    .background(selection == status ? accent.opacity(0.13) : Color(uiColor: .tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                    .overlay {
                        if selection == status {
                            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                                .strokeBorder(accent.opacity(0.6), lineWidth: 1.5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == status ? .isSelected : [])
        }
    }

}

private struct PostalQueryResults: View {
    @ObservedObject var model: PostalQueryViewModel
    let isPersonal: Bool
    private let accent = Color.brown

    @ViewBuilder var body: some View {
        if let message = model.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label("查詢未完成", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                Button("重新查詢") { model.search() }.frame(minHeight: 44).tint(accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.medium)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
        }
        if let submitted = model.resultQuery {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text("查詢結果").font(.title3.bold())
                    Spacer()
                    Text("\(submitted.status.title) · \(model.records.count) 筆")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !isPersonal && !submitted.name.isEmpty {
                    Text("收件人：\(submitted.name)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if model.filtersChanged {
                    Label("條件已變更，請再次點選查詢。下方為上次結果。", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.records.isEmpty {
                    stateCard(icon: "tray", title: isPersonal && submitted.status == .waiting ? "目前沒有待領郵件" : "查無\(submitted.status.title)郵件",
                              description: isPersonal ? "可切換領取狀態查看其他紀錄，或稍後重新整理。" : "請確認查詢條件，或切換領取狀態再查詢。")
                } else {
                    LazyVStack(spacing: Theme.Spacing.medium) {
                        ForEach(model.records) { record in PostalRecordCard(record: record) }
                    }
                }
                if let page = model.page, page.pageIndex + 1 < page.pageCount {
                    if page.nextForm != nil {
                        Button { model.loadMore() } label: {
                            Text(model.isLoading ? "正在載入…" : "載入更多結果")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered).tint(accent)
                        .disabled(model.isLoading || model.filtersChanged)
                    } else {
                        Text("校方另有更多結果，請增加姓名、手機或郵件號碼條件以縮小範圍。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("已載入 \(page.pageIndex + 1)／\(page.pageCount) 頁")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if model.errorMessage == nil {
            stateCard(icon: model.isLoading ? "ellipsis.circle" : "tray.and.arrow.down",
                      title: model.isLoading ? "正在向校方查詢" : "查詢收件紀錄",
                      description: model.isLoading ? "正在取得最新資料，請稍候。" : "填寫查詢條件，查看是否有待領的郵件與包裹。")
        }
    }

    private func stateCard(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 10) {
            if model.isLoading && model.resultQuery == nil {
                ProgressView().tint(accent)
            } else {
                Image(systemName: icon).font(.title).foregroundStyle(accent.opacity(0.8)).accessibilityHidden(true)
            }
            Text(title).font(.headline)
            Text(description).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.large)
        .padding(.horizontal, Theme.Spacing.medium)
    }

}

private struct PostalQueryFooter: View {
    @ObservedObject var model: PostalQueryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("領取提醒", systemImage: "info.circle").font(.subheadline.weight(.medium))
            Text("領取地點、開放時間及所需證件，請以校方通知為準。")
            Text("依姓名查詢的結果，請核對收件單位與郵件號碼。")
            if let date = model.updatedAt {
                Text("查詢時間：\(date.formatted(date: .abbreviated, time: .shortened))")
            }
            Text("資料來源：國立宜蘭大學郵務收發管理系統")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.bottom, Theme.Spacing.medium)
    }

}

private struct PostalRecordCard: View {
    let record: PostalRecord
    private var tint: Color {
        switch record.status {
        case .waiting: return .brown
        case .collected: return .green
        case .returned: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.category.isEmpty ? "郵件／包裹" : record.category).font(.headline)
                    Text("收件日期 \(record.receivedDate)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Label(record.status.title, systemImage: record.status.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(tint.opacity(0.1), in: Capsule())
            Divider()
            field("收件人", record.recipient)
            field("收件單位", record.unit)
            field("郵件號碼", record.trackingNumber)
            field("數量", record.quantity)
            field("簽收資訊", record.signature)
            field(record.status == .returned ? "退件日期" : "簽收日期", record.completedDate)
            if !record.note.isEmpty {
                Text(record.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(Theme.Spacing.medium)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
    }

    @ViewBuilder private func field(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(title) {
                Text(value).foregroundStyle(.primary).textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
        }
    }
}
