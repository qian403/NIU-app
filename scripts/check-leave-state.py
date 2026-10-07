#!/usr/bin/env python3
"""Compile the production leave VM with an offline service and isolated defaults.
No WebView, credentials, Keychain, SSO transport or school requests are used.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
feature = root / 'Features/LeaveApplication'
fixture = r'''
import Foundation

let fixtureSuite = "niu.leave.fixture.\(UUID().uuidString)"
let fixtureDefaults = UserDefaults(suiteName: fixtureSuite)!
enum StorageKeys { static let authSessionID = "session" }
@MainActor final class SSOSessionService {
    static let shared = SSOSessionService()
    var calls = 0
    var onRefresh: (() -> Void)?
    func requestRefresh(force: Bool) async -> Bool {
        precondition(force); calls += 1; onRefresh?(); return true
    }
}
@MainActor final class LeaveApplicationService {
    static var loads: [Result<LeavePage, Error>] = []
    static var entries: [LeaveEntry] = []
    static var runs: [String] = []
    static var failingScript: String?
    static var failure: Error = LeaveApplicationError.expired
    static var snapshotResult = LeavePage(kind: "form")
    static var waitCalls = 0
    static var waitFailure: Error?
    static var waitResult = LeavePage(kind: "periods", periods: [period])
    static var gate: CheckedContinuation<LeavePage, Error>?
    static var hold = false
    static var created = 0
    var onDialog: ((String) -> Void)?
    var onProgress: ((LeaveLoadStage) -> Void)?
    var onConfirm: ((String, @escaping (Bool) -> Void) -> Void)?
    var closed = false
    static var refreshesLogin = false
    var refreshedLogin = LeaveApplicationService.refreshesLogin
    init() { Self.created += 1 }
    func load(account: String, entry: LeaveEntry) async throws -> LeavePage {
        precondition(account == "fixture")
        Self.entries.append(entry)
        if Self.hold { return try await withCheckedThrowingContinuation { Self.gate = $0 } }
        precondition(!Self.loads.isEmpty, "unexpected load / unbounded retry")
        return try Self.loads.removeFirst().get()
    }
    func run(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        precondition(!closed)
        Self.runs.append(script)
        if script == Self.failingScript { throw Self.failure }
        return "ok"
    }
    func snapshot() async throws -> LeavePage { Self.snapshotResult }
    func waitForPage(kind: String, script: String = LeaveApplicationScript.snapshot,
                     matches: (LeavePage) -> Bool = { _ in true }) async throws -> LeavePage {
        Self.waitCalls += 1
        if let failure = Self.waitFailure { Self.waitFailure = nil; throw failure }
        precondition(matches(Self.waitResult), "fixture must supply a matching settled page")
        return Self.waitResult
    }
    func close() { closed = true }
}
let period = LeavePeriod(id: "1151005|2|COURSE|1", date: "115/10/05", period: "2", course: "測試", teacher: "", room: "")
func form(_ attachments: [String] = []) -> LeavePage {
    LeavePage(kind: "form", studentID: "fixture", attachmentNames: attachments,
              selected: period.id, mode: "DETAIL", current: LeaveCurrentValues(leaveType: "saved", startDate: "115/10/01", endDate: "115/10/02", reason: "saved", supplementLater: false))
}
@MainActor func settle(_ condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    preconditionFailure("fixture timed out")
}
@MainActor func reset() {
    fixtureDefaults.set("fixture", forKey: "app.user.username")
    fixtureDefaults.set("session-1", forKey: StorageKeys.authSessionID)
    LeaveApplicationService.loads = [.success(form(["old.pdf"]))]
    LeaveApplicationService.entries = []; LeaveApplicationService.runs = []
    LeaveApplicationService.failingScript = nil; LeaveApplicationService.waitFailure = nil; LeaveApplicationService.created = 0; LeaveApplicationService.waitCalls = 0
    LeaveApplicationService.failure = LeaveApplicationError.expired
    LeaveApplicationService.snapshotResult = LeavePage(kind: "form")
    LeaveApplicationService.waitResult = LeavePage(kind: "periods", periods: [period])
    LeaveApplicationService.hold = false; LeaveApplicationService.gate = nil
    SSOSessionService.shared.calls = 0; SSOSessionService.shared.onRefresh = nil
}
@MainActor func ready(_ entry: LeaveEntry = .apply) async -> LeaveApplicationViewModel {
    reset()
    let model = LeaveApplicationViewModel(entry: entry)
    model.load(); await settle { !model.isBusy }
    model.leaveType = "draft"; model.reason = "保留的事由"; model.supplementLater = true
    model.startDate = LeaveApplicationDate.date(fromROC: "115/10/05")!
    model.endDate = LeaveApplicationDate.date(fromROC: "115/10/06")!
    model.loadPeriods(); await settle { !model.isBusy }
    model.togglePeriod(period.id)
    precondition(model.hasLoadedPeriods && !model.selected.isEmpty)
    return model
}
@MainActor func checkDraft(_ model: LeaveApplicationViewModel) {
    precondition(model.leaveType == "draft" && model.reason == "保留的事由" && model.supplementLater)
    precondition(model.dateKey == "115/10/05|115/10/06")
    precondition(model.periods.isEmpty && model.selected.isEmpty && !model.hasLoadedPeriods)
    precondition(!model.canReview && !model.acknowledged)
}
@main struct Checks {
    @MainActor static func main() async throws {
        defer { fixtureDefaults.removePersistentDomain(forName: fixtureSuite) }
        // Every entry retains native values, even when saved values differ.
        for entry in [LeaveEntry.apply, .modify(formNo: "fake"), .supplement(formNo: "fake")] {
            let model = await ready(entry)
            LeaveApplicationService.loads = [.success(form(["new.pdf"]))]
            LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
            model.loadPeriods(); await settle { !model.isBusy }
            checkDraft(model)
            precondition(model.attachmentNames == ["new.pdf"] && model.message!.contains("附件清單已變更"))
            precondition(!model.needsReconnect && SSOSessionService.shared.calls == 0)
            precondition(LeaveApplicationService.entries == [entry, entry])
            precondition(LeaveApplicationService.runs.filter { $0 == LeaveApplicationScript.openPeriods }.count == 2)
            model.close()
        }
        // Notice, review and upload all recover; an interrupted upload is not replayed.
        let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("synthetic.pdf")
        try Data("synthetic attachment".utf8).write(to: file)
        for action in ["notice", "review", "upload"] {
            let model: LeaveApplicationViewModel
            if action == "notice" {
                reset(); LeaveApplicationService.loads = [.success(LeavePage(kind: "notice"))]
                model = LeaveApplicationViewModel(); model.load(); await settle { !model.isBusy }
            } else { model = await ready() }
            let script = action == "notice" ? LeaveApplicationScript.acceptNotice
                : action == "review" ? LeaveApplicationScript.openPeriods : LeaveApplicationScript.upload
            LeaveApplicationService.failingScript = script
            LeaveApplicationService.loads = [.success(form())]
            let count = LeaveApplicationService.runs.filter { $0 == script }.count
            if action == "notice" { model.acceptNotice() }
            else if action == "review" { model.prepareReview() }
            else { model.upload(file) }
            await settle { !model.isBusy }
            precondition(!model.needsReconnect && model.message!.contains("已重新連線"))
            precondition(LeaveApplicationService.runs.filter { $0 == script }.count == count + 1)
            if action != "notice" { checkDraft(model) }
            model.close()
        }
        // Navigation can expire after the click succeeded, during the period/form poll.
        for action in ["periods", "review", "upload", "notice"] {
            let model: LeaveApplicationViewModel
            if action == "notice" {
                reset(); LeaveApplicationService.loads = [.success(LeavePage(kind: "notice"))]
                model = LeaveApplicationViewModel(); model.load(); await settle { !model.isBusy }
            } else { model = await ready() }
            LeaveApplicationService.waitFailure = LeaveApplicationError.expired
            LeaveApplicationService.loads = [.success(form())]
            if action == "periods" { model.loadPeriods() }
            else if action == "review" { model.prepareReview() }
            else if action == "notice" { model.acceptNotice() }
            else { model.upload(file) }
            await settle { !model.isBusy }
            precondition(!model.needsReconnect && model.message!.contains("已重新連線"))
            precondition(LeaveApplicationService.entries.count == 2 && SSOSessionService.shared.calls == 0)
            if action != "notice" { checkDraft(model) }
            model.close()
        }
        // Reload through the notice once; do not restore saved values over the draft.
        let notice = await ready()
        LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
        LeaveApplicationService.loads = [.success(LeavePage(kind: "notice"))]
        LeaveApplicationService.waitResult = form()
        notice.loadPeriods(); await settle { !notice.isBusy }
        checkDraft(notice); precondition(notice.page?.kind == "form"); notice.close()

        // A parent form can arrive before attachments. Recovery waits for their page.
        let delayed = await ready()
        LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
        LeaveApplicationService.loads = [.success(LeavePage(kind: "form", studentID: "fixture"))]
        LeaveApplicationService.waitResult = form(["old.pdf"])
        let waits = LeaveApplicationService.waitCalls
        delayed.loadPeriods(); await settle { !delayed.isBusy }
        checkDraft(delayed)
        precondition(LeaveApplicationService.waitCalls == waits + 1)
        precondition(delayed.attachmentNames == ["old.pdf"] && !delayed.message!.contains("附件清單已變更"))
        delayed.close()

        // A failed bridge permits only one SSO refresh; failure stays visible and manual retry preserves draft.
        let failed = await ready()
        LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
        LeaveApplicationService.loads = [.failure(URLError(.userAuthenticationRequired)), .failure(LeaveApplicationError.expired)]
        failed.loadPeriods(); await settle { !failed.isBusy }
        checkDraft(failed)
        precondition(failed.needsReconnect && failed.message!.contains("重新連線"))
        precondition(SSOSessionService.shared.calls == 1 && LeaveApplicationService.created == 3)
        LeaveApplicationService.loads = [.success(form())]
        failed.reconnect(); await settle { !failed.isBusy }
        checkDraft(failed); precondition(!failed.needsReconnect); failed.close()

        // A service that already refreshed SSO in its own GUID bridge is not refreshed again.
        do {
            let model = await ready()
            LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
            LeaveApplicationService.refreshesLogin = true
            LeaveApplicationService.loads = [.failure(LeaveApplicationError.expired)]
            model.loadPeriods(); await settle { !model.isBusy }
            LeaveApplicationService.refreshesLogin = false
            checkDraft(model)
            precondition(model.needsReconnect && SSOSessionService.shared.calls == 0)
            model.close()
        }
        // Offline and transport timeout during reconnect are not refreshed or called login failure.
        for code in [URLError.Code.notConnectedToInternet, .timedOut] {
            let model = await ready()
            LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
            LeaveApplicationService.loads = [.failure(URLError(code))]
            model.loadPeriods(); await settle { !model.isBusy }
            checkDraft(model)
            precondition(model.needsReconnect && SSOSessionService.shared.calls == 0)
            precondition(model.message!.contains(code == .timedOut ? "回應逾時" : "沒有網路連線"))
            model.close()
        }
        // Account/session replacement during refresh cannot start another load.
        for key in ["app.user.username", StorageKeys.authSessionID] {
            let model = await ready()
            LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
            LeaveApplicationService.loads = [.failure(LeaveApplicationError.expired)]
            SSOSessionService.shared.onRefresh = { fixtureDefaults.set("replacement", forKey: key) }
            model.loadPeriods(); await settle { SSOSessionService.shared.calls == 1 }
            precondition(LeaveApplicationService.created == 2 && model.attachmentNames == ["old.pdf"])
            model.close()
        }
        // An old load that ignores cancellation must not repopulate a closed form.
        let cancelled = await ready()
        LeaveApplicationService.failingScript = LeaveApplicationScript.openPeriods
        LeaveApplicationService.hold = true
        cancelled.loadPeriods(); await settle { LeaveApplicationService.gate != nil }
        cancelled.close()
        LeaveApplicationService.gate!.resume(returning: form(["stale.pdf"]))
        await Task.yield(); await Task.yield()
        precondition(cancelled.page == nil && cancelled.service == nil && cancelled.message == nil)

        // Expiry at submission dispatch AND during the response poll never starts recovery.
        for supplement in [false, true] {
            for afterDispatch in [false, true] {
                let model = await ready(supplement ? .supplement(formNo: "fake") : .apply)
                if !supplement {
                    LeaveApplicationService.waitResult = form()
                    model.prepareReview(); await settle { !model.isBusy }
                    precondition(model.canReview)
                }
                model.acknowledged = true
                let script = supplement ? LeaveApplicationScript.submitSupplement : LeaveApplicationScript.submit
                if afterDispatch { LeaveApplicationService.snapshotResult = LeavePage(kind: "expired") }
                else { LeaveApplicationService.failingScript = script }
                if supplement { model.submitSupplement() } else { model.submit() }
                await settle { !model.isBusy }
                precondition(model.didAttemptSubmit && model.message!.contains("送出結果尚未確認"))
                model.reconnect(); model.load(); model.submit(); model.submitSupplement()
                precondition(LeaveApplicationService.entries.count == 1 && SSOSessionService.shared.calls == 0)
                precondition(LeaveApplicationService.runs.filter { $0 == script }.count == 1)
                model.close()
            }
        }
        print("PASS: leave draft retention, period reset, attachment reload, all in-form recovery paths, bounded refresh, manual reconnect, offline/timeout distinction, stale account/session/cancelled responses, no submit replay.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-leave-state-') as temporary:
    directory = Path(temporary)
    # Keep production logic verbatim, replacing only the defaults destination.
    vm = directory / 'LeaveApplicationViewModel.swift'
    vm.write_text((feature / vm.name).read_text().replace('UserDefaults.standard', 'fixtureDefaults'))
    checks = directory / 'Checks.swift'
    checks.write_text(fixture)
    binary = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    '-module-cache-path', str(directory / 'ModuleCache'),
                    str(feature / 'LeaveApplicationModels.swift'), str(feature / 'LeaveApplicationScript.swift'),
                    str(vm), str(checks), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(directory)], check=True)
