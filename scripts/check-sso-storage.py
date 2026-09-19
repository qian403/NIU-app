#!/usr/bin/env python3
"""Exercise SSO migration using a fresh Keychain service and isolated defaults.
Never accesses the app's real Keychain items or preferences.
"""
from pathlib import Path
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
identifier = 'dev.chienniuapp.preflight-fixture.' + str(uuid.uuid4())
source = (root / 'Core/Services/SSOTokenStore.swift').read_text()
source = source.replace('private init()', 'init()')
source = source.replace('(Bundle.main.bundleIdentifier ?? "dev.chienniuapp") + ".sso"', f'"{identifier}"')
source = source.replace('UserDefaults.standard', f'UserDefaults(suiteName: "{identifier}")!')
source += '''
extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
@main struct Checks {
    @MainActor static func main() {
'''
source += f'        let defaults = UserDefaults(suiteName: "{identifier}")!\n'
source += f'        defer {{ defaults.removePersistentDomain(forName: "{identifier}") }}\n'
source += '''
        defaults.set("fixture-old-token", forKey: "app.sso.token")
        defaults.set("2099-01-01T00:00:00Z", forKey: "app.sso.token.exp")
        defaults.set("FIXTURE", forKey: "app.sso.token.account")
        let store = SSOTokenStore()
        defer { store.clear() }
        precondition(store.token == "fixture-old-token", "migration must persist in isolated Keychain")
        precondition(store.account == "fixture")
        precondition(store.isLikelyValid)
        precondition(defaults.object(forKey: "app.sso.token") == nil)
        let restored = SSOTokenStore()
        precondition(restored.token == store.token, "new process/store must restore saved token")
        store.save(token: "fixture-new-token", exp: nil, account: "FIXTURE")
        store.clear(ifMatching: "fixture-old-token")
        precondition(store.token == "fixture-new-token", "old 401 must not clear new session")
        store.clear(ifMatching: "fixture-new-token")
        precondition(store.token == nil)
        precondition(SSOTokenStore().token == nil, "logout must delete persisted token")
        print("PASS: isolated SSO Keychain migration, restore, replacement, stale rejection and deletion")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-sso-storage-') as directory:
    directory = Path(directory)
    fixture = directory / 'Checks.swift'
    fixture.write_text(source)
    binary = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(directory / 'ModuleCache'), str(fixture), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
