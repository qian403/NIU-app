import Combine
import Foundation
import WebKit

@MainActor
final class MoodleQuestionDetailViewModel: ObservableObject {
    @Published private(set) var page: MoodleQuestionPage?
    @Published var answers: [String: [String]] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPerforming = false
    @Published private(set) var showsSchoolPage = false
    @Published private(set) var isSyncingPage = false
    let browser: MoodleWebManager
    let module: MoodleModule

    private var generation = 0
    private var isActive = false
    private var pageGeneration = 0
    private var actionTask: Task<Void, Never>?
    private var submittedRevision: String?
    private var submissionStarted: Date?
    private var sessionRevision: Int?
    private var needsAnswerSync = false

    init(module: MoodleModule) {
        self.module = module
        browser = MoodleWebManager()
    }

    func run() async {
        guard let url = module.questionActivityURL else {
            errorMessage = "目前無法開啟此活動。"
            return
        }
        generation &+= 1
        isActive = true
        let current = generation
        let revision = MoodleService.shared.sessionRevision
        if sessionRevision != revision {
            page = nil
            answers = [:]
            errorMessage = nil
            isPerforming = false
            submittedRevision = nil
            submissionStarted = nil
            showsSchoolPage = false
            needsAnswerSync = false
            isSyncingPage = false
        }
        sessionRevision = revision
        pageGeneration &+= 1
        browser.loadWithSSO(targetURL: url.absoluteString)
        defer {
            if generation == current { stop() }
        }
        var failures = 0
        while !Task.isCancelled, generation == current {
            guard sessionRevision == MoodleService.shared.sessionRevision else {
                page = nil
                answers = [:]
                errorMessage = "登入狀態已變更，請返回課程後重新開啟。"
                return
            }
            if browser.isPageReady && !browser.questionNeedsWebInteraction && browser.errorMessage == nil && !browser.webView.isLoading {
                do {
                    let pageRequest = pageGeneration
                    let snapshot = try await readPage()
                    guard !Task.isCancelled, generation == current else { return }
                    guard sessionRevision == MoodleService.shared.sessionRevision else {
                        page = nil
                        answers = [:]
                        errorMessage = "登入狀態已變更，請返回課程後重新開啟。"
                        return
                    }
                    guard pageRequest == pageGeneration else { continue }
                    accept(snapshot)
                    failures = 0
                } catch {
                    guard !Task.isCancelled, generation == current else { return }
                    failures += 1
                    if failures >= 3 {
                        errorMessage = "暫時無法讀取題目，請重試或查看校方頁面。"
                    }
                }
            }
            if let start = submissionStarted, Date().timeIntervalSince(start) > 15 {
                errorMessage = "尚未取得可確認的校方回應。請查看校方頁面確認作答紀錄，避免重複送出。"
                // Keep submission locked until a different school document/control
                // set is received, or the user explicitly returns to the entry page.
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    private func readPage() async throws -> MoodleQuestionPage {
        _ = try await browser.webView.evaluateJavaScript(MoodleQuestionPageScript.install)
        let value = try await browser.webView.evaluateJavaScript(MoodleQuestionPageScript.snapshot)
        guard let text = value as? String, let data = text.data(using: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return try JSONDecoder().decode(MoodleQuestionPage.self, from: data)
    }

    private func accept(_ snapshot: MoodleQuestionPage) {
        if page?.revision != snapshot.revision || showsSchoolPage || needsAnswerSync {
            if page != nil && !isPerforming && !showsSchoolPage && !needsAnswerSync &&
                answers != page?.fields.reduce(into: [:], { $0[$1.id] = $1.values }) {
                errorMessage = "校方題目或選項已更新，請重新確認答案。"
            } else {
                errorMessage = nil
            }
            answers = Dictionary(uniqueKeysWithValues: snapshot.fields.map { ($0.id, $0.values) })
            needsAnswerSync = false
            isSyncingPage = false
        }
        if let submittedRevision, submittedRevision != snapshot.revision {
            isPerforming = false
            submissionStarted = nil
            self.submittedRevision = nil
        }
        if page != snapshot { page = snapshot }
    }

    func perform(_ action: MoodleQuestionPage.Action, revision: String) {
        guard isActive, !isPerforming, !isSyncingPage, revision == page?.revision, page?.webReason == nil,
              browser.isPageReady, !browser.questionNeedsWebInteraction, !browser.webView.isLoading,
              browser.errorMessage == nil,
              sessionRevision == MoodleService.shared.sessionRevision else { return }
        isPerforming = true
        errorMessage = nil
        submittedRevision = revision
        submissionStarted = Date()
        let current = generation
        let values = answers.filter { action.fieldIDs.contains($0.key) }
        actionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, isActive, generation == current,
                  sessionRevision == MoodleService.shared.sessionRevision,
                  page?.revision == revision else { return }
            do {
                let result = try await browser.webView.callAsyncJavaScript(
                    "return window.__niuQuestionsV1.perform(revision, actionID, answers);",
                    arguments: ["revision": revision, "actionID": action.id, "answers": values],
                    in: nil, contentWorld: .page
                ) as? String
                guard !Task.isCancelled, generation == current else { return }
                if result != "invoked" {
                    isPerforming = false
                    submittedRevision = nil
                    submissionStarted = nil
                    errorMessage = result == "invalid"
                        ? "請確認必填欄位、字數與輸入格式後再送出。"
                        : "題目或操作已變更，請重新確認目前內容。"
                }
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                // A navigation can invalidate JavaScript after a successful click.
                // Never retry a potentially submitted operation automatically.
                errorMessage = "無法確認操作結果，請查看校方頁面確認，避免重複送出。"
            }
        }
    }

    func openSchoolPage() {
        guard isActive, !isSyncingPage else { return }
        guard let page, page.webReason == nil, !isPerforming,
              browser.isPageReady, !browser.questionNeedsWebInteraction else {
            showsSchoolPage = true
            return
        }
        let current = generation
        let pageRequest = pageGeneration
        let values = answers
        isSyncingPage = true
        actionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, isActive, generation == current,
                  pageRequest == pageGeneration,
                  sessionRevision == MoodleService.shared.sessionRevision else { return }
            defer { if generation == current { isSyncingPage = false } }
            do {
                let result = try await browser.webView.callAsyncJavaScript(
                    "return window.__niuQuestionsV1.stage(revision, answers);",
                    arguments: ["revision": page.revision, "answers": values],
                    in: nil, contentWorld: .page
                ) as? String
                guard !Task.isCancelled, generation == current, pageRequest == pageGeneration,
                      sessionRevision == MoodleService.shared.sessionRevision else { return }
                if result == "staged" {
                    showsSchoolPage = true
                } else {
                    errorMessage = "無法保留目前輸入，請先確認題目與字數後再切換。"
                }
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                errorMessage = "暫時無法切換介面，目前輸入仍保留，請稍後再試。"
            }
        }
    }

    func returnToNativePage() {
        guard isActive else { return }
        pageGeneration &+= 1
        needsAnswerSync = true
        isSyncingPage = true
        showsSchoolPage = false
    }

    func openReviewQuestion(_ id: String) {
        guard isActive, !isPerforming, !isSyncingPage, browser.isPageReady,
              page?.reviewQuestions?.contains(where: { $0.id == id }) == true,
              sessionRevision == MoodleService.shared.sessionRevision else { return }
        let current = generation
        let pageRequest = pageGeneration
        showsSchoolPage = true
        actionTask = Task { [weak self] in
            guard let self, !Task.isCancelled, isActive, generation == current,
                  pageRequest == pageGeneration,
                  sessionRevision == MoodleService.shared.sessionRevision else { return }
            do {
                _ = try await browser.webView.callAsyncJavaScript(
                    "return window.__niuQuestionsV1.focusQuestion(questionID);",
                    arguments: ["questionID": id], in: nil, contentWorld: .page
                )
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                errorMessage = "校方頁面已更新，請在頁面中選擇要複習的題目。"
            }
        }
    }

    func reload() {
        guard isActive else { return }
        pageGeneration &+= 1
        actionTask?.cancel()
        page = nil
        answers = [:]
        errorMessage = nil
        isPerforming = false
        submittedRevision = nil
        submissionStarted = nil
        needsAnswerSync = false
        isSyncingPage = false
        browser.retry()
    }

    func stop() {
        isActive = false
        generation &+= 1
        actionTask?.cancel()
        actionTask = nil
        isSyncingPage = false
        browser.cancel()
    }
}
