#!/usr/bin/env python3
"""Offline Analytics configuration and fixture-isolation checks; no SDK or network."""
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / "App/Info.plist").read_bytes())
for key in (
    "FIREBASE_ANALYTICS_COLLECTION_ENABLED",
    "GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_STORAGE",
    "GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_USER_DATA",
    "GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS",
    "GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED",
    "FirebaseAutomaticScreenReportingEnabled",
):
    assert info[key] is False, key

project = json.loads(subprocess.check_output([
    "plutil", "-convert", "json", "-o", "-", str(root / "NIU-App.xcodeproj/project.pbxproj")
]))
objects = project["objects"]
for target in (o for o in objects.values() if o.get("isa") == "PBXNativeTarget"):
    products = {objects[i]["productName"] for i in target.get("packageProductDependencies", [])}
    if target["name"] == "NIU-APP":
        assert {"FirebaseCore", "FirebaseAnalyticsCore"} <= products
        assert not products & {"FirebaseAnalytics", "FirebaseAnalyticsIdentitySupport"}
        for config in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            assert "-ObjC" in objects[config]["buildSettings"]["OTHER_LDFLAGS"]
    else:
        assert not any(p.startswith("Firebase") for p in products)
privacy = plistlib.loads((root / "Resources/PrivacyInfo.xcprivacy").read_bytes())
collected = {item["NSPrivacyCollectedDataType"] for item in privacy["NSPrivacyCollectedDataTypes"]}
assert {
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypeProductInteraction",
    "NSPrivacyCollectedDataTypeCoarseLocation",
} <= collected
assert privacy["NSPrivacyTracking"] is False
app_source = (root / "App/NIUApp.swift").read_text()
delegate = app_source[app_source.index("final class NIUAppDelegate:"):]
checks = r'''
import Foundation
struct UIApplication {
    struct LaunchOptionsKey: Hashable {}
}
protocol UIApplicationDelegate {}
enum NIUApp { static var isRunningUIFixture = false }
enum ConsentType: Hashable { case analyticsStorage, adStorage, adUserData, adPersonalization }
enum ConsentStatus { case granted, denied }
enum FirebaseApp {
    static var configured = false
    static func configure() { configured = true }
}
enum Analytics {
    // Simulate an earlier normal launch having persisted an enabled preference.
    static var enabled = true
    static var consent: [ConsentType: ConsentStatus] = [:]
    static func setConsent(_ value: [ConsentType: ConsentStatus]) { consent = value }
    static func setAnalyticsCollectionEnabled(_ value: Bool) {
        if value {
            precondition(FirebaseApp.configured, "do not collect before configuration")
            precondition(consent[.analyticsStorage] == .granted)
            for kind in [ConsentType.adStorage, .adUserData, .adPersonalization] {
                precondition(consent[kind] == .denied, "deny ads before enabling collection")
            }
        }
        enabled = value
    }
}
@main struct Checks {
    static func main() {
        let delegate = NIUAppDelegate()
        NIUApp.isRunningUIFixture = true
        precondition(delegate.application(UIApplication()))
        precondition(!FirebaseApp.configured && !Analytics.enabled,
                     "offline fixtures override a previously enabled preference")
        NIUApp.isRunningUIFixture = false
        precondition(delegate.application(UIApplication()))
        precondition(FirebaseApp.configured && Analytics.enabled,
                     "normal app launch enables Analytics")
        NIUApp.isRunningUIFixture = true
        precondition(delegate.application(UIApplication()))
        precondition(!Analytics.enabled, "returning to a fixture disables collection")
        print("PASS: production delegate enables Analytics with advertising denied; offline fixtures disable persisted collection")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-analytics-check-") as directory:
    folder = Path(directory)
    source = folder / "Checks.swift"
    source.write_text(checks + "\n" + delegate)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(folder / "ModuleCache"), str(source), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
print("PASS: Analytics without IDFA, main-target-only linkage, linker flags and privacy declarations")
