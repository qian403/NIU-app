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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Label(viewModel.module.questionActivityKind?.title ?? "問答",
                          systemImage: viewModel.module.iconName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(viewModel.module.name)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = browser.errorMessage ?? viewModel.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let result = page.result {
                        if page.reviewQuestions != nil {
                            DisclosureGroup("本次作答摘要") {
                                MoodleQuestionResultView(result: result)
                                    .padding(.top, 12)
                            }
                        } else {
                            MoodleQuestionResultView(result: result)
                        }
                    }
                    if let questions = page.reviewQuestions {
                        Label("題目複習", systemImage: "text.book.closed")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text("以下依校方開放的內容顯示，僅供複習，無法修改作答。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                    if (page.result != nil || page.reviewQuestions != nil) && page.fields.isEmpty && !page.text.isEmpty {
                        DisclosureGroup("其他校方說明") {
                            Text(page.text)
                                .font(.subheadline)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    } else if !page.text.isEmpty {
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
                            fieldView(field)
                                .disabled(field.disabled || viewModel.isPerforming || viewModel.isSyncingPage || !browser.isPageReady)
                        }
                        if viewModel.isPerforming {
                            ProgressView("正在等待校方回應，請勿重複送出…")
                                .font(.subheadline)
                        }
                        ForEach(page.actions) { action in
                            Button {
                                focusedField = nil
                                if action.isNavigation == true {
                                    viewModel.perform(action, revision: page.revision)
                                } else {
                                    pendingRevision = page.revision
                                    pendingAction = action
                                }
                            } label: {
                                Text(action.label)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(action.disabled || viewModel.isPerforming || viewModel.isSyncingPage || !browser.isPageReady || browser.errorMessage != nil)
                        }
                        if page.result == nil && page.reviewQuestions == nil && page.text.isEmpty && page.fields.isEmpty && page.actions.isEmpty {
                            ContentUnavailableView("尚無可顯示內容", systemImage: "questionmark.bubble",
                                                   description: Text("可能尚未開放題目，可從右上角查看校方頁面。"))
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
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

    private func fieldView(_ field: MoodleQuestionPage.Field) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(field.label + (field.required ? "（必填）" : ""))
                .font(.headline)
            if field.kind == "single" || field.kind == "multiple" {
                ForEach(field.options) { option in
                    let selected = (viewModel.answers[field.id] ?? []).contains(option.id)
                    Button {
                        if field.kind == "single" { viewModel.answers[field.id] = [option.id] }
                        else {
                            var values = viewModel.answers[field.id] ?? []
                            if selected { values.removeAll { $0 == option.id } }
                            else { values.append(option.id) }
                            viewModel.answers[field.id] = values
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                            Text(option.label)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(option.disabled)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            } else {
                let value = Binding<String>(
                    get: { viewModel.answers[field.id]?.first ?? "" },
                    set: { viewModel.answers[field.id] = [$0] }
                )
                if field.kind == "longText" {
                    TextEditor(text: value)
                        .frame(minHeight: 140)
                        .focused($focusedField, equals: field.id)
                        .accessibilityLabel(field.label)
                } else {
                    TextField("輸入答案", text: value)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: field.id)
                        .accessibilityLabel(field.label)
                }
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
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
