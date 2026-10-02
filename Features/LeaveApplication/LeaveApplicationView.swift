import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor
struct LeaveApplicationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LeaveApplicationViewModel()
    @State private var showImporter = false
    @State private var showReview = false
    @State private var showSchoolPage = false
    @State private var isWaitingLong = false
    @State private var confirmSupplement = false
    @FocusState private var reasonFocused: Bool

    private let tint = Color.mint

    init(model: LeaveApplicationViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? LeaveApplicationViewModel())
    }

    private var isShowingSchoolPage: Bool { showSchoolPage && model.service != nil }
    private var isForm: Bool { model.page?.kind == "form" && !model.didAttemptSubmit }

    var body: some View {
        ZStack {
            // The school page stays mounted at full size so its scripts run normally;
            // it is revealed when the school needs the user to log in or verify.
            if let service = model.service {
                LeaveApplicationWebView(webView: service.webView)
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
        .navigationTitle(model.entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if model.service != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isShowingSchoolPage ? "返回表單" : "校方頁面") { showSchoolPage.toggle() }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { reasonFocused = false }
            }
        }
        .task { if model.page == nil && !model.isBusy { model.load() } }
        .task(id: model.service.map(ObjectIdentifier.init)) {
            showSchoolPage = false; isWaitingLong = false
            guard model.service != nil else { return }
            // After 8 s offer the school page; after 20 s reveal it so a login
            // or verification step the school requires is never left hidden.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard model.isBusy, model.page == nil else { return }
            withAnimation(Theme.Animation.standard) { isWaitingLong = true }
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            if model.isBusy, model.page == nil { showSchoolPage = true }
        }
        .onChange(of: model.page?.kind) { _, kind in if kind != nil { showSchoolPage = false } }
        .onDisappear { if !showReview && !showImporter { model.close() } }
        .onChange(of: appState.currentUser?.username) { _, _ in reset() }
        .onChange(of: appState.isAuthenticated) { _, value in if !value { reset() } }
        .onChange(of: model.canReview) { _, value in if value { showReview = true } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .jpeg, .png]) { result in
            if case .success(let url) = result { model.upload(url) }
        }
        .sheet(isPresented: $showReview, onDismiss: { model.acknowledged = false }) {
            LeaveReviewSheet(model: model, tint: tint) { showReview = false }
        }
        .confirmationDialog("送出補交的證明文件？", isPresented: $confirmSupplement, titleVisibility: .visible) {
            Button("送出") { model.acknowledged = true; model.submitSupplement() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會按下校方表單的「送出」。送出後請回到假單列表確認附件。")
        }
        .alert("校方確認", isPresented: Binding(
            get: { model.schoolConfirmation != nil },
            set: { _ in }
        )) {
            Button("取消", role: .cancel) { model.answerSchoolConfirmation(false) }
            Button("繼續") { model.answerSchoolConfirmation(true) }
        } message: { Text(model.schoolConfirmation ?? "") }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if model.page == nil && !model.didAttemptSubmit {
            if let error = model.loadError, !model.isBusy {
                LeaveLoadFailureView(title: model.entry == .apply ? "無法開啟請假表單" : "無法開啟這張假單",
                                     detail: error, tint: tint, retry: model.load) {
                    openURL(LeaveApplicationCopy.dashboard)
                }
            } else {
                LeaveConnectingView(title: model.entry == .apply ? "正在開啟請假表單" : "正在開啟假單",
                                    stage: model.loadStage, isWaitingLong: isWaitingLong, tint: tint) {
                    showSchoolPage = true
                }
            }
        } else {
            formList
        }
    }

    private var formList: some View {
        List {
            if (model.page != nil || model.didAttemptSubmit) && !model.isSupplement {
                Section {
                    LeaveStepIndicator(steps: model.steps, current: model.currentStep, tint: tint)
                        .listRowInsets(EdgeInsets(top: Theme.Spacing.small, leading: Theme.Spacing.medium,
                                                  bottom: Theme.Spacing.small, trailing: Theme.Spacing.medium))
                }
            }
            status
            if model.didAttemptSubmit {
                submitted
            } else if model.page?.kind == "notice" {
                notice
            } else if model.page?.kind == "form" && model.isSupplement {
                supplement
            } else if model.page?.kind == "form" {
                form
            }
            Section {
                Button { openURL(LeaveApplicationCopy.dashboard) } label: {
                    Label("在校務系統開啟", systemImage: "safari")
                }
            } footer: {
                Text("資料來源：國立宜蘭大學教務行政資訊系統。App 不保存請假內容與附件。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var status: some View {
        if model.isBusy {
            Section {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView()
                    Text(model.loadingMessage)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        } else if let error = model.loadError {
            Section {
                LeaveNotice(icon: "exclamationmark.triangle.fill", title: "無法完成操作", detail: error, color: Theme.Colors.warning)
            }
        }
        if let message = model.message, !model.didAttemptSubmit {
            Section {
                LeaveNotice(icon: "info.circle.fill", title: "校方訊息", detail: message, color: Theme.Colors.info)
            }
        }
    }

    private var notice: some View {
        Section {
            Text(model.page?.notice ?? "")
                .font(.callout)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.vertical, Theme.Spacing.xxsmall)
        } header: {
            Text("校方請假注意事項")
        } footer: {
            Text("讀完後點下方「我已閱讀，開始填寫」。")
        }
    }

    @ViewBuilder private var form: some View {
        Section {
            Picker("假別", selection: $model.leaveType) {
                Text("請選擇").tag("")
                ForEach(model.page?.options ?? []) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.menu)
            DatePicker("開始", selection: $model.startDate, displayedComponents: .date)
            DatePicker("結束", selection: $model.endDate, in: model.startDate..., displayedComponents: .date)
        } header: {
            Text("假別與日期")
        } footer: {
            Text("共 \(model.dayCount) 天。考試週請選擇「期中、期末考試假」。")
        }
        .disabled(model.isBusy)

        Section {
            TextField("例如：發燒就醫，附診斷證明", text: $model.reason, axis: .vertical)
                .lineLimit(3...8)
                .focused($reasonFocused)
        } header: {
            Text("請假事由")
        } footer: {
            Text("如有調課，請選原課表節次，並在事由寫上實際上課日期。")
        }
        .disabled(model.isBusy)

        periodSection
        attachmentSection
    }

    @ViewBuilder private var periodSection: some View {
        Section {
            if !model.hasLoadedPeriods {
                Button { model.loadPeriods() } label: {
                    Label("查詢這段期間的課程", systemImage: "magnifyingglass")
                        .frame(minHeight: 44)
                }
                .disabled(model.isBusy)
            } else if model.periods.isEmpty {
                Text("這段期間沒有可請假的課程節次，請調整日期。")
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            }
        } header: {
            HStack {
                Text("請假節次")
                Spacer()
                if model.hasLoadedPeriods, !model.periods.isEmpty {
                    Text("已選 \(model.selected.count) 節").monospacedDigit()
                }
            }
        } footer: {
            if case .modify = model.entry, !model.existingPeriods.isEmpty {
                Text("原本申請 \(model.existingPeriods.count) 節，查詢後會預先勾選。送出修改後以這次勾選的節次為準。")
            }
        }

        ForEach(model.hasLoadedPeriods ? model.periodDays : [], id: \.self) { day in
            let dayPeriods = model.periods.filter { $0.date == day }
            let allSelected = dayPeriods.allSatisfy { model.selected.contains($0.id) }
            Section {
                ForEach(dayPeriods) { period in
                    LeavePeriodRow(period: period, isSelected: model.selected.contains(period.id), tint: tint) {
                        model.togglePeriod(period.id)
                    }
                    .disabled(model.isBusy)
                }
            } header: {
                HStack {
                    Text(LeaveApplicationDate.display(roc: day))
                    Spacer()
                    Button(allSelected ? "取消整天" : "整天") { model.toggleDay(day) }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                        .disabled(model.isBusy)
                        .accessibilityLabel(allSelected ? "取消選取 \(LeaveApplicationDate.display(roc: day)) 全部節次"
                                            : "選取 \(LeaveApplicationDate.display(roc: day)) 全部節次")
                }
            }
        }
    }

    private var attachmentSection: some View {
        Section {
            ForEach(model.page?.attachmentNames ?? [], id: \.self) { name in
                Label(name, systemImage: "paperclip").font(.subheadline)
            }
            Button { showImporter = true } label: {
                Label("附加證明文件", systemImage: "doc.badge.plus").frame(minHeight: 44)
            }
            .disabled(model.isBusy)
            if !model.isSupplement {
                Toggle("證明文件稍後補交", isOn: $model.supplementLater)
                    .disabled(model.isBusy)
            }
        } header: {
            Text("證明文件")
        } footer: {
            Text(model.isSupplement
                 ? "PDF、JPG 或 PNG，單一檔案 10 MB 以內。選擇後會立即上傳到校方系統，附加完成再按下方「送出補交」。"
                 : "PDF、JPG 或 PNG，單一檔案 10 MB 以內。選擇後會立即上傳到校方系統。")
        }
    }

    private var submitted: some View {
        Section {
            LeaveNotice(icon: "doc.text.magnifyingglass", title: "請確認校方紀錄",
                        detail: model.message ?? "已按下送出，正在等待校方回應。", color: tint)
            Text("返回假單列表會重新查詢，可看到這張假單目前的內容與審核結果；附件請在校務系統逐項確認。")
                .font(.footnote).foregroundStyle(.secondary)
            Button { dismiss() } label: {
                Label("返回假單列表", systemImage: "list.bullet.rectangle").frame(minHeight: 44)
            }
        }
    }

    /// 補檔: the school locks every field (Mode=DETAIL) and only accepts new attachments.
    @ViewBuilder private var supplement: some View {
        Section {
            LabeledContent("假單序號") { Text(model.entry.formNo ?? "").monospacedDigit() }
            if let saved = model.page?.current {
                LabeledContent("假別", value: model.page?.options?.first { $0.id == saved.leaveType }?.title ?? saved.leaveType)
                LabeledContent("期間") {
                    Text(saved.startDate == saved.endDate ? saved.startDate : "\(saved.startDate) 至 \(saved.endDate)")
                        .monospacedDigit()
                }
                if !saved.reason.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("事由").font(.subheadline).foregroundStyle(.secondary)
                        Text(saved.reason)
                    }
                }
            }
        } header: {
            Text("假單內容")
        } footer: {
            Text("補檔只能附加證明文件；要改假別、日期、節次或事由，請改用「修改」。")
        }
        if !model.existingPeriods.isEmpty {
            Section("請假節次") {
                ForEach(model.existingPeriods) { LeaveExistingPeriodRow(period: $0) }
            }
        }
        attachmentSection
    }

    // MARK: - Bottom bar

    @ViewBuilder private var bottomBar: some View {
        if isShowingSchoolPage {
            Text("若校方要求登入或驗證，請在此完成，完成後點「返回表單」。")
                .font(.footnote)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
        } else if model.didAttemptSubmit {
            actionBar {
                Button { openURL(LeaveApplicationCopy.dashboard) } label: {
                    Label("前往校務系統確認", systemImage: "safari")
                        .fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(tint)
            }
        } else if model.isSupplement && model.page?.kind == "form" {
            actionBar {
                HStack(spacing: Theme.Spacing.small) {
                    Text(model.attachmentNames.isEmpty ? "請先附加證明文件" : "已附加 \(model.attachmentNames.count) 個檔案")
                        .font(.subheadline)
                        .foregroundStyle(model.attachmentNames.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { confirmSupplement = true } label: {
                        Text("送出補交").fontWeight(.semibold).frame(minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent).tint(tint)
                    .disabled(!model.canSubmitSupplement)
                }
            }
        } else if model.page?.kind == "notice" {
            actionBar {
                Button { model.acceptNotice() } label: {
                    Text("我已閱讀，開始填寫").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(tint)
                .disabled(model.isBusy)
            }
        } else if isForm && !reasonFocused {
            // Hidden while typing: above the keyboard's floating toolbar the bar left
            // a transparent gap where the list showed through.
            actionBar {
                HStack(spacing: Theme.Spacing.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.leaveTypeTitle ?? "尚未選擇假別")
                            .font(.subheadline.weight(.semibold))
                        Text(model.missingRequirement ?? "已選 \(model.selected.count) 節，可以檢查送出")
                            .font(.caption)
                            .foregroundStyle(model.missingRequirement == nil ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    Button { reasonFocused = false; model.prepareReview() } label: {
                        Text("檢查並送出").fontWeight(.semibold).frame(minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent).tint(tint)
                    .disabled(!model.hasValidDraft)
                }
            }
        }
    }

    /// Sticky bar for the screen's primary action, kept apart from the list content.
    private func actionBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }

    private func reset() {
        showReview = false; showImporter = false; showSchoolPage = false; model.close()
    }
}

// MARK: - Components

/// The steps the school's form requires; a real sequence, so it is numbered.
/// Connectors are drawn as separate segments between circles, never behind them.
struct LeaveStepIndicator: View {
    let steps: [LeaveApplicationViewModel.Step]
    let current: LeaveApplicationViewModel.Step
    let tint: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 28

    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }

    var body: some View {
        // The labels cannot fit side by side at accessibility sizes; name only the current step.
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                track(showsLabels: false)
                Text("第 \(currentIndex + 1)／\(steps.count) 步：\(current.title)")
                    .font(.subheadline.weight(.semibold))
            }
        } else {
            track(showsLabels: true)
        }
    }

    private func track(showsLabels: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        connector(visible: index > 0, done: index <= currentIndex)
                        marker(index: index)
                        connector(visible: index < steps.count - 1, done: index < currentIndex)
                    }
                    .frame(height: diameter)
                    if showsLabels {
                        Text(step.title)
                            .font(.caption2.weight(index == currentIndex ? .semibold : .regular))
                            .foregroundStyle(index == currentIndex ? Theme.Colors.label : Theme.Colors.secondaryLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("第 \(index + 1) 步，\(step.title)，\(status(index))")
            }
        }
        .padding(.vertical, Theme.Spacing.xxsmall)
    }

    private func status(_ index: Int) -> String {
        index < currentIndex ? "已完成" : index == currentIndex ? "目前步驟" : "尚未開始"
    }

    private func marker(index: Int) -> some View {
        let done = index < currentIndex
        let active = index == currentIndex
        return ZStack {
            Circle()
                .fill(done || active ? tint : Color.clear)
            Circle()
                .strokeBorder(done || active ? Color.clear : Theme.Colors.opaqueSeparator, lineWidth: 1.5)
            if done {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
            } else {
                Text("\(index + 1)").font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(active ? .white : Theme.Colors.secondaryLabel)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func connector(visible: Bool, done: Bool) -> some View {
        // Flat ends: the two halves of a connector meet without a visible seam.
        Rectangle()
            .fill(visible ? (done ? tint : Theme.Colors.opaqueSeparator) : Color.clear)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }
}

/// First screen while reaching the school's form: shows the real phases instead of a bare spinner.
struct LeaveConnectingView: View {
    var title = "正在開啟請假表單"
    let stage: LeaveLoadStage
    let isWaitingLong: Bool
    let tint: Color
    let showSchoolPage: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var badge: CGFloat = 72

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: badge * 0.45, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: badge, height: badge)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title2.bold())
                    Text("使用你在 App 的登入連到教務系統，不需要再輸入帳號密碼。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Colors.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(LeaveLoadStage.allCases, id: \.self) { item in
                        stageRow(item)
                    }
                }
                .padding(Theme.Spacing.medium)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))

                if isWaitingLong {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("比平常久一些")
                            .font(.subheadline.weight(.semibold))
                        Text("校方可能要求登入或驗證。打開校方頁面看看，完成後點「返回表單」。")
                            .font(.subheadline)
                            .foregroundStyle(Theme.Colors.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: showSchoolPage) {
                            Label("查看校方頁面", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(tint)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.xlarge)
            .padding(.bottom, Theme.Spacing.large)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.groupedBackground)
    }

    private func stageRow(_ item: LeaveLoadStage) -> some View {
        let done = item.rawValue < stage.rawValue
        let active = item == stage
        return HStack(spacing: Theme.Spacing.small) {
            ZStack {
                if active {
                    ProgressView().controlSize(.small)
                } else if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                } else {
                    Image(systemName: "circle").foregroundStyle(Theme.Colors.tertiaryLabel)
                }
            }
            .font(.body)
            .frame(width: 24, height: 24)
            Text(item.title)
                .font(.body.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.Colors.label : done ? Theme.Colors.secondaryLabel : Theme.Colors.tertiaryLabel)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title)，\(done ? "已完成" : active ? "進行中" : "等待中")")
    }
}

/// Initial load failure: says what happened and offers the two useful actions.
struct LeaveLoadFailureView: View {
    var title = "無法開啟請假表單"
    let detail: String
    let tint: Color
    let retry: () -> Void
    let openSchool: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.Colors.warning)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                Text(detail)
                    .font(.body)
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Theme.Spacing.small) {
                    Button(action: retry) {
                        Label("重新連線", systemImage: "arrow.clockwise")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    Button(action: openSchool) {
                        Label("在校務系統開啟", systemImage: "safari")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(tint)
                }
                .padding(.top, Theme.Spacing.small)
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.xlarge)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.groupedBackground)
    }
}

private struct LeavePeriodRow: View {
    let period: LeavePeriod
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.small) {
                Text(period.period.isEmpty ? "—" : period.period)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Theme.Colors.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 56, height: 36)
                    .background(isSelected ? tint : Theme.Colors.tertiaryFill,
                                in: RoundedRectangle(cornerRadius: Theme.CornerRadius.xsmall, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(period.course.isEmpty ? "未命名課程" : period.course)
                        .foregroundStyle(Theme.Colors.label)
                    HStack(spacing: Theme.Spacing.xsmall) {
                        if !period.teacher.isEmpty { Text(period.teacher) }
                        if !period.room.isEmpty { Text(period.room) }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.secondaryLabel)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? tint : Theme.Colors.tertiaryLabel)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(LeaveApplicationDate.display(roc: period.date)) \(period.period) \(period.course) \(period.teacher)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A saved period from the school's「本次請假日期與節次明細」.
struct LeaveExistingPeriodRow: View {
    let period: LeaveExistingPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(period.course.isEmpty ? "未命名課程" : period.course)
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(LeaveApplicationDate.display(roc: period.date))
                Text("第 \(period.period) 節")
                if !period.teacher.isEmpty { Text(period.teacher) }
            }
            .font(.caption)
            .foregroundStyle(Theme.Colors.secondaryLabel)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct LeaveNotice: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Spacing.xxsmall)
        .accessibilityElement(children: .combine)
    }
}

private struct LeaveReviewSheet: View {
    @ObservedObject var model: LeaveApplicationViewModel
    let tint: Color
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("假別", value: model.leaveTypeTitle ?? "")
                    LabeledContent("期間") {
                        Text(LeaveApplicationDate.string(model.startDate) == LeaveApplicationDate.string(model.endDate)
                             ? LeaveApplicationDate.string(model.startDate)
                             : "\(LeaveApplicationDate.string(model.startDate)) 至 \(LeaveApplicationDate.string(model.endDate))")
                            .monospacedDigit()
                    }
                    LabeledContent("節次", value: "\(model.selected.count) 節")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("事由").font(.subheadline).foregroundStyle(.secondary)
                        Text(model.trimmedReason)
                    }
                } header: { Text("申請內容") }

                Section {
                    ForEach(model.selectedPeriods) { period in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(period.course)
                            Text("\(LeaveApplicationDate.display(roc: period.date)) \(period.period)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("課程") }

                Section {
                    if (model.page?.attachmentNames ?? []).isEmpty {
                        Text("未附加證明文件").foregroundStyle(.secondary)
                    }
                    ForEach(model.page?.attachmentNames ?? [], id: \.self) { Label($0, systemImage: "paperclip") }
                    LabeledContent("稍後補交", value: model.supplementLater ? "是" : "否")
                } header: { Text("證明文件") }

                Section {
                    Toggle(isOn: $model.acknowledged) {
                        Text(LeaveApplicationCopy.acknowledgement).font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tint(tint)
                    .accessibilityIdentifier("leave.submissionAcknowledgement")
                } footer: {
                    Text("送出會直接寫入校方請假紀錄，無法在 App 內撤回。")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.submit(); dismiss()
                } label: {
                    Text(model.entry == .apply ? "送出請假申請" : "送出修改").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(tint)
                .disabled(!model.acknowledged || !model.hasValidDraft || !model.canReview)
                .accessibilityIdentifier("leave.submit")
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .background(.bar)
            }
            .navigationTitle(model.entry == .apply ? "送出前確認" : "確認修改內容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回修改", action: dismiss) } }
        }
    }
}

private struct LeaveApplicationWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
