#!/usr/bin/env python3
"""Render real postal views with synthetic services and verify sheet/account lifecycle.

A temporary view copy receives presentation commands; production layouts, models,
SwiftUI sheet dismissal, and profile observers run unchanged. No school requests.
"""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--state', choices=['records', 'empty', 'error', 'loading', 'manual', 'missing'], default='records')
parser.add_argument('--light', action='store_true')
parser.add_argument('--large-text', action='store_true')
parser.add_argument('--screenshot', default='/tmp/niu-postal-ui.png')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
bundle = 'dev.chien.niuapp.postal-fixture'
view = (root / 'Features/Postal/Views/PostalQueryView.swift').read_text()
hook = '''        .onReceive(Fixture.presentation) { showsOtherQuery = $0 }
'''
assert view.count('        .onAppear(perform: prepareOwnMail)') == 1
view = view.replace('        .onAppear(perform: prepareOwnMail)', hook + '        .onAppear(perform: prepareOwnMail)')
fixture = r'''
import SwiftUI
import Combine

@MainActor final class AppState: ObservableObject {
    @Published var isAuthenticated = true
    @Published var currentUser: User? = User(username: "fixture-a", name: "測試同學")
}
@MainActor enum Fixture {
    static let presentation = PassthroughSubject<Bool, Never>()
    static var mode = "records"
    static var started = false
}
nonisolated struct FakePostalService: PostalServing {
    func search(_ query: PostalQuery) async throws -> PostalPage {
        let mode = await Fixture.mode
        try await Task.sleep(for: .milliseconds(mode == "loading" ? 60_000 : 30))
        if mode == "error" { throw URLError(.notConnectedToInternet) }
        let records = mode == "empty" ? [] : [PostalRecord(
            sequence: "1", receivedDate: "2026/10/02", trackingNumber: "TEST123456",
            unit: "資訊工程學系", recipient: query.name, category: "宅配包裹", quantity: "1",
            signature: query.status == .collected ? "已簽收" : "", completedDate: "",
            note: "請攜帶學生證領取", status: query.status)]
        return PostalPage(records: records, query: query, pageIndex: 0, pageCount: 1, nextForm: nil)
    }
    func nextPage(after page: PostalPage) async throws -> PostalPage { throw PostalError.unavailable }
    func invalidate() {}
}
struct CheckFailure: Error { let reason: String }
@main struct PostalChecks: App {
    @StateObject private var appState = AppState()
    private let personal = PostalQueryViewModel(makeService: { FakePostalService() })
    private let manual = PostalQueryViewModel(makeService: { FakePostalService() })
    var body: some Scene {
        WindowGroup {
            NavigationStack { PostalQueryView(model: personal, manualModel: manual) }
                .environmentObject(appState)
                .preferredColorScheme(FIXTURE_COLOR)
                .dynamicTypeSize(FIXTURE_TYPE)
                .task { await check() }
        }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw CheckFailure(reason: "UI state timed out")
    }
    private func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw CheckFailure(reason: reason) }
    }
    private var sheetIsPresented: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).contains { $0.rootViewController?.presentedViewController != nil }
    }
    private func check() async {
        guard !Fixture.started else { return }
        Fixture.started = true
        var stage = "automatic lookup"
        var output: [String: String]
        do {
            try await waitFor { personal.resultQuery?.name == "測試同學" }
            try require(manual.query == PostalQuery(), "Manual form must start independently")
            stage = "manual sheet open"
            Fixture.presentation.send(true)
            try await waitFor { sheetIsPresented }
            try await Task.sleep(for: .milliseconds(500))
            try require(personal.ownName == "測試同學" && personal.records.count == 1,
                        "Presenting sheet must preserve personal results")
            manual.query = PostalQuery(name: "其他同學", status: .returned)
            manual.search()
            try await waitFor { manual.resultQuery?.name == "其他同學" }
            Fixture.presentation.send(false)
            try await waitFor { !sheetIsPresented }
            try require(personal.resultQuery == PostalQuery(name: "測試同學"), "Manual query must not replace personal results")
            stage = "status selection"
            personal.selectOwnStatus(.collected)
            try await waitFor { personal.resultQuery?.status == .collected }
            stage = "account switch with sheet"
            Fixture.presentation.send(true)
            try await waitFor { sheetIsPresented }
            appState.currentUser = User(username: "fixture-b", name: "另一位同學")
            try await waitFor { personal.resultQuery?.name == "另一位同學" && !sheetIsPresented }
            try require(manual.query == PostalQuery() && manual.records.isEmpty, "Account switch must clear manual data")
            stage = "logout"
            appState.currentUser = nil
            appState.isAuthenticated = false
            try await waitFor { personal.ownName == nil }
            try require(personal.records.isEmpty && manual.records.isEmpty, "Logout must clear both result sets")
            stage = "late profile preserves manual query"
            appState.currentUser = User(username: "fixture-a", name: "")
            appState.isAuthenticated = true
            try await Task.sleep(for: .milliseconds(150))
            manual.query.name = "手動查詢"
            appState.currentUser = User(username: "fixture-a", name: "測試同學")
            try await waitFor { personal.resultQuery?.name == "測試同學" && sheetIsPresented }
            try require(manual.query.name == "手動查詢", "Late name must preserve manual draft")
            Fixture.presentation.send(false)
            try await waitFor { !sheetIsPresented }
            manual.reset()
            stage = "screenshot state"
            Fixture.mode = "FIXTURE_STATE"
            if Fixture.mode == "missing" {
                appState.currentUser = User(username: "fixture-a", name: "")
                try await waitFor { personal.ownName == nil }
            } else {
                personal.searchOwnMail()
                if Fixture.mode != "loading" { try await waitFor { !personal.isLoading } }
                if Fixture.mode == "manual" {
                    Fixture.presentation.send(true)
                    try await waitFor { sheetIsPresented }
                }
            }
            try await Task.sleep(for: .milliseconds(500))
            output = ["status": "passed", "checks": "auto lookup, sheet preserves personal results, independent manual query, automatic status lookup, account switch dismisses sheet and clears both models, logout, late profile preserves draft"]
        } catch {
            output = ["status": "failed", "reason": "\(stage): \(error)"]
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
        try? JSONSerialization.data(withJSONObject: output).write(to: url)
    }
}
'''
run = subprocess.run
with tempfile.TemporaryDirectory(prefix='niu-postal-ui-') as directory:
    folder = Path(directory)
    app = folder / 'PostalChecks.app'
    app.mkdir()
    source = folder / 'Checks.swift'
    source.write_text(fixture.replace('FIXTURE_COLOR', '.light' if args.light else '.dark')
                      .replace('FIXTURE_TYPE', '.accessibility2' if args.large_text else '.large')
                      .replace('FIXTURE_STATE', args.state))
    screen = folder / 'PostalQueryView.swift'
    screen.write_text(view)
    (app / 'Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=bundle, CFBundleName='PostalChecks', CFBundleExecutable='PostalChecks',
        CFBundlePackageType='APPL', CFBundleVersion='1', CFBundleShortVersionString='1.0',
        MinimumOSVersion='26.0', LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2], UILaunchScreen={}
    )))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    files = [root / 'Features/Postal' / p for p in (
        'Models/PostalModels.swift', 'Services/PostalService.swift', 'ViewModels/PostalQueryViewModel.swift')]
    run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-sdk', sdk,
         '-target', 'arm64-apple-ios26.0-simulator', '-parse-as-library',
         '-module-cache-path', str(folder / 'ModuleCache'), *map(str, files),
         str(root / 'Core/Models/User.swift'), str(root / 'Shared/Theme/Theme.swift'), str(screen), str(source),
         '-o', str(app / 'PostalChecks')], check=True)
    run(['codesign', '--force', '--sign', '-', str(app)], check=True, stdout=subprocess.DEVNULL)
    run(['xcrun', 'simctl', 'install', args.device, str(app)], check=True)
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data'], text=True).strip())
    output = container / 'Documents/result.json'
    output.unlink(missing_ok=True)
    run(['xcrun', 'simctl', 'launch', args.device, bundle], check=True)
    try:
        deadline = time.monotonic() + 40
        while not output.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not output.exists():
            raise RuntimeError('Postal UI fixture did not return a result')
        result = json.loads(output.read_text())
        run(['xcrun', 'simctl', 'io', args.device, 'screenshot', args.screenshot], check=True, stdout=subprocess.DEVNULL)
        if result['status'] != 'passed':
            raise RuntimeError(result)
        print('PASS: ' + result['checks'])
        print('Screenshot: ' + args.screenshot)
    finally:
        run(['xcrun', 'simctl', 'terminate', args.device, bundle], check=False, capture_output=True)
