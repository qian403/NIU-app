import SwiftUI
import WebKit

/// 圖書館設備預約。畫面元件分別位於：
/// - `LibraryEquipmentBookingViews.swift`：日期、設備、時段與底部預約列
/// - `LibraryEquipmentReservationViews.swift`：我的預約清單
/// - `LibraryEquipmentComponents.swift`：共用卡片、選項、訊息與格式
struct LibraryEquipmentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(StorageKeys.authSessionID) private var sessionID = ""
    @StateObject private var model = LibraryEquipmentViewModel()
    @State private var showReservations = false
    @State private var cancellation: LibraryEquipmentReservation?
    @State private var isConfirmationPresented = false
    @State private var completionAlert: LibraryEquipmentCompletion?

    init(model: LibraryEquipmentViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? LibraryEquipmentViewModel())
    }

    private var account: String { appState.isAuthenticated ? appState.currentUser?.username ?? "" : "" }
    private var isUpdating: Bool { model.isLoading || model.isMutating }

    var body: some View {
        ZStack(alignment: .topLeading) {
            nativeContent
                .opacity(model.needsLogin ? 0 : 1)
                .allowsHitTesting(!model.needsLogin)
                .accessibilityHidden(model.needsLogin)
            loginHost
        }
        .background(Theme.Colors.groupedBackground)
        .safeAreaInset(edge: .bottom) {
            if !showReservations && !model.needsLogin {
                LibraryEquipmentBookingBar(model: model) { showReservations = true }
            }
        }
        .navigationTitle("設備預約")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.refresh() } label: {
                    if isUpdating {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .accessibilityLabel(isUpdating ? "正在更新" : "重新整理設備與我的預約")
                .disabled(isUpdating || model.needsLogin)
            }
        }
        .environment(\.calendar, LibraryEquipmentDate.calendar)
        .environment(\.timeZone, LibraryEquipmentDate.calendar.timeZone)
        .task(id: account + sessionID) { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.recheckSelection() }
        }
        .sheet(item: $model.confirmation, onDismiss: {
            isConfirmationPresented = false
            completionAlert = model.completion
        }) { draft in
            LibraryEquipmentConfirmationSheet(model: model, draft: draft)
                .onAppear { isConfirmationPresented = true }
        }
        .onChange(of: model.completion) { _, result in
            if result == nil || !isConfirmationPresented { completionAlert = result }
        }
        .alert(completionAlert?.title ?? "操作完成", isPresented: Binding(
            get: { completionAlert != nil },
            set: { if !$0 { completionAlert = nil; model.dismissCompletion() } }
        )) {
            if completionAlert?.kind == .reserved {
                Button("查看我的預約") { showReservations = true; completionAlert = nil; model.dismissCompletion() }
            }
            Button("知道了", role: .cancel) { completionAlert = nil; model.dismissCompletion() }
        } message: {
            Text(completionAlert?.message ?? "")
        }
        .alert("取消這筆預約？", isPresented: Binding(
            get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }
        )) {
            Button("保留預約", role: .cancel) { cancellation = nil }
            Button("取消預約", role: .destructive) {
                if let record = cancellation { model.cancel(record) }
                cancellation = nil
            }
        } message: {
            if let record = cancellation {
                Text("\(record.equipmentName)\n\(LibraryEquipmentText.dateTime(record.start)) 至 \(LibraryEquipmentText.dateTime(record.end))")
            }
        }
    }

    // MARK: Native content

    private var nativeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                    Picker("設備預約頁面", selection: $showReservations) {
                        Text("預約設備").tag(false)
                        Text(model.reservations.isEmpty ? "我的預約" : "我的預約（\(model.reservations.count)）").tag(true)
                    }
                    .pickerStyle(.segmented)
                    syncStatus
                }
                statusMessages
                if showReservations {
                    LibraryEquipmentReservationList(model: model) { cancellation = $0 }
                } else {
                    LibraryEquipmentBookingForm(model: model)
                }
                footer
            }
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : Theme.Animation.easeInOut, value: model.errorMessage)
            .animation(reduceMotion ? nil : Theme.Animation.easeInOut, value: model.notice)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refreshAndWait() }
    }

    /// 固定高度的資料狀態列；更新中只替換文字，不推擠下方內容。
    private var syncStatus: some View {
        HStack(spacing: 6) {
            if isUpdating {
                ProgressView().controlSize(.mini)
                Text(model.isMutating ? "正在送交校方，請稍候…" : "正在更新校方資料…")
            } else {
                Image(systemName: "building.columns")
                Text("來源：圖書館系統 · 最後更新：\(updatedText)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var updatedText: String {
        let date = showReservations ? model.reservationsUpdatedAt : model.updatedAt
        return date.map { LibraryEquipmentDate.format($0, pattern: "MM/dd HH:mm") } ?? "尚未更新"
    }

    @ViewBuilder private var statusMessages: some View {
        if model.needsVerification {
            LibraryEquipmentBanner(.warning,
                message: model.notice ?? LibraryEquipmentError.uncertainMutation.localizedDescription) {
                if !showReservations {
                    Button("查看我的預約") { showReservations = true }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
            }
        } else if let notice = model.notice {
            LibraryEquipmentBanner(.success, message: notice)
        }
        if let error = model.errorMessage {
            LibraryEquipmentBanner(.error, message: error) {
                Button("重新整理") { model.refresh() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(isUpdating)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
            if let url = URL(string: "https://webpacx.niu.edu.tw/equipment") {
                Link(destination: url) {
                    Label("開啟校方設備預約網站", systemImage: "safari")
                }
                .font(.footnote)
                .frame(minHeight: 44)
            }
            Text("本頁提供單日時段預約。全日、多日或週期預約請使用校方網站。資料與預約結果以圖書館系統為準。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Library login

    /// Keep a single browser host mounted while changing its visible size.
    private var loginHost: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if model.needsLogin { loginHeader }
            if let webView = model.webView {
                LibraryEquipmentBrowser(webView: webView)
                    .frame(maxWidth: model.needsLogin ? .infinity : 1,
                           maxHeight: model.needsLogin ? .infinity : 1)
                    .opacity(model.needsLogin ? 1 : 0.01)
                    .allowsHitTesting(model.needsLogin)
                    .accessibilityHidden(!model.needsLogin)
            }
            if model.needsLogin { loginActions }
        }
        .padding(model.needsLogin ? Theme.Spacing.medium : 0)
        .frame(maxWidth: model.needsLogin ? .infinity : 1,
               maxHeight: model.needsLogin ? .infinity : 1, alignment: .topLeading)
    }

    private var loginHeader: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: "person.badge.key.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
                Text("請完成圖書館登入或人機驗證")
                    .font(.headline)
                Text(model.errorMessage ?? "請使用與 App 相同的帳號登入，完成後按下方「我已完成登入，繼續」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var loginActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.small) {
                resumeLoginButton
                reloadLoginButton
            }
            VStack(spacing: Theme.Spacing.xsmall) {
                resumeLoginButton
                reloadLoginButton
            }
        }
    }

    private var resumeLoginButton: some View {
        Button { model.resumeLogin() } label: {
            Text("我已完成登入，繼續").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isLoading)
    }

    private var reloadLoginButton: some View {
        Button { model.start() } label: {
            Text("重新載入登入頁").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.isLoading)
    }
}

// MARK: - Confirmation

struct LibraryEquipmentConfirmationSheet: View {
    @ObservedObject var model: LibraryEquipmentViewModel
    let draft: LibraryEquipmentDraft

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Theme.Colors.accentSoft,
                                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.equipment.name).font(.headline)
                            Text(draft.group.name).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xxsmall)
                    .accessibilityElement(children: .combine)
                }
                Section {
                    LabeledContent("日期", value: "\(LibraryEquipmentDate.format(draft.date))（\(LibraryEquipmentDate.weekday(draft.date))）")
                    LabeledContent("時段", value: draft.timeLabel)
                    LabeledContent("時長", value: "\(LibraryEquipmentText.hours(minutes: draft.endMinute - draft.startMinute)) 小時")
                    LabeledContent("目前剩餘額度", value: "\(LibraryEquipmentText.hours(draft.policy.remainingHours)) 小時")
                } header: {
                    Text("預約內容")
                } footer: {
                    Text("送出時會再次核對時段與校方規則。預約完成後，請依圖書館規定報到。")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { model.submit() } label: {
                    HStack(spacing: Theme.Spacing.xsmall) {
                        if model.isMutating { ProgressView() }
                        Text(model.isMutating ? "正在送出…" : "確認並送出預約")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isMutating || model.isLoading)
                .padding(Theme.Spacing.medium)
                .background(.bar)
            }
            .navigationTitle("確認設備預約")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { model.confirmation = nil }.disabled(model.isMutating)
                }
            }
            .interactiveDismissDisabled(model.isMutating)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Browser host

private struct LibraryEquipmentBrowser: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        mount(in: container)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) { mount(in: uiView) }
    private func mount(in container: UIView) {
        for previous in container.subviews where previous !== webView {
            previous.removeFromSuperview()
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}
