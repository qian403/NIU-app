#!/usr/bin/env python3
"""Run the production native question view model with isolated browser/session doubles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import WebKit
import Combine

@MainActor final class MoodleService {
    static let shared = MoodleService()
    var sessionRevision = 0
}
@MainActor final class Browser {
    var isLoading = false
    var revision = "one"
    var value = "校方原值"
    var result = "invoked"
    var submits = 0
    var stages = 0
    var pauseNextRead = false
    var pending: CheckedContinuation<Any?, Never>?
    var pendingValue: String?
    func json() -> String {
        let content: [String: Any] = [
            "revision": revision, "title": "合成題目", "text": "合成題幹",
            "fields": [["id": "answer", "kind": "text", "label": "答案", "values": [value],
                        "options": [], "required": true, "disabled": false]],
            "actions": [["id": "send", "label": "送出", "disabled": false, "fieldIDs": ["answer"]]]
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
    }
    func evaluateJavaScript(_ script: String) async throws -> Any? {
        guard script == MoodleQuestionPageScript.snapshot else { return nil }
        if pauseNextRead {
            pauseNextRead = false
            pendingValue = json()
            return await withCheckedContinuation { pending = $0 }
        }
        return json()
    }
    func release() {
        let reply = pending
        pending = nil
        reply?.resume(returning: pendingValue)
        pendingValue = nil
    }
    func callAsyncJavaScript(_ script: String, arguments: [String: Any],
                             in frame: WKFrameInfo?, contentWorld: WKContentWorld) async throws -> Any? {
        let answers = arguments["answers"] as! [String: [String]]
        precondition(arguments["revision"] as? String == revision)
        if script.contains(".stage(") {
            stages += 1
            value = answers["answer"]!.first!
            return "staged"
        }
        submits += 1
        return result
    }
}
@MainActor final class MoodleWebManager {
    var isPageReady = false
    var questionNeedsWebInteraction = false
    var errorMessage: String?
    var loads = 0
    let webView = Browser()
    func loadWithSSO(targetURL: String) { loads += 1; isPageReady = true }
    func retry() { loads += 1; isPageReady = true }
    func cancel() { isPageReady = false }
}
@MainActor func wait(_ label: String, until condition: () -> Bool) async {
    let end = Date().addingTimeInterval(4)
    while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    precondition(condition(), label)
}
@main struct Checks {
    @MainActor static func main() async throws {
        let module = try JSONDecoder().decode(MoodleModule.self, from: Data(
            #"{"id":100,"modname":"irs","name":"合成問答"}"#.utf8))
        let model = MoodleQuestionDetailViewModel(module: module)
        let task = Task { await model.run() }
        await wait("initial native snapshot") { model.page != nil }
        let browser = model.browser.webView
        model.answers["answer"] = ["原生草稿"]
        try await Task.sleep(for: .milliseconds(1200))
        precondition(model.answers["answer"] == ["原生草稿"], "Polling must preserve unsubmitted native edits")
        model.openSchoolPage()
        await wait("enter school page") { model.showsSchoolPage }
        precondition(browser.value == "原生草稿" && browser.stages == 1 && browser.submits == 0,
                     "Switching UI stages drafts without submitting")
        browser.value = "校方頁面修改"
        model.returnToNativePage()
        precondition(model.isSyncingPage, "Actions must wait for a fresh school snapshot")
        await wait("return to native") { !model.isSyncingPage }
        precondition(model.answers["answer"] == ["校方頁面修改"], "Web edits must replace old native draft")

        let action = model.page!.actions[0]
        model.perform(action, revision: model.page!.revision)
        model.perform(action, revision: model.page!.revision)
        await wait("one explicit action") { browser.submits == 1 }
        precondition(model.isPerforming, "An invoked control is not proof of a server response")
        try await Task.sleep(for: .milliseconds(1200))
        precondition(browser.submits == 1 && model.isPerforming, "No automatic retry or premature unlocking")
        browser.revision = "two"
        await wait("new server page") { model.page?.revision == "two" }
        precondition(!model.isPerforming)
        browser.result = "invalid"
        model.perform(model.page!.actions[0], revision: "two")
        await wait("validation failure unlock") { browser.submits == 2 && !model.isPerforming }
        precondition(model.errorMessage?.contains("必填") == true)
        model.perform(action, revision: "one")
        precondition(browser.submits == 2, "Stale confirmation must not act")

        var published: [String] = []
        let observation = model.$page.sink { if let value = $0 { published.append(value.revision) } }
        browser.revision = "obsolete"
        browser.pauseNextRead = true
        await wait("delayed read") { browser.pending != nil }
        model.reload()
        browser.revision = "fresh"
        browser.release()
        await wait("fresh reload") { model.page?.revision == "fresh" }
        precondition(!published.contains("obsolete"), "Pre-reload read must not restore stale questions")
        observation.cancel()

        model.stop()
        model.perform(model.page!.actions[0], revision: "fresh")
        precondition(browser.submits == 2, "A dismissed confirmation cannot submit after leaving the screen")
        task.cancel()
        await task.value
        let reopened = Task { await model.run() }
        await wait("reopening") { model.browser.loads == 3 && model.browser.isPageReady }
        browser.pauseNextRead = true
        await wait("read during account switch") { browser.pending != nil }
        MoodleService.shared.sessionRevision += 1
        browser.release()
        await reopened.value
        precondition(model.page == nil && model.answers.isEmpty && !model.browser.isPageReady)
        print("PASS: native/web draft ownership, validation, duplicate submission prevention, stale confirmation, reload races, reentry and account changes")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-native-question-detail-") as directory:
    folder = Path(directory)
    swift = folder / "Checks.swift"
    swift.write_text(HARNESS)
    binary = folder / "checks"
    sources = [
        "Features/Moodle/Models/MoodleModels.swift",
        "Features/Moodle/Questions/MoodleQuestionActivity.swift",
        "Features/Moodle/Questions/MoodleQuestionPage.swift",
        "Features/Moodle/Questions/MoodleQuestionDetailViewModel.swift",
    ]
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(folder / "modules"),
        *[str(ROOT / source) for source in sources], str(swift), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=35)
