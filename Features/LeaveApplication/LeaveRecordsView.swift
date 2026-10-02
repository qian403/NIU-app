import SwiftUI
import WebKit

/// 請假首頁: 先看自己的假單（審核結果、可撤回／修改／補檔），再從這裡申請新的請假。
/// Pushed from Home, so it uses the enclosing navigation stack.
@MainActor
struct LeaveRecordsView: View {
    enum Route: Hashable { case apply }

    /// A leave opened from the list; its detail runs in a sheet so this screen (and the
    /// school page mounted in it) stays in the window while it works.
    struct Selection: Identifiable { let id: String }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.openURL) private var openURL
    @StateObject private var model = LeaveRecordsViewModel()
    @State private var selection: Selection?
    @State private var editedInSheet = false
    @State private var needsReload = false
    @State private var showSchoolPage = false
    @State private var isWaitingLong = false

    private let tint = Color.mint
    private var isShowingSchoolPage: Bool { showSchoolPage && model.service != nil }

    var body: some View {
        ZStack {
            if let service = model.service {
                LeaveRecordsWebView(webView: service.webView)
                    .id(ObjectIdentifier(service.webView))
                    .allowsHitTesting(isShowingSchoolPage)
                    .accessibilityHidden(!isShowingSchoolPage)
            }
            content
                .opacity(isShowingSchoolPage ? 0 : 1)
                .allowsHitTesting(!isShowingSchoolPage)
                .accessibilityHidden(isShowingSchoolPage)
        }
        .background(Theme.Colors.groupedBackground)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("請假")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if model.service != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isShowingSchoolPage ? "返回假單" : "校方頁面") { showSchoolPage.toggle() }
                }
            }
        }
        .navigationDestination(for: Route.self) { _ in
            LeaveApplicationView(model: LeaveApplicationViewModel(entry: .apply))
                .onAppear { needsReload = true }
        }
        .onAppear {
            // Back from 申請請假: a new form may now exist.
            if needsReload { needsReload = false; model.load() }
        }
        .task { if !model.hasLoaded && !model.isBusy { model.load() } }
        .task(id: model.isBusy) {
            isWaitingLong = false
            guard model.isBusy, !model.hasLoaded else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if model.isBusy, !model.hasLoaded { withAnimation(Theme.Animation.standard) { isWaitingLong = true } }
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            if model.isBusy, !model.hasLoaded { showSchoolPage = true }
        }
        .sheet(item: $selection, onDismiss: {
            // 修改／補檔 may have changed the school form; query again.
            if editedInSheet { editedInSheet = false; model.load() }
        }) { selected in
            LeaveRecordDetailSheet(model: model, formNo: selected.id, tint: tint) { editedInSheet = true }
                .environmentObject(appState)
        }
        // Covered by 申請請假 keeps this screen (and its school page); only a real pop closes it.
        .onChange(of: isPresented) { _, presented in if !presented { model.close() } }
        .onDisappear { if !isPresented { model.close() } }
        .onChange(of: appState.currentUser?.username) { _, _ in selection = nil; model.close(); dismiss() }
        .onChange(of: appState.isAuthenticated) { _, value in
            if !value { selection = nil; model.close(); dismiss() }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.hasLoaded {
            if let error = model.loadError, !model.isBusy {
                LeaveLoadFailureView(title: "無法讀取請假紀錄", detail: error, tint: tint, retry: model.load) {
                    openURL(LeaveApplicationCopy.dashboard)
                }
            } else {
                LeaveConnectingView(title: "正在讀取你的假單", stage: model.loadStage, isWaitingLong: isWaitingLong, tint: tint) {
                    showSchoolPage = true
                }
            }
        } else {
            List {
                if let message = model.message {
                    Section {
                        LeaveNotice(icon: "info.circle.fill", title: "校方訊息", detail: message, color: Theme.Colors.info)
                        Button("知道了") { model.dismissMessage() }
                    }
                }
                if let error = model.loadError {
                    Section {
                        LeaveNotice(icon: "exclamationmark.triangle.fill", title: "無法更新", detail: error, color: Theme.Colors.warning)
                    }
                }
                if model.items.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                            Text("目前沒有請假紀錄").font(.headline)
                            Text("要請假時，點下方「申請請假」。送出後會在這裡看到校方的審核結果。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Theme.Spacing.xsmall)
                    }
                }
                if !model.actionable.isEmpty {
                    Section {
                        ForEach(model.actionable) { row($0) }
                    } header: {
                        Text("可撤回、修改或補檔")
                    } footer: {
                        Text("點假單查看內容；校方只開放部分狀態的假單做這些操作。")
                    }
                }
                if !model.others.isEmpty {
                    Section(model.actionable.isEmpty ? "請假紀錄" : "其他紀錄") {
                        ForEach(model.others) { row($0) }
                    }
                }
                if let updatedAt = model.updatedAt {
                    Section {
                        EmptyView()
                    } footer: {
                        Text("資料來源：教務系統「請假紀錄」，更新於 \(updatedAt.formatted(date: .omitted, time: .shortened))。下拉可重新整理。")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.reloadAndWait() }
            .overlay(alignment: .top) {
                if model.isBusy {
                    ProgressView().padding(Theme.Spacing.xsmall)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, Theme.Spacing.xsmall)
                        .accessibilityLabel(model.busyMessage)
                }
            }
        }
    }

    /// 申請請假 stays one tap away, also while the list is still loading.
    @ViewBuilder private var bottomBar: some View {
        if isShowingSchoolPage {
            Text("若校方要求登入或驗證，請在此完成，完成後點「返回假單」。")
                .font(.footnote)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
        } else {
            NavigationLink(value: Route.apply) {
                Label("申請請假", systemImage: "plus")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func row(_ item: LeaveRecordsViewModel.Item) -> some View {
        Button { selection = Selection(id: item.record.formNo) } label: {
            HStack {
                LeaveRecordRow(record: item.record, actions: item.actions, tint: tint)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.tertiaryLabel)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看假單內容與可用操作")
    }
}

/// Detail of one leave in its own stack, so 修改／補檔 push inside the sheet.
struct LeaveRecordDetailSheet: View {
    @ObservedObject var model: LeaveRecordsViewModel
    let formNo: String
    let tint: Color
    let didEdit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [LeaveEntry] = []

    var body: some View {
        NavigationStack(path: $path) {
            LeaveRecordDetailView(model: model, formNo: formNo, tint: tint) { entry in
                didEdit()
                path.append(entry)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(model.isWithdrawing)
                }
            }
            .navigationDestination(for: LeaveEntry.self) { entry in
                LeaveApplicationView(model: LeaveApplicationViewModel(entry: entry))
            }
        }
        .interactiveDismissDisabled(model.isWithdrawing)
    }
}

// MARK: - Row

struct LeaveRecordRow: View {
    let record: LeaveRecord
    let actions: LeaveRecordActions
    let tint: Color
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            // At accessibility sizes the badge moves under the title so dates keep the full width.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    LeaveStatusBadge(status: record.status)
                    details
                }
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    VStack(alignment: .leading, spacing: 4) { title; details }
                    Spacer(minLength: Theme.Spacing.xsmall)
                    LeaveStatusBadge(status: record.status)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: some View {
        Text(record.type.isEmpty ? "請假" : record.type).font(.headline)
    }

    @ViewBuilder private var details: some View {
        Text(LeaveRecordFormat.range(record))
            .font(.subheadline)
            .foregroundStyle(Theme.Colors.secondaryLabel)
            .monospacedDigit()
        if actions.any {
            Text(LeaveRecordFormat.actions(actions))
                .font(.caption)
                .foregroundStyle(tint)
        }
    }
}

/// Shows the school's own status text; the icon only supports it.
struct LeaveStatusBadge: View {
    let status: String

    private var style: (icon: String, color: Color) {
        switch status {
        case let s where s.contains("退回"): return ("arrow.uturn.backward.circle.fill", Theme.Colors.warning)
        case let s where s.contains("申請") || s.contains("審核中") || s.contains("簽核"):
            return ("clock.fill", Theme.Colors.info)
        case let s where s.contains("結案") || s.contains("核准") || s.contains("通過"):
            return ("checkmark.circle.fill", Theme.Colors.success)
        default: return ("circle.fill", Theme.Colors.secondaryLabel)
        }
    }

    var body: some View {
        // Explicit icon + text: a Label inside a list row can collapse to its icon only.
        HStack(spacing: 4) {
            Image(systemName: style.icon).accessibilityHidden(true)
            Text(status.isEmpty ? "未知" : status).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(style.color)
        .padding(.horizontal, Theme.Spacing.xsmall)
        .padding(.vertical, 4)
        .background(style.color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

enum LeaveRecordFormat {
    static func range(_ record: LeaveRecord) -> String {
        let dates = record.startDate == record.endDate ? record.startDate : "\(record.startDate) 至 \(record.endDate)"
        return record.totalPeriods.isEmpty ? dates : "\(dates)，\(record.totalPeriods) 節"
    }

    static func actions(_ actions: LeaveRecordActions) -> String {
        [actions.modify ? "修改" : nil, actions.supplement ? "補檔" : nil, actions.withdraw ? "撤回" : nil]
            .compactMap { $0 }.joined(separator: "、") + "可用"
    }
}

// MARK: - Detail

struct LeaveRecordDetailView: View {
    @ObservedObject var model: LeaveRecordsViewModel
    let formNo: String
    let tint: Color
    let edit: (LeaveEntry) -> Void
    @State private var confirmWithdraw = false
    @Environment(\.dismiss) private var dismiss

    private var item: LeaveRecordsViewModel.Item? { model.item(formNo) }

    private var outcomeTitle: String {
        if case .withdrawn = model.withdrawOutcome { return "已撤回假單" }
        return "撤回結果尚未確認"
    }

    private var outcomeMessage: String {
        switch model.withdrawOutcome {
        case .withdrawn(let formNo, let summary):
            return "\(summary)（假單序號 \(formNo)）已撤回，校方的假單列表已不再顯示這張假單。"
        case .uncertain(let text): return text
        case nil: return ""
        }
    }
    private var detail: LeavePage? { model.details[formNo] }

    var body: some View {
        List {
            if let item {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.record.type.isEmpty ? "請假" : item.record.type).font(.title3.bold())
                        Spacer()
                        LeaveStatusBadge(status: item.record.status)
                    }
                    LabeledContent("期間") { Text(LeaveRecordFormat.range(item.record)).monospacedDigit() }
                    if !item.record.startPeriod.isEmpty {
                        LabeledContent("節次") {
                            Text(item.record.startPeriod == item.record.endPeriod
                                 ? "第 \(item.record.startPeriod) 節"
                                 : "第 \(item.record.startPeriod) 至 \(item.record.endPeriod) 節")
                        }
                    }
                    LabeledContent("申請日期") { Text(item.record.appliedDate).monospacedDigit() }
                    LabeledContent("假單序號") { Text(item.record.formNo).monospacedDigit().textSelection(.enabled) }
                }
                detailSections
                if item.actions.any { actionSection(item.actions) }
            } else {
                Section {
                    Text(model.withdrawOutcome == nil ? "這張假單已不在校方列表中，可能已撤回。" : "這張假單已撤回。")
                        .foregroundStyle(.secondary)
                }
            }
            if let message = model.message {
                Section {
                    LeaveNotice(icon: "info.circle.fill", title: "校方訊息", detail: message, color: Theme.Colors.info)
                }
            }
            if model.isBusy {
                Section {
                    HStack(spacing: Theme.Spacing.small) { ProgressView(); Text(model.busyMessage) }
                        .frame(minHeight: 44)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.isWithdrawing {
                // Prominent and blocking: the result follows as an alert.
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    VStack(spacing: Theme.Spacing.small) {
                        ProgressView().controlSize(.large)
                        Text("正在撤回假單").font(.headline)
                        Text("正在等校方處理並重新查詢確認，請勿離開。")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .alert(outcomeTitle, isPresented: Binding(get: { model.withdrawOutcome != nil }, set: { _ in })) {
            Button("好") {
                let succeeded: Bool = { if case .withdrawn = model.withdrawOutcome { return true } else { return false } }()
                model.withdrawOutcome = nil
                if succeeded { dismiss() }
            }
        } message: {
            Text(outcomeMessage)
        }
        .navigationTitle("假單內容")
        .navigationBarTitleDisplayMode(.inline)
        .task { if item != nil { model.loadDetail(formNo) } }
        .confirmationDialog("撤回這張假單？", isPresented: $confirmWithdraw, titleVisibility: .visible) {
            Button("撤回假單", role: .destructive) { model.withdraw(formNo) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("校方會刪除假單 \(formNo)，無法在 App 內復原。需要時請重新申請。")
        }
    }

    @ViewBuilder private var detailSections: some View {
        if let detail {
            if let reason = detail.current?.reason, !reason.isEmpty {
                Section("請假事由") { Text(reason).textSelection(.enabled) }
            }
            if let periods = detail.existingPeriods, !periods.isEmpty {
                Section("請假節次") { ForEach(periods) { LeaveExistingPeriodRow(period: $0) } }
            }
            Section("證明文件") {
                if (detail.attachmentNames ?? []).isEmpty {
                    Text(detail.current?.supplementLater == true ? "尚未附加（申請時選擇稍後補交）" : "未附加證明文件")
                        .foregroundStyle(.secondary)
                }
                ForEach(detail.attachmentNames ?? [], id: \.self) { Label($0, systemImage: "paperclip") }
            }
        } else if let error = model.detailErrors[formNo] {
            Section {
                LeaveNotice(icon: "exclamationmark.triangle.fill", title: "無法讀取事由與節次", detail: error, color: Theme.Colors.warning)
                Button { model.loadDetail(formNo) } label: { Label("重新讀取", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy)
            }
        } else {
            Section {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView()
                    Text("正在讀取事由、節次與附件…").foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
        }
    }

    private func actionSection(_ actions: LeaveRecordActions) -> some View {
        Section {
            if actions.modify {
                Button { edit(.modify(formNo: formNo)) } label: {
                    Label("修改假單", systemImage: "square.and.pencil").frame(minHeight: 44)
                }
            }
            if actions.supplement {
                Button { edit(.supplement(formNo: formNo)) } label: {
                    Label("補交證明文件", systemImage: "doc.badge.plus").frame(minHeight: 44)
                }
            }
            if actions.withdraw {
                Button(role: .destructive) { confirmWithdraw = true } label: {
                    Label("撤回假單", systemImage: "arrow.uturn.backward").frame(minHeight: 44)
                }
            }
        } header: {
            Text("操作")
        } footer: {
            Text("修改與補檔會開啟校方表單；撤回後校方會刪除這張假單。")
        }
        .disabled(model.isBusy)
    }
}

private struct LeaveRecordsWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
