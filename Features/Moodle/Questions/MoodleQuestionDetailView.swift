import SwiftUI
import WebKit

struct MoodleQuestionDetailView: View {
    let module: MoodleModule
    @StateObject private var viewModel: MoodleQuestionDetailViewModel

    init(module: MoodleModule) {
        self.module = module
        _viewModel = StateObject(wrappedValue: MoodleQuestionDetailViewModel(module: module))
    }

    var body: some View {
        MoodleQuestionDetailContent(viewModel: viewModel, browser: viewModel.browser)
            .navigationTitle(module.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.run() }
            .onDisappear { viewModel.stop() }
    }
}

private struct MoodleQuestionDetailContent: View {
    @ObservedObject var viewModel: MoodleQuestionDetailViewModel
    @ObservedObject var browser: MoodleWebManager
    @State private var pendingAction: MoodleQuestionPage.Action?
    @State private var pendingRevision = ""
    @State private var confirmedAction: MoodleQuestionPage.Action?
    @State private var confirmsReload = false
    @FocusState private var focusedField: String?
    @State private var openPicker: String?

    private var showsWeb: Bool {
        viewModel.showsSchoolPage || browser.questionNeedsWebInteraction
    }

    var body: some View {
        ZStack {
            // Keep the same school document mounted for authentication, AJAX and
            // form validation. Native controls are the normal visible interface.
            MoodleQuestionBrowserHost(manager: browser)
                .opacity(showsWeb ? 1 : 0.01)
                .allowsHitTesting(showsWeb)
                .accessibilityHidden(!showsWeb)
            if !showsWeb {
                nativeContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
        }
        .safeAreaInset(edge: .top) {
            if browser.questionNeedsWebInteraction {
                Label("請完成 M 園區登入或驗證，完成後會返回題目。", systemImage: "person.crop.circle")
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(viewModel.showsSchoolPage ? "返回原生介面" : "查看校方頁面",
                           systemImage: viewModel.showsSchoolPage ? "list.bullet.rectangle" : "globe") {
                        focusedField = nil
                        if viewModel.showsSchoolPage { viewModel.returnToNativePage() }
                        else { viewModel.openSchoolPage() }
                    }
                    Button("重新開啟活動", systemImage: "arrow.clockwise") { confirmsReload = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("問答選項")
            }
        }
        .sheet(item: $pendingAction, onDismiss: {
            if let action = confirmedAction {
                confirmedAction = nil
                viewModel.perform(action, revision: pendingRevision)
            }
        }) { action in
            NavigationStack {
                VStack(alignment: .leading, spacing: 20) {
                    Text("將在 M 園區執行「\(action.label)」。開始或送出作答可能影響測驗次數與成績，請確認答案後繼續。")
                    Button(action.label) {
                        confirmedAction = action
                        pendingAction = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    Spacer()
                }
                .padding(20)
                .navigationTitle("確認操作")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { pendingAction = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("重新開啟活動？", isPresented: $confirmsReload) {
            Button("重新開啟") { focusedField = nil; viewModel.reload() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("尚未送出的輸入將清除。若剛執行過送出，請先查看校方頁面確認紀錄。")
        }
    }

    @ViewBuilder
    private var nativeContent: some View {
        if let page = viewModel.page {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let message = browser.errorMessage ?? viewModel.errorMessage {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if page.isQuizFlow {
                            quizContent(page)
                        } else {
                            genericContent(page)
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    // The summary lists every question itself; keep its bar for the countdown only.
                    if page.isQuizFlow, page.stage == "attempt" && !(page.navigation ?? []).isEmpty ||
                        (page.stage == "attempt" || page.stage == "summary") && page.timerSeconds != nil {
                        answerCardBar(page, proxy: proxy)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if page.isQuizFlow { quizActionBar(page) }
                }
            }
            .onChange(of: viewModel.answers) { viewModel.answersChanged() }
        } else if let error = browser.errorMessage ?? viewModel.errorMessage {
            ContentUnavailableView {
                Label("問答載入失敗", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重試") { viewModel.reload() }
                Button("查看校方頁面") { viewModel.openSchoolPage() }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在讀取題目…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isBusy: Bool {
        viewModel.isPerforming || viewModel.isSyncingPage || !browser.isPageReady || browser.errorMessage != nil
    }

    /// Quiz steps follow Moodle's own confirmations (start preflight, submit dialog),
    /// so only other activities get the extra native confirmation sheet.
    private func run(_ action: MoodleQuestionPage.Action, on page: MoodleQuestionPage) {
        focusedField = nil
        if action.isNavigation == true || page.isQuizFlow {
            viewModel.perform(action, revision: page.revision)
        } else {
            pendingRevision = page.revision
            pendingAction = action
        }
    }

    private func jump(to item: MoodleQuestionPage.NavigationItem, on page: MoodleQuestionPage, proxy: ScrollViewProxy) {
        if item.current, let question = page.questions?.first(where: { $0.number == item.number }) {
            withAnimation { proxy.scrollTo(question.id, anchor: .top) }
            return
        }
        focusedField = nil
        // Moodle's navigation handler saves this page before moving.
        viewModel.perform(.init(id: item.id, label: item.number, disabled: false,
                                fieldIDs: page.fields.map(\.id), isNavigation: true),
                          revision: page.revision)
    }

    // MARK: Quiz stages

    @ViewBuilder
    private func quizContent(_ page: MoodleQuestionPage) -> some View {
        switch page.stage {
        case "overview": overviewContent(page)
        case "attempt": attemptContent(page)
        case "summary": summaryContent(page)
        case "confirm": confirmContent(page)
        default: reviewContent(page)
        }
    }

    @ViewBuilder
    private func overviewContent(_ page: MoodleQuestionPage) -> some View {
        Text(viewModel.module.name)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
        if !page.text.isEmpty {
            Text(page.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let result = page.result {
            MoodleQuestionResultView(result: result)
        }
        let reviews = page.actions.filter { $0.role == "review" }
        if reviews.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                Text("複習作答").font(.headline).padding(.bottom, 4)
                ForEach(reviews) { action in
                    Button { run(action, on: page) } label: {
                        HStack {
                            Text(action.label.replacingOccurrences(of: "：", with: " "))
                            Spacer()
                            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                }
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        otherActions(page)
    }

    @ViewBuilder
    private func attemptContent(_ page: MoodleQuestionPage) -> some View {
        let questions = page.questions ?? []
        ForEach(questions) { question in
            questionCard(question, fields: page.fields.filter { $0.questionID == question.id })
                .id(question.id)
        }
        // Controls outside a quiz question (rare) still need to be answerable.
        ForEach(page.fields.filter { field in !questions.contains { $0.id == field.questionID } }) { field in
            fieldBlock(field)
                .padding(18)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
        }
        if !page.text.isEmpty {
            Text(page.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        otherActions(page)
    }

    private func questionCard(_ question: MoodleQuestionPage.Question, fields: [MoodleQuestionPage.Field]) -> some View {
        let answered = !fields.isEmpty && fields.allSatisfy(isAnswered)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("第 \(question.number) 題")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !fields.isEmpty {
                    HStack(spacing: 6) {
                        AnswerMark(filled: answered, square: false)
                            .frame(width: 18, height: 10)
                        Text(answered ? "已作答" : "未作答")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !question.text.isEmpty {
                Text(question.text)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(fields) { field in
                fieldBlock(field)
                    .disabled(field.disabled || isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func summaryContent(_ page: MoodleQuestionPage) -> some View {
        let items = page.navigation ?? []
        let open = items.filter { $0.state == "unanswered" || $0.state == "invalid" }
        Text("交卷前檢查")
            .font(.title2.weight(.bold))
        Text(items.isEmpty ? "確認答案後即可交卷。" :
                open.isEmpty ? "全部 \(items.count) 題都已作答。" :
                "還有 \(open.count) 題未作答。點題號可回到該題。")
            .font(.body)
            .foregroundStyle(open.isEmpty ? Color.secondary : Color.orange)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    Button { focusedField = nil; viewModel.perform(.init(id: item.id, label: item.number, disabled: false,
                                                                          fieldIDs: [], isNavigation: true),
                                                                    revision: page.revision) } label: {
                        HStack(spacing: 14) {
                            AnswerBubble(number: item.number, filled: item.state == "answered",
                                         invalid: item.state == "invalid", current: false)
                            Text(item.status.isEmpty ? (item.state == "answered" ? "已作答" : "未作答") : item.status)
                                .foregroundStyle(item.state == "answered" ? Color.secondary : Color.primary)
                            Spacer()
                            if item.flagged { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel("第 \(item.number) 題，\(item.status)")
                    if item.id != items.last?.id { Divider().padding(.leading, 56) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        if !page.text.isEmpty {
            Label(page.text, systemImage: "calendar.badge.clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        otherActions(page)
    }

    @ViewBuilder
    private func confirmContent(_ page: MoodleQuestionPage) -> some View {
        let lines = page.text.components(separatedBy: "\n").filter { $0 != page.title }
        let warnings = lines.filter { $0.contains("尚未作答") || $0.contains("未回答") }
        Text(page.title.isEmpty ? "確認" : page.title)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 24)
        ForEach(lines.filter { !warnings.contains($0) }, id: \.self) { line in
            Text(line).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(warnings, id: \.self) { line in
            Label(line, systemImage: "exclamationmark.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
        if page.stage == "confirm", page.actions.contains(where: { $0.role == "confirm" }) {
            Text("這是校方的確認步驟，按下後才會正式送出。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func reviewContent(_ page: MoodleQuestionPage) -> some View {
        Text(viewModel.module.name)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
        if let result = page.result {
            MoodleQuestionResultView(result: result)
        }
        if let questions = page.reviewQuestions {
            Text("題目複習")
                .font(.headline)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(questions) { question in
                MoodleReviewQuestionCard(question: question) {
                    viewModel.openReviewQuestion(question.id)
                }
            }
            if questions.isEmpty {
                Text("校方目前未顯示本頁題目。若下方有分頁，可切換查看其他題目。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        if !page.text.isEmpty {
            DisclosureGroup("其他校方說明") {
                Text(page.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        otherActions(page)
    }

    /// Actions without a known quiz role (e.g. review pagination) stay available, but quiet.
    @ViewBuilder
    private func otherActions(_ page: MoodleQuestionPage) -> some View {
        let others = page.actions.filter { $0.role == nil }
        if !others.isEmpty {
            VStack(spacing: 8) {
                ForEach(others) { action in
                    Button { run(action, on: page) } label: {
                        Text(action.label).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(action.disabled || isBusy)
                }
            }
        }
    }

    // MARK: Fixed bars

    private func answerCardBar(_ page: MoodleQuestionPage, proxy: ScrollViewProxy) -> some View {
        let items = page.navigation ?? []
        let answered = items.filter { isAnswered($0, on: page) }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if page.stage == "attempt", !items.isEmpty {
                    Text("已作答 \(answered)／\(items.count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer()
                if let seconds = page.timerSeconds { TimerChip(seconds: seconds) }
            }
            if page.stage == "attempt", !items.isEmpty {
                ScrollViewReader { strip in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(items) { item in
                                Button { jump(to: item, on: page, proxy: proxy) } label: {
                                    AnswerBubble(number: item.number, filled: isAnswered(item, on: page),
                                                 invalid: item.state == "invalid", current: item.current)
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .disabled(isBusy && !item.current)
                                .id(item.id)
                                .accessibilityLabel("第 \(item.number) 題，\(isAnswered(item, on: page) ? "已作答" : "未作答")\(item.current ? "，在這一頁" : "")")
                            }
                        }
                    }
                    .onAppear { if let id = items.first(where: \.current)?.id { strip.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, page.stage == "attempt" ? 0 : 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func quizActionBar(_ page: MoodleQuestionPage) -> some View {
        let primaryRoles = ["start", "next", "finish", "submit", "confirm", "done"]
        let primary = page.actions.first { primaryRoles.contains($0.role ?? "") }
        let secondary = page.actions.first { ["previous", "resume", "cancel"].contains($0.role ?? "") } ??
            (page.stage == "overview" ? page.actions.first { $0.role == "review" } : nil)
        if primary != nil || secondary != nil || viewModel.isPerforming {
            HStack(spacing: 12) {
                if viewModel.isPerforming {
                    ProgressView()
                    Text("正在等待校方回應…").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    if let secondary {
                        Button { run(secondary, on: page) } label: {
                            Text(title(for: secondary))
                                .lineLimit(1)
                                .frame(maxWidth: primary == nil ? .infinity : nil, minHeight: 44)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(secondary.disabled || isBusy)
                    }
                    if let primary {
                        Button { run(primary, on: page) } label: {
                            Text(title(for: primary))
                                .font(.headline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(primary.role == "confirm" || primary.role == "submit" ? .orange : .accentColor)
                        .disabled(primary.disabled || isBusy)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// One verb per step:「交卷」is used from the last page through the school dialog.
    private func title(for action: MoodleQuestionPage.Action) -> String {
        switch action.role {
        case "next": "下一頁"
        case "previous": "上一頁"
        case "finish": "檢查並交卷"
        case "submit": "交卷"
        case "resume": "返回作答"
        case "review": "複習上次作答"
        case "done": "完成複習"
        default: action.label.replacingOccurrences(of: "...", with: "").replacingOccurrences(of: "…", with: "")
        }
    }

    // MARK: Answer state

    private func isAnswered(_ field: MoodleQuestionPage.Field) -> Bool {
        let values = viewModel.answers[field.id] ?? field.values
        if field.kind == "order" {
            // Moodle shows a default order; it only counts once moved or already saved.
            let saved = viewModel.page?.questions?.first { $0.id == field.questionID }?.state.contains("尚未") == false
            return values != field.values || saved
        }
        if field.options.isEmpty {
            return !(values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return values.contains { value in field.options.contains { $0.id == value && $0.blank != true } }
    }

    /// Bubbles on this page follow native input live; other pages use Moodle's saved state.
    private func isAnswered(_ item: MoodleQuestionPage.NavigationItem, on page: MoodleQuestionPage) -> Bool {
        guard item.current, let question = page.questions?.first(where: { $0.number == item.number }) else {
            return item.state == "answered"
        }
        let fields = page.fields.filter { $0.questionID == question.id }
        return fields.isEmpty ? item.state == "answered" : fields.allSatisfy(isAnswered)
    }

    // MARK: Generic activities (choice, feedback, IRS…)

    @ViewBuilder
    private func genericContent(_ page: MoodleQuestionPage) -> some View {
        Label(viewModel.module.questionActivityKind?.title ?? "問答",
              systemImage: viewModel.module.iconName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        Text(viewModel.module.name)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
        if let result = page.result {
            MoodleQuestionResultView(result: result)
        }
        if !page.text.isEmpty {
            Text(page.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        if let reason = page.webReason {
            VStack(alignment: .leading, spacing: 12) {
                Label(reason, systemImage: "info.circle")
                Button("使用校方操作介面") { viewModel.openSchoolPage() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.subheadline)
        } else {
            ForEach(page.fields) { field in
                fieldBlock(field)
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    .disabled(field.disabled || isBusy)
            }
            if viewModel.isPerforming {
                ProgressView("正在等待校方回應，請勿重複送出…")
                    .font(.subheadline)
            }
            ForEach(page.actions) { action in
                Button { run(action, on: page) } label: {
                    Text(action.label)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(action.disabled || isBusy)
            }
            if page.result == nil && page.text.isEmpty && page.fields.isEmpty && page.actions.isEmpty {
                ContentUnavailableView("尚無可顯示內容", systemImage: "questionmark.bubble",
                                       description: Text("可能尚未開放題目，可從右上角查看校方頁面。"))
            }
        }
    }

    // MARK: Fields

    private func fieldBlock(_ field: MoodleQuestionPage.Field) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let context = field.context, !context.isEmpty {
                Text(context)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if field.questionID == nil || (field.part != nil && field.kind != "order") {
                Text((field.questionID == nil ? field.label : field.part ?? "") + (field.required ? "（必填）" : ""))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch field.kind {
            case "order": orderView(field)
            // Blanks and matching stems share one option set; a picker keeps each row short.
            case "single" where field.part != nil: compactPicker(field)
            case "single", "multiple": optionList(field)
            default: textInput(field)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func optionList(_ field: MoodleQuestionPage.Field) -> some View {
        let values = viewModel.answers[field.id] ?? []
        let choices = field.options.filter { $0.blank != true }
        VStack(spacing: 8) {
            ForEach(choices) { option in
                let selected = values.contains(option.id)
                let parts = OptionText(option.label)
                Button {
                    if field.kind == "single" { viewModel.answers[field.id] = [option.id] }
                    else {
                        var next = values
                        if selected { next.removeAll { $0 == option.id } } else { next.append(option.id) }
                        viewModel.answers[field.id] = next
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        AnswerMark(filled: selected, square: field.kind == "multiple", marker: parts.marker)
                            .frame(width: 34, height: 22)
                        Text(parts.text)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 48)
                    .background(selected ? Color.primary.opacity(0.07) : Color(.tertiarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? Color.primary.opacity(0.5) : .clear, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(option.disabled)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
            // A placeholder entry means Moodle lets the student clear this blank.
            if let blank = field.options.first(where: { $0.blank == true }),
               values.contains(where: { value in choices.contains { $0.id == value } }) {
                Button("清除這格的選擇") { viewModel.answers[field.id] = [blank.id] }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }

    /// Blanks and matching stems: one short row that expands its options in place.
    private func compactPicker(_ field: MoodleQuestionPage.Field) -> some View {
        let values = viewModel.answers[field.id] ?? []
        let choices = field.options.filter { $0.blank != true }
        let selected = choices.first { values.contains($0.id) }
        let open = openPicker == field.id
        return VStack(spacing: 6) {
            Button {
                withAnimation(.snappy) { openPicker = open ? nil : field.id }
            } label: {
                HStack(spacing: 12) {
                    AnswerMark(filled: selected != nil, square: false)
                        .frame(width: 22, height: 14)
                    Text(selected?.label ?? "選擇答案")
                        .foregroundStyle(selected == nil ? Color.secondary : Color.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(field.part ?? field.label)
            .accessibilityValue(selected?.label ?? "未作答")
            .accessibilityHint(open ? "收合選項" : "展開選項")
            if open {
                ForEach(choices) { option in
                    let chosen = option.id == selected?.id
                    Button {
                        viewModel.answers[field.id] = [option.id]
                        withAnimation(.snappy) { openPicker = nil }
                    } label: {
                        HStack(spacing: 12) {
                            AnswerMark(filled: chosen, square: false)
                                .frame(width: 22, height: 14)
                            Text(option.label)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 24)
                        .padding(.trailing, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(option.disabled)
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                }
                if selected != nil, let blank = field.options.first(where: { $0.blank == true }) {
                    Button("清除這格") {
                        viewModel.answers[field.id] = [blank.id]
                        withAnimation(.snappy) { openPicker = nil }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.leading, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func textInput(_ field: MoodleQuestionPage.Field) -> some View {
        let value = Binding<String>(
            get: { viewModel.answers[field.id]?.first ?? "" },
            set: { viewModel.answers[field.id] = [$0] }
        )
        if field.kind == "longText" {
            TextEditor(text: value)
                .frame(minHeight: 160)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .focused($focusedField, equals: field.id)
                .accessibilityLabel(field.part ?? field.label)
        } else {
            TextField("輸入答案", text: value)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .focused($focusedField, equals: field.id)
                .submitLabel(.done)
                .accessibilityLabel(field.part ?? field.label)
        }
    }

    private func orderView(_ field: MoodleQuestionPage.Field) -> some View {
        let order = viewModel.answers[field.id] ?? field.values
        return VStack(spacing: 8) {
            ForEach(Array(order.enumerated()), id: \.element) { index, id in
                let label = field.options.first { $0.id == id }?.label ?? ""
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 28)
                        .foregroundStyle(.secondary)
                    Text(label)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.snappy) { move(field, order: order, from: index, to: index - 1) }
                    } label: {
                        Image(systemName: "arrow.up").frame(width: 44, height: 44)
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("上移「\(label)」")
                    Button {
                        withAnimation(.snappy) { move(field, order: order, from: index, to: index + 1) }
                    } label: {
                        Image(systemName: "arrow.down").frame(width: 44, height: 44)
                    }
                    .disabled(index == order.count - 1)
                    .accessibilityLabel("下移「\(label)」")
                }
                .padding(.leading, 6)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .buttonStyle(.borderless)
                .accessibilityElement(children: .contain)
                .accessibilityValue("第 \(index + 1) 項，共 \(order.count) 項")
            }
        }
    }

    private func move(_ field: MoodleQuestionPage.Field, order: [String], from: Int, to: Int) {
        guard order.indices.contains(from), order.indices.contains(to) else { return }
        var values = order
        values.swapAt(from, to)
        viewModel.answers[field.id] = values
    }
}

private extension MoodleQuestionPage {
    /// Moodle quiz pages get the step-by-step layout; anything needing the school UI does not.
    var isQuizFlow: Bool {
        webReason == nil && ["overview", "attempt", "summary", "confirm", "review"].contains(stage ?? "")
    }
}

/// Splits Moodle numbering (「a. 」「1. 」) from the option text so it can sit in the bubble.
private struct OptionText {
    let marker: String?
    let text: String

    init(_ label: String) {
        if let match = label.firstMatch(of: #/^([A-Za-z]|\d{1,2})[.)．、]\s*/#) {
            marker = String(match.1).uppercased()
            text = String(label[match.range.upperBound...])
        } else {
            marker = nil
            text = label
        }
    }
}

/// The answer-card mark: hollow when empty, filled like a pencilled bubble when chosen.
private struct AnswerMark: View {
    let filled: Bool
    let square: Bool
    var marker: String? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: square ? 5 : 11, style: .continuous)
        ZStack {
            shape.fill(filled ? Color(.label) : .clear)
            shape.strokeBorder(Color(.label).opacity(filled ? 0 : 0.45), lineWidth: 1.5)
            if let marker {
                Text(marker)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(filled ? Color(.systemBackground) : .secondary)
            } else if filled && square {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color(.systemBackground))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct AnswerBubble: View {
    let number: String
    let filled: Bool
    let invalid: Bool
    let current: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(number)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(filled ? Color(.systemBackground) : .primary)
                .frame(minWidth: 30, minHeight: 22)
                .padding(.horizontal, 3)
                .background { Capsule().fill(filled ? Color(.label) : .clear) }
                .overlay {
                    Capsule().strokeBorder(invalid ? Color.red : Color(.label).opacity(filled ? 0 : 0.45),
                                           lineWidth: invalid ? 2 : 1.5)
                }
            Capsule()
                .fill(current ? Color.accentColor : .clear)
                .frame(width: 14, height: 3)
        }
        .accessibilityHidden(true)
    }
}

private struct TimerChip: View {
    let seconds: Int

    var body: some View {
        let tone: Color = seconds <= 60 ? .red : seconds <= 300 ? .orange : .secondary
        Label(text, systemImage: "timer")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tone == .secondary ? Color.primary : tone)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tone.opacity(0.14), in: Capsule())
            .accessibilityLabel("剩餘時間 \(seconds / 60) 分 \(seconds % 60) 秒；時間到會由校方自動交卷")
    }

    private var text: String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MoodleReviewQuestionCard: View {
    let question: MoodleQuestionPage.ReviewQuestion
    let openSchoolQuestion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(question.title).font(.headline)
                    Spacer(minLength: 12)
                    mark
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.title).font(.headline)
                    mark
                }
            }
            .accessibilityAddTraits(.isHeader)
            if !question.status.isEmpty {
                Label(question.status, systemImage: verdictIcon(question.verdict))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(verdictColor(question.verdict))
            }
            if !question.text.isEmpty {
                Text(question.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !question.prompt.isEmpty {
                Text(question.prompt).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(question.choices) { choice in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: choice.selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(choice.selected ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        Text(choice.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if choice.selected || choice.verdict != nil {
                        HStack(spacing: 12) {
                            if choice.selected {
                                Text("你的選擇").foregroundStyle(Color.accentColor)
                            }
                            if let verdict = choice.verdict {
                                Label(verdictLabel(verdict), systemImage: verdictIcon(verdict))
                                    .foregroundStyle(verdictColor(verdict))
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                    if !choice.feedback.isEmpty {
                        Text(choice.feedback).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(choice.selected ? Color.accentColor.opacity(0.08) : Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(choice.selected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
            }
            if !question.responses.isEmpty {
                reviewSection("你的作答", text: question.responses.map { $0.isEmpty ? "未填答" : $0 }.joined(separator: "\n"))
            }
            if !question.correctAnswer.isEmpty || !question.feedback.isEmpty ||
                !question.generalFeedback.isEmpty || !question.comment.isEmpty {
                Divider()
                reviewSection("正確答案", text: question.correctAnswer)
                reviewSection("作答回饋", text: question.feedback)
                reviewSection("題目解析", text: question.generalFeedback)
                reviewSection("教師評語", text: question.comment)
            }
            if let reason = question.webReason {
                Label(reason, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("查看本題完整內容", systemImage: "arrow.up.forward.square", action: openSchoolQuestion)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var mark: some View {
        Text(question.mark)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func reviewSection(_ title: String, text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func verdictColor(_ verdict: String?) -> Color {
        switch verdict {
        case "correct": return .green
        case "incorrect": return .red
        case "partiallycorrect": return .orange
        default: return .secondary
        }
    }

    private func verdictIcon(_ verdict: String?) -> String {
        switch verdict {
        case "correct": return "checkmark.circle"
        case "incorrect": return "xmark.circle"
        case "partiallycorrect": return "minus.circle"
        default: return "info.circle"
        }
    }

    private func verdictLabel(_ verdict: String) -> String {
        switch verdict {
        case "correct": return "正確"
        case "incorrect": return "錯誤"
        case "partiallycorrect": return "部分正確"
        default: return "校方判定"
        }
    }
}

private struct MoodleQuestionResultView: View {
    let result: MoodleQuestionPage.ResultSummary

    var body: some View {
        if let grade = result.grade {
            VStack(alignment: .leading, spacing: 12) {
                Label(result.gradeLabel ?? "成績", systemImage: "chart.bar.doc.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(grade)
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                    }
            }
            .accessibilityElement(children: .combine)
        }

        if !result.attempts.isEmpty {
            Text("作答紀錄")
                .font(.headline)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(result.attempts) { attempt in
                VStack(alignment: .leading, spacing: 16) {
                    Text(attempt.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let status = attempt.details.first(where: isStatus) {
                        Label(status.value, systemImage: statusIcon(status.value))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("\(status.label)：\(status.value)")
                    }
                    detailRows(attempt.details.filter { !isStatus($0) })
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }

        ForEach(result.notices, id: \.self) { notice in
            Label {
                Text(notice)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }

        if !result.information.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Label("測驗資訊", systemImage: "calendar")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                detailRows(result.information, isInformation: true)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func detailRows(
        _ details: [MoodleQuestionPage.ResultSummary.Detail], isInformation: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(details) { detail in
                if detail.id != details.first?.id { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayLabel(detail.label, isInformation: isInformation))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(detail.value)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func displayLabel(_ label: String, isInformation: Bool) -> String {
        guard isInformation else { return label }
        switch label {
        case "開始", "Opened", "Opens": return "開放時間"
        case "結束", "Closed", "Closes": return "截止時間"
        default: return label
        }
    }

    private func isStatus(_ detail: MoodleQuestionPage.ResultSummary.Detail) -> Bool {
        ["作答狀態", "狀態", "status", "state"].contains(detail.label.lowercased())
    }

    private func statusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "已經完成", "已完成", "完成", "finished": return "checkmark.circle"
        case "進行中", "in progress": return "clock"
        default: return "info.circle"
        }
    }
}

private struct MoodleQuestionBrowserHost: UIViewRepresentable {
    let manager: MoodleWebManager
    func makeUIView(context: Context) -> WKWebView { manager.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
