#!/usr/bin/env python3
"""Run production Home/Grade SwiftUI screens with isolated synthetic dependencies.

Usage: python3 scripts/check-home-navigation.py --device <booted simulator UDID>
Navigation commands are injected into a temporary copy of HomeView. The actual
stack, destination factory, cards, grade UI and loading lifecycle are compiled.
No real school requests, camera session, credentials or app data are used.
"""
import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--manual-first-entry", action="store_true",
                    help="Wait for a real tap on the grade card before running the remaining checks")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
bundle = "dev.chien.niuapp.home-navigation-checks"
home = (root / "Features/Home/Views/HomeView.swift").read_text().split("#Preview")[0]
cards = home[home.index("    private var featureCards:"):home.index("private struct HomeToolsView")]
assert "destination: .tools" in cards
assert any('title: "請假"' in card and "destination: .leaveApplication" in card
           for card in cards.split("FeatureCard("))
assert "destination: .libraryEquipment" not in cards and "destination: .postalQuery" not in cards
tools_start = home.index("private struct HomeToolsView")
tools = home[tools_start:home.index("// MARK: - Feature Card", tools_start)]
assert "LazyVGrid" in tools and "destination: .libraryEquipment" in tools and "destination: .postalQuery" in tools
assert "NavigationStack" not in tools, "Tools must retain the Home back stack"
hook = r'''
        .onReceive(Fixture.commands) { command in
            switch command {
            case "tools": navigationPath.append(HomeRoute(destination: .tools))
            case "equipment": navigationPath.append(HomeRoute(destination: .libraryEquipment))
            case "postal": navigationPath.append(HomeRoute(destination: .postalQuery))
            case "leave": navigationPath.append(HomeRoute(destination: .leaveApplication))
            case "back": if !navigationPath.isEmpty { navigationPath.removeLast() }
            case "grades": navigationPath.append(HomeRoute(destination: .gradeHistory))
            case "home": navigationPath = NavigationPath()
            default: break
            }
        }
'''
assert home.count("        .onAppear {") == 1
home = home.replace("        .onAppear {", hook + "        .onAppear {", 1)
grade = (root / "Features/GradeHistory/Views/GradeHistoryView.swift").read_text()
grade = grade[:grade.index("private struct GradeHistoryCourseDTO")]
model = (root / "Features/GradeHistory/ViewModels/GradeHistoryViewModel.swift").read_text()
assert model.count("        self.cacheDefaults = cacheDefaults") == 1
model = model.replace("        self.cacheDefaults = cacheDefaults",
                      "        defer { Fixture.gradeModels.append(self) }\n        self.cacheDefaults = cacheDefaults", 1)
source = r'''
import SwiftUI
import Combine
import UIKit

@MainActor enum Fixture {
    static let commands = PassthroughSubject<String, Never>()
    static let details = PassthroughSubject<Void, Never>()
    static var gradeModels: [GradeHistoryViewModel] = []
    static var screenAppearances: [String: Int] = [:]
    static var visibleIDs: [String: Set<UUID>] = [:]
    static var visible: Set<String> { Set(visibleIDs.filter { !$0.value.isEmpty }.keys) }
    static var returnHome: (() -> Void)?
    static var finishGrades = true
    static var stage = "cold launch"
    static var driverStarted = false
    static func appeared(_ name: String, id: UUID) {
        screenAppearances[name, default: 0] += 1
        visibleIDs[name, default: []].insert(id)
    }
    static func disappeared(_ name: String, id: UUID) {
        visibleIDs[name]?.remove(id)
    }
}
struct FixtureUser {
    let name = "Synthetic Student"
    let department: String? = "Synthetic Department"
    let grade: String? = "3"
}
@MainActor final class AppState: ObservableObject {
    var currentUser: FixtureUser? = FixtureUser()
    func refreshProfileIfNeeded() async {}
}
@MainActor final class ClassScheduleViewModel: ObservableObject {
    enum State { case idle, loaded }
    var loadState = State.loaded
    var showWebView = false
    var loadGeneration = 0
    func loadSchedule() {}
    func handleWebResult(_ result: Bool, generation: Int) {}
    func refreshAndWait() async {}
}
struct ClassScheduleWebView: View {
    let onResult: (Bool) -> Void
    var body: some View { Color.clear }
}
extension Notification.Name {
    static let classScheduleDidUpdate = Notification.Name("fixtureScheduleUpdate")
}
@MainActor final class SSOSessionService {
    static let shared = SSOSessionService()
    var lastFailureMessage: String?
    func requestRefresh(force: Bool) async -> Bool { fatalError("Live SSO is forbidden") }
}
struct GradeHistoryWebView: View {
    let mode: GradeQueryMode
    let onResult: (GradeHistoryWebResult) -> Void
    var body: some View {
        Color.clear.task {
            guard Fixture.finishGrades else { return }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            onResult(.historySuccess(GradeHistoryViewModel.sampleData))
        }
    }
}
struct FixtureScreen: View {
    let name: String
    @State private var showDetail = false
    @State private var identity = UUID()
    @State private var detailIdentity = UUID()
    var body: some View {
        VStack {
            Text(name)
            NavigationLink("Nested detail", destination: Text("View destination"))
        }
        .navigationTitle(name)
        .onAppear { Fixture.appeared(name, id: identity) }
        .onDisappear { Fixture.disappeared(name, id: identity) }
        .onReceive(Fixture.details) { showDetail = true }
        .navigationDestination(isPresented: $showDetail) {
            Text("Nested detail").onAppear { Fixture.appeared("detail", id: detailIdentity) }
                .onDisappear { Fixture.disappeared("detail", id: detailIdentity) }
        }
    }
}
struct MoodleAttendanceScannerView: View {
    let onReturnHome: () -> Void
    @State private var showResult = false
    @State private var identity = UUID()
    @State private var resultIdentity = UUID()
    var body: some View {
        Text("Synthetic scanner")
            .onAppear { Fixture.appeared("attendance", id: identity) }
            .onDisappear { Fixture.disappeared("attendance", id: identity) }
            .onReceive(Fixture.details) { showResult = true }
            .navigationDestination(isPresented: $showResult) {
                Text("Synthetic attendance result")
                    .onAppear { Fixture.appeared("result", id: resultIdentity); Fixture.returnHome = onReturnHome }
                    .onDisappear { Fixture.disappeared("result", id: resultIdentity); Fixture.returnHome = nil }
            }
    }
}
'''
for name in ["Settings", "Moodle", "ClassSchedule", "LibraryCode", "LibraryEquipment", "AcademicCalendar",
             "EventRegistration", "GraduationThreshold", "Mail", "EnrollmentCertificate", "PostalQuery", "LeaveRecords"]:
    source += f'struct {name}View: View {{ var body: some View {{ FixtureScreen(name: "{name}") }} }}\n'
source += r'''
struct CheckFailure: Error { let reason: String }
@main struct ChecksApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(AppState())
                .environmentObject(CampusRouter.shared)
                .task {
                    guard !Fixture.driverStarted else { return }
                    Fixture.driverStarted = true
                    // The fixture driver must survive the Home screen's navigation cancellation.
                    Task { await runChecks() }
                }
        }
    }
    @MainActor func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw CheckFailure(reason: reason) }
    }
    @MainActor func waitFor(timeout: Duration = .seconds(6), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                throw CheckFailure(reason: "Timed out at \(Fixture.stage); models=\(Fixture.gradeModels.count), visible=\(Fixture.visible), appearances=\(Fixture.screenAppearances), depths=\(navigationControllers().map { $0.viewControllers.count })")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(450))
    }
    @MainActor func navigationControllers() -> [UINavigationController] {
        func descendants(_ controller: UIViewController) -> [UINavigationController] {
            ((controller as? UINavigationController).map { [$0] } ?? []) + controller.children.flatMap(descendants)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).compactMap(\.rootViewController).flatMap(descendants)
    }
    @MainActor func runChecks() async {
        var result: [String: String]
        do {
            try await Task.sleep(for: .seconds(1))
            try require(Fixture.gradeModels.isEmpty, "Home created grade state before opening its destination")
            Fixture.stage = "tools category"
            Fixture.commands.send("tools")
            try await waitFor { navigationControllers().first?.topViewController?.navigationItem.title == "小工具" }
            try require(navigationControllers().count == 1 && navigationControllers()[0].viewControllers.count == 2,
                        "Tools must use the Home stack with a back destination")
            Fixture.stage = "equipment open"
            Fixture.commands.send("equipment")
            try await waitFor { Fixture.visible.contains("LibraryEquipment") }
            try require(navigationControllers().first?.viewControllers.count == 3,
                        "Equipment must retain Tools as its parent")
            Fixture.commands.send("back")
            try await waitFor { navigationControllers().first?.topViewController?.navigationItem.title == "小工具"
                && navigationControllers().first?.viewControllers.count == 2 }
            Fixture.stage = "postal open"
            Fixture.commands.send("postal")
            try await waitFor { Fixture.visible.contains("PostalQuery") }
            try require(navigationControllers().first?.viewControllers.count == 3,
                        "Postal must retain Tools as its parent")
            Fixture.commands.send("back")
            try await waitFor { navigationControllers().first?.topViewController?.navigationItem.title == "小工具" }
            Fixture.commands.send("back")
            try await waitFor { navigationControllers().first?.viewControllers.count == 1 }
            Fixture.stage = "leave records open"
            Fixture.commands.send("leave")
            try await waitFor { Fixture.visible.contains("LeaveRecords") }
            try require(navigationControllers().first?.viewControllers.count == 2,
                        "Leave records must use the Home stack with a back destination")
            Fixture.commands.send("back")
            try await waitFor { navigationControllers().first?.viewControllers.count == 1 }
            Fixture.stage = "first grade open"
            let manualEntry = ProcessInfo.processInfo.arguments.contains("--manual-first-entry")
            if !manualEntry { Fixture.commands.send("grades") }
            try await waitFor(timeout: manualEntry ? .seconds(40) : .seconds(6)) {
                Fixture.gradeModels.first?.loadState == .loaded
            }
            try require(Fixture.gradeModels.count == 1, "The first grade open should construct exactly one model")
            let navigation = navigationControllers()
            try require(navigation.count == 1 && navigation[0].viewControllers.count == 2,
                        "Grades must use the Home stack and retain its back navigation")
            try require(navigation[0].topViewController?.navigationItem.title == "成績查詢",
                        "The first grade destination did not reach the visible navigation column")
            Fixture.stage = "return home"
            Fixture.commands.send("home")
            try await waitFor { navigationControllers().first?.viewControllers.count == 1 }
            Fixture.stage = "second grade open"
            Fixture.commands.send("grades")
            try await waitFor { Fixture.gradeModels.count == 2 && Fixture.gradeModels.last?.loadState == .loaded }
            try require(navigationControllers().count == 1, "Reopening grades created a nested stack")

            let oldModel = Fixture.gradeModels.last!
            Fixture.finishGrades = false
            oldModel.refresh()
            let oldRequest = oldModel.webViewID
            Fixture.stage = "cancel pending grades"
            Fixture.commands.send("home")
            try await waitFor { !oldModel.isRefreshing }
            oldModel.handleWebResult(.failure("stale fixture"), requestID: oldRequest)
            try require(oldModel.lastRefreshError == nil && oldModel.loadState == .loaded,
                        "Leaving grades allowed its old result to change state")
            Fixture.finishGrades = true
            Fixture.stage = "third grade open"
            Fixture.commands.send("grades")
            try await waitFor { Fixture.gradeModels.count == 3 && Fixture.gradeModels.last?.loadState == .loaded }

            // A shortcut replaces grades; repeating it must remove subordinate details.
            Fixture.stage = "library shortcut"
            CampusRouter.shared.open(.library)
            try await waitFor { Fixture.visible.contains("LibraryCode") }
            Fixture.stage = "nested library detail"
            Fixture.details.send()
            try await waitFor { Fixture.visible.contains("detail") }
            let libraryCount = Fixture.screenAppearances["LibraryCode", default: 0]
            Fixture.stage = "repeat library shortcut"
            CampusRouter.shared.open(.library)
            try await waitFor { Fixture.screenAppearances["LibraryCode", default: 0] > libraryCount
                && Fixture.visible.contains("LibraryCode") && !Fixture.visible.contains("detail") }
            try require(navigationControllers().first?.viewControllers.count == 2,
                        "A repeated shortcut left an old nested destination")
            Fixture.stage = "attendance shortcut"
            CampusRouter.shared.open(.attendance)
            try await waitFor { Fixture.visible.contains("attendance") }
            Fixture.stage = "attendance result"
            Fixture.details.send()
            try await waitFor { Fixture.returnHome != nil && Fixture.visible.contains("result") }
            Fixture.stage = "attendance to home"
            Fixture.returnHome?()
            try await waitFor { navigationControllers().first?.viewControllers.count == 1
                && !Fixture.visible.contains("result") }
            Fixture.stage = "grades after attendance"
            Fixture.commands.send("grades")
            try await waitFor { Fixture.gradeModels.count == 4 && Fixture.gradeModels.last?.loadState == .loaded }
            result = ["status": "passed", "checks":
                "Tools grid, equipment/postal to Tools to Home back stack, leave card to LeaveRecords, cold first grade open, native back stack, reopen, loading cancellation, stale result, shortcut replacement, repeated shortcut from detail, attendance result to Home, grade reentry"]
        } catch {
            result = ["status": "failed", "reason": String(describing: error)]
        }
        do {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("result.json")
            try JSONSerialization.data(withJSONObject: result).write(to: url, options: .atomic)
        } catch { print("Unable to write navigation fixture result") }
    }
}
'''


def run(*command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="niu-home-navigation-") as directory:
    folder = Path(directory)
    app = folder / "HomeNavigationChecks.app"
    app.mkdir()
    files = []
    for name, contents in [("HomeView.swift", home), ("GradeHistoryView.swift", grade),
                           ("GradeHistoryViewModel.swift", model), ("Checks.swift", source)]:
        path = folder / name
        path.write_text(contents)
        files.append(path)
    files += [root / "NIU-LiveActivities/CampusNavigation.swift",
              root / "NIU-LiveActivities/ClassScheduleModels.swift",
              root / "Features/GradeHistory/Models/GradeHistoryModels.swift",
              root / "Shared/Theme/Theme.swift", root / "Shared/Components/NIUComponents.swift"]
    plist = dict(CFBundleIdentifier=bundle, CFBundleName="HomeNavigationChecks",
                 CFBundleExecutable="HomeNavigationChecks", CFBundlePackageType="APPL",
                 CFBundleVersion="1", CFBundleShortVersionString="1.0", MinimumOSVersion="26.0",
                 LSRequiresIPhoneOS=True, UIDeviceFamily=[1, 2], UILaunchScreen={})
    (app / "Info.plist").write_bytes(plistlib.dumps(plist))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    run("xcrun", "swiftc", "-swift-version", "5", "-sdk", sdk,
        "-target", "arm64-apple-ios26.0-simulator", "-parse-as-library",
        "-module-cache-path", str(folder / "ModuleCache"), *map(str, files),
        "-o", str(app / "HomeNavigationChecks"))
    run("codesign", "--force", "--sign", "-", str(app), stdout=subprocess.DEVNULL)
    run("xcrun", "simctl", "install", args.device, str(app))
    container = Path(subprocess.check_output([
        "xcrun", "simctl", "get_app_container", args.device, bundle, "data"], text=True).strip())
    output = container / "Documents/result.json"
    output.unlink(missing_ok=True)
    launch = ["xcrun", "simctl", "launch", args.device, bundle]
    if args.manual_first_entry:
        launch.append("--manual-first-entry")
    run(*launch)
    try:
        deadline = time.monotonic() + (95 if args.manual_first_entry else 55)
        while not output.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not output.exists():
            raise RuntimeError("No simulator result before the test deadline")
        result = json.loads(output.read_text())
        if result["status"] != "passed":
            raise RuntimeError(result)
        print("PASS: " + result["checks"])
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle],
                       check=False, capture_output=True)
