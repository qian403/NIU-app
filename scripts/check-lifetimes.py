#!/usr/bin/env python3
"""Run the production refresh cancellation/login arbitration methods offline."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

manager = (root / 'Features/EventRegistration/Services/EventRegistrationWebViewManager.swift').read_text()
fixture = '''import Foundation
@MainActor final class EventRegistrationWebViewManager {
    static let shared = EventRegistrationWebViewManager()
    private var isLoggingIn = false
    private var activeLoginRequesterID: String?
    private var loginCompletionHandlers: [String: () -> Void] = [:]
'''
for name in ['requestLogin', 'completeLoginIfNeeded', 'notifyLoginCompleted', 'cancelLogin', 'resetLoginState']:
    fixture += method(manager, 'func ' + name + '(') + '\n'
fixture += '}\n'
for tab in (1, 2):
    source = (root / f'Features/EventRegistration/ViewModels/EventRegistration_Tab{tab}_ViewModel.swift').read_text()
    fixture += f'@MainActor final class Model{tab} {{\n'
    fixture += '''var isOverlayVisible = false
    var loadGeneration = 0
    var loadingCancelled = false
    var hasInitialized = false
    let loginRequesterID = UUID().uuidString
    var cancellations = 0
    var webView: FakeWebView? = FakeWebView()
    func resetLoginProgress() { cancellations += 1 }
    func loadEventList() { loadGeneration += 1; loadingCancelled = false; isOverlayVisible = true }
    func failLoading(_ message: String) { cancelLoading() }
'''
    fixture += method(source, 'func manualRefresh()') + '\n'
    fixture += method(source, 'func cancelLoading()') + '\n}\n'
fixture += '''@MainActor final class FakeWebView { func stopLoading() {} }
@main struct Checks {
    @MainActor static func main() async throws {
'''
for tab in (1, 2):
    fixture += f'''
        do {{
            var model: Model{tab}? = Model{tab}()
            weak var weakModel = model
            var task: Task<Void, Never>? = Task {{ [model = model!] in await model.manualRefresh() }}
            try await Task.sleep(for: .milliseconds(20))
            let start = ContinuousClock.now
            task?.cancel()
            await task?.value
            precondition(start.duration(to: .now) < .seconds(1), "cancel must not spin")
            precondition(model?.isOverlayVisible == false)
            task = nil
            model = nil
            precondition(weakModel == nil, "cancelled refresh must release model")

            let restarted = Model{tab}()
            let old = Task {{ await restarted.manualRefresh() }}
            try await Task.sleep(for: .milliseconds(20))
            let new = Task {{ await restarted.manualRefresh() }}
            try await Task.sleep(for: .milliseconds(20))
            old.cancel()
            await old.value
            precondition(restarted.isOverlayVisible, "old waiter must not cancel new refresh")
            restarted.isOverlayVisible = false
            await new.value
            print("PASS: tab {tab} cancellation, release, superseded waiter, completion")
        }}
'''
fixture += '''
        let manager = EventRegistrationWebViewManager.shared
        manager.resetLoginState()
        var firstStarted = false
        var waitingStarted = false
        var cancelledWaiterRan = false
        manager.requestLogin(requesterID: "owner", loginAction: { firstStarted = true }, waitCompletion: {})
        manager.requestLogin(requesterID: "waiter", loginAction: {}, waitCompletion: {
            manager.requestLogin(requesterID: "waiter", loginAction: { waitingStarted = true }, waitCompletion: {})
        })
        manager.requestLogin(requesterID: "cancelled", loginAction: {}, waitCompletion: { cancelledWaiterRan = true })
        manager.cancelLogin(requesterID: "cancelled")
        manager.cancelLogin(requesterID: "owner")
        try await Task.sleep(for: .milliseconds(350))
        precondition(firstStarted && waitingStarted && !cancelledWaiterRan)
        manager.cancelLogin(requesterID: "waiter")
        var reopened = false
        manager.requestLogin(requesterID: "reopened", loginAction: { reopened = true }, waitCompletion: {})
        precondition(reopened, "cancelled owner must release lock")
        print("PASS: cancelled login owner/waiter and page reentry")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-lifetime-') as directory:
    swift = Path(directory) / 'Checks.swift'
    swift.write_text(fixture)
    binary = Path(directory) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(directory) / 'ModuleCache'), '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
