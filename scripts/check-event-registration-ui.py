#!/usr/bin/env python3
"""Render the real activity registration views in an isolated simulator app with synthetic data.

No school servers, Keychain or WebKit sessions are used. Takes a screenshot for visual QA.
Use a simulator that is not running your own signed-in app; settings are restored afterwards.
Usage: python3 scripts/check-event-registration-ui.py --device <booted UDID> --scenario list
"""
import argparse
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--scenario", default="list",
                    choices=["list", "applied", "failed", "empty", "uncertain", "detail", "busy"])
parser.add_argument("--screenshot", default="/private/tmp/niu-event-registration-ui.png")
parser.add_argument("--dark", action="store_true")
parser.add_argument("--large-text", action="store_true")
parser.add_argument("--wait", type=float, default=4)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
feature = root / "Features/EventRegistration"
bundle = "dev.chien.niuapp.event-registration-fixture"

fixture = r'''
import SwiftUI

@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? { fatalError("Keychain forbidden") }
}

@MainActor enum StorageKeys {
    static let username = "fixture.username"
    static let authSessionID = "fixture.session"
}

@MainActor let fixtureFavorites: EventFavoritesStore = {
    let suite = "dev.niu.event-ui-fixture"
    guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Fixture defaults unavailable") }
    defaults.removePersistentDomain(forName: suite)
    return EventFavoritesStore(defaults: defaults, account: { "synthetic" }, session: { "fixture" })
}()

let scenario = "SCENARIO"

func event(_ id: String, _ name: String, _ state: String) -> EventData {
    EventData(name: name, department: "學生事務處課外活動指導組", event_state: state, eventSerialID: id,
              eventTime: "2099/10/10 10:00起\n2099/10/10 12:00止", eventLocation: "綜合大樓 1 樓演講廳",
              eventRegisterTime: "2099/10/01起\n2099/10/09止", eventDetail: "合成測試資料，非真實活動。",
              contactInfoName: "測試聯絡人", contactInfoTel: "03-0000000", contactInfoMail: "test@example.com",
              Related_links: "", Multi_factor_authentication: "服務學習", eventPeople: "限額 80人\n已報名 42人",
              Remark: "")
}

func applied(_ id: String, _ name: String, _ state: String, _ eventState: String) -> EventData_Apply {
    EventData_Apply(name: name, department: "資訊中心", state: state, event_state: eventState, eventSerialID: id,
                    eventTime: "2099/10/12 13:00起\n2099/10/12 15:00止", eventLocation: "圖資館 3 樓",
                    eventRegisterTime: "", eventDetail: "合成測試資料。", contactInfoName: "", contactInfoTel: "",
                    contactInfoMail: "", Related_links: "", Multi_factor_authentication: "", Remark: "")
}

@MainActor final class FixtureService: EventRegistrationServing {
    func availableEvents() async throws -> [EventData] {
        try await Task.sleep(for: .milliseconds(300))
        switch scenario {
        case "failed": throw EventRegistrationError.offline
        case "empty": return []
        default:
            return [event("12345", "生成式 AI 實作工作坊（測試）", "報名中"),
                    event("22222", "校園攝影講座：構圖與光線（測試）", "已額滿"),
                    event("33333", "職涯探索講座（測試）", "即將開始")]
        }
    }
    func appliedEvents() async throws -> [EventData_Apply] {
        [applied("44444", "Swift 程式設計入門（測試）", "已報名", "未開始"),
         applied("55555", "志工培訓（測試）", "候補", "進行中")]
    }
    func register(eventID: String) async throws -> EventActionOutcome {
        try await Task.sleep(for: .seconds(scenario == "busy" ? 30 : 0.2))
        return .uncertain("已送出報名，但尚無法確認校方是否完成。請到「已報名活動」確認，勿立即重複報名。")
    }
    func cancelRegistration(eventID: String) async throws -> EventActionOutcome { .confirmed("已取消報名。") }
    func registrationForm(eventID: String) async throws -> EventRegistrationForm { EventRegistrationForm() }
    func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome {
        .confirmed("已更新報名資料。")
    }
}

struct Harness: View {
    @StateObject private var appliedModel = EventRegistration_Tab2_ViewModel(service: FixtureService())
    @StateObject private var availableModel = EventRegistration_Tab1_ViewModel(service: FixtureService(), favorites: fixtureFavorites)

    var body: some View {
        NavigationStack {
            switch scenario {
            case "applied":
                EventRegistration_Tab2_View(viewModel: appliedModel)
                    .navigationTitle("活動報名").navigationBarTitleDisplayMode(.inline)
                    .onAppear { appliedModel.loadIfNeeded() }
            case "uncertain", "busy":
                EventRegistrationView(service: FixtureService(), favorites: fixtureFavorites)
                    .task {
                        try? await Task.sleep(for: .seconds(1))
                        NotificationCenter.default.post(name: .fixtureRegister, object: nil)
                    }
            case "detail":
                EventDetailView(event: event("12345", "生成式 AI 實作工作坊（測試）", "報名中")) { _ in }
            default:
                EventRegistrationView(service: FixtureService(), favorites: fixtureFavorites)
            }
        }
    }
}

extension Notification.Name { static let fixtureRegister = Notification.Name("fixtureRegister") }

@main struct FixtureApp: App {
    var body: some Scene { WindowGroup { Harness() } }
}
'''

def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)

# The uncertain/busy scenarios register via the ViewModel the real screen created.
view_source = (feature / "Views/EventRegistrationView.swift").read_text()
view_source = view_source.replace(
    "        .onDisappear {",
    "        .onReceive(NotificationCenter.default.publisher(for: .fixtureRegister)) { _ in\n"
    "            if let first = tab1ViewModel.events.first { tab1ViewModel.register(first) }\n"
    "        }\n        .onDisappear {", 1)

with tempfile.TemporaryDirectory(prefix="niu-event-ui-") as directory:
    folder = Path(directory)
    app = folder / "EventFixture.app"
    app.mkdir()
    source = folder / "Fixture.swift"
    source.write_text(fixture.replace("SCENARIO", args.scenario))
    view = folder / "EventRegistrationView.swift"
    view.write_text(view_source)
    (app / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=bundle, CFBundleName="EventFixture", CFBundleExecutable="EventFixture",
        CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1.0",
        MinimumOSVersion="26.0", LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2], UILaunchScreen={}
    )))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    files = [feature / "Models/EventRegistrationModels.swift", feature / "Services/EventRegistrationClient.swift",
             feature / "Stores/EventFavoritesStore.swift",
             *sorted((feature / "Batch").glob("*.swift")),
             *sorted((feature / "ViewModels").glob("*.swift")),
             *[f for f in sorted((feature / "Views").glob("*.swift")) if f.name != "EventRegistrationView.swift"],
             view, root / "Shared/Theme/Theme.swift"]
    run("xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5", "-sdk", sdk,
        "-target", "arm64-apple-ios26.0-simulator", "-parse-as-library", "-default-isolation", "MainActor",
        "-module-cache-path", str(folder / "ModuleCache"), *map(str, files), str(source),
        "-o", str(app / "EventFixture"))
    run("codesign", "--force", "--sign", "-", str(app), stdout=subprocess.DEVNULL)
    current = lambda setting: subprocess.check_output(
        ["xcrun", "simctl", "ui", args.device, setting], text=True).strip()
    original_appearance, original_size = current("appearance"), current("content_size")
    run("xcrun", "simctl", "ui", args.device, "appearance", "dark" if args.dark else "light")
    run("xcrun", "simctl", "ui", args.device, "content_size",
        "accessibility-extra-large" if args.large_text else "large")
    try:
        run("xcrun", "simctl", "install", args.device, str(app))
        subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle], capture_output=True)
        run("xcrun", "simctl", "launch", args.device, bundle, stdout=subprocess.DEVNULL)
        time.sleep(args.wait)
        run("xcrun", "simctl", "io", args.device, "screenshot", args.screenshot, capture_output=True)
        print(f"Screenshot: {args.screenshot}")
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle], capture_output=True)
        subprocess.run(["xcrun", "simctl", "uninstall", args.device, bundle], capture_output=True)
        run("xcrun", "simctl", "ui", args.device, "appearance", original_appearance)
        run("xcrun", "simctl", "ui", args.device, "content_size", original_size)
