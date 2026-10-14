#!/usr/bin/env python3
"""Exercise the post-update release notes decision with isolated defaults."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

# WhatsNewStore reads StorageKeys from AppState.swift, which pulls in the whole app.
# Stub the two keys here and verify they still match the real definitions.
app_state = (ROOT / "Core/Models/AppState.swift").read_text()
keys = {name: re.search(rf'static let {name} = "([^"]+)"', app_state).group(1)
        for name in ("loginTime", "authSessionID")}

FIXTURE = r'''
import Foundation

enum StorageKeys {
    static let loginTime = "%(loginTime)s"
    static let authSessionID = "%(authSessionID)s"
}

@main struct Checks {
    @MainActor static func main() {
        let item = ReleaseNotes.Item(icon: "star", title: "t", detail: "d")
        let catalog = [
            ReleaseNotes(version: "1.7.0", items: [item]),
            ReleaseNotes(version: "1.5.0", items: [item]),
            ReleaseNotes(version: "1.6.0", items: [item])
        ]
        var suites: [String] = []
        func freshDefaults() -> UserDefaults {
            let suite = "dev.chienniuapp.whatsnew-fixture.\(UUID().uuidString)"
            suites.append(suite)
            return UserDefaults(suiteName: suite)!
        }
        defer { suites.forEach { UserDefaults().removePersistentDomain(forName: $0) } }
        func store(_ defaults: UserDefaults, _ version: String) -> WhatsNewStore {
            WhatsNewStore(defaults: defaults, currentVersion: version, catalog: catalog)
        }
        let key = WhatsNewStore.lastSeenVersionKey

        // Fresh install: no prompt, and the installed version becomes the baseline.
        var defaults = freshDefaults()
        precondition(store(defaults, "1.5.0").pendingNotes.isEmpty, "fresh installs are not prompted")
        precondition(defaults.string(forKey: key) == "1.5.0")
        precondition(store(defaults, "1.5.0").pendingNotes.isEmpty)

        // Shown once after an update, and not again after it is seen.
        let updated = store(defaults, "1.6.0")
        precondition(updated.pendingNotes.map(\.version) == ["1.6.0"], "an update introduces itself")
        precondition(store(defaults, "1.6.0").pendingNotes.map(\.version) == ["1.6.0"],
                     "an unseen prompt survives relaunch")
        updated.markSeen()
        precondition(updated.pendingNotes.isEmpty)
        precondition(defaults.string(forKey: key) == "1.6.0")
        precondition(store(defaults, "1.6.0").pendingNotes.isEmpty, "seen notes do not return")

        // Skipped versions are combined, newest first, without notes beyond the installed version.
        defaults = freshDefaults()
        defaults.set("1.4.0", forKey: key)
        precondition(store(defaults, "1.6.0").pendingNotes.map(\.version) == ["1.6.0", "1.5.0"])
        precondition(store(defaults, "1.7.0").pendingNotes.map(\.version) == ["1.7.0", "1.6.0", "1.5.0"])

        // A version without notes records itself so later updates compare against it.
        defaults = freshDefaults()
        defaults.set("1.5.0", forKey: key)
        precondition(store(defaults, "1.5.1").pendingNotes.isEmpty, "patches without notes are silent")
        precondition(defaults.string(forKey: key) == "1.5.1")
        precondition(store(defaults, "1.6.0").pendingNotes.map(\.version) == ["1.6.0"])

        // Updating from a version older than this feature shows only the installed version.
        for legacyKey in WhatsNewStore.legacyUsageKeys {
            defaults = freshDefaults()
            defaults.set(Date(), forKey: legacyKey)
            let legacy = store(defaults, "1.6.0")
            precondition(legacy.pendingNotes.map(\.version) == ["1.6.0"], "legacy key \(legacyKey) marks an update")
            precondition(defaults.string(forKey: key) == nil, "pending notes are not recorded before they are seen")
            legacy.markSeen()
            precondition(store(defaults, "1.6.0").pendingNotes.isEmpty)
        }
        defaults = freshDefaults()
        defaults.set(Date(), forKey: AppUpdateChecker.lastCheckKey)
        precondition(store(defaults, "1.5.1").pendingNotes.isEmpty)
        precondition(defaults.string(forKey: key) == "1.5.1", "legacy users without notes start tracking")

        // Installing an older build neither prompts nor moves the record backwards.
        defaults = freshDefaults()
        defaults.set("1.7.0", forKey: key)
        let older = store(defaults, "1.6.0")
        precondition(older.pendingNotes.isEmpty)
        older.markSeen()
        precondition(defaults.string(forKey: key) == "1.7.0")

        // Invalid installed or stored versions never prompt; an invalid record is replaced.
        defaults = freshDefaults()
        defaults.set(Date(), forKey: StorageKeys.loginTime)
        precondition(store(defaults, "").pendingNotes.isEmpty)
        precondition(store(defaults, "1.6.0-beta").pendingNotes.isEmpty)
        defaults.set("garbage", forKey: key)
        precondition(store(defaults, "1.6.0").pendingNotes.isEmpty)
        precondition(defaults.string(forKey: key) == "1.6.0")

        precondition(store(freshDefaults(), "1.6.0").currentNotes?.version == "1.6.0")
        precondition(store(freshDefaults(), "1.6.1").currentNotes == nil)

        // The shipped catalog must be valid, newest first and free of duplicates.
        let shipped = ReleaseNotes.catalog.map(\.version)
        precondition(Set(shipped).count == shipped.count, "duplicate release notes")
        precondition(zip(shipped, shipped.dropFirst()).allSatisfy { AppUpdateChecker.isNewer($0, than: $1) },
                     "catalog must be strictly newest first with numeric versions")
        precondition(ReleaseNotes.catalog.allSatisfy { !$0.items.isEmpty })
        print("PASS: fresh install, show once, relaunch, skipped versions, silent patches, legacy installs, downgrades, invalid versions, catalog order")
    }
}
''' % keys

with tempfile.TemporaryDirectory(prefix="niu-whats-new-") as directory:
    directory = Path(directory)
    fixture = directory / "Checks.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
        str(ROOT / "Core/Services/AppUpdateChecker.swift"), str(ROOT / "Core/Services/WhatsNewStore.swift"),
        str(fixture), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
