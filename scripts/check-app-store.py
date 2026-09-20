#!/usr/bin/env python3
"""Offline release checks. Optionally inspect an already-built .xcarchive."""
import argparse
import json
import plistlib
import struct
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path)
args = parser.parse_args()

def read_plist(path):
    with path.open('rb') as file:
        return plistlib.load(file)

info = read_plist(root / 'App/Info.plist')
assert info['CFBundleDisplayName'] == 'NIU-Life'
assert info['CFBundleShortVersionString'] == '$(MARKETING_VERSION)'
assert info['CFBundleVersion'] == '$(CURRENT_PROJECT_VERSION)'
assert info['ITSAppUsesNonExemptEncryption'] is False
assert 'NSAppTransportSecurity' not in info  # No broad insecure-transport exception.
for key in ['NSCameraUsageDescription', 'NSCalendarsWriteOnlyUsageDescription']:
    assert info.get(key, '').strip(), key

icons = root / 'Resources/Assets.xcassets/AppIcon.appiconset'
for entry in json.loads((icons / 'Contents.json').read_text())['images']:
    if entry.get('platform') != 'ios' or 'filename' not in entry:
        continue
    data = (icons / entry['filename']).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    assert (width, height) == (1024, 1024)
    assert color == 2, 'Marketing icon must be opaque RGB'

for manifest in ['Resources/PrivacyInfo.xcprivacy', 'NIU-LiveActivities/PrivacyInfo.xcprivacy']:
    privacy = read_plist(root / manifest)
    assert privacy['NSPrivacyTracking'] is False
    defaults = next(api for api in privacy['NSPrivacyAccessedAPITypes']
                    if api['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryUserDefaults')
    assert {'CA92.1', '1C8F.1'} <= set(defaults['NSPrivacyAccessedAPITypeReasons'])

state = (root / 'Core/Models/AppState.swift').read_text()
assert 'your-domain.com' not in state and 'pushType: .token' not in state
assert 'uploadScheduleToBackend' not in state and 'uploadToken' not in state
assert state.count('pushType: LiveActivityRemoteClient.enabled ? .token : nil') == 2
remote_activity = (root / 'Core/Services/LiveActivityRemoteClient.swift').read_text()
assert 'static let consentKey' in remote_activity
assert 'UserDefaults.standard.bool(forKey: consentKey)' in remote_activity
policy_definitions = sum(p.read_text().count('struct PrivacyPolicyView:') for p in (root / 'Features').rglob('*.swift'))
assert policy_definitions == 1
print('PASS: app metadata, opaque icons, privacy manifests, consent-gated activities and shared policy')

if args.archive:
    apps = list((args.archive / 'Products/Applications').glob('*.app'))
    assert len(apps) == 1
    app = apps[0]
    built = read_plist(app / 'Info.plist')
    assert built['CFBundleIdentifier'] == 'dev.chienniuapp'
    assert built['CFBundleDisplayName'] == 'NIU-Life'
    assert built['ITSAppUsesNonExemptEncryption'] is False
    assert (app / 'PrivacyInfo.xcprivacy').is_file()
    extensions = list((app / 'PlugIns').glob('*.appex'))
    assert len(extensions) == 1
    extension = read_plist(extensions[0] / 'Info.plist')
    assert extension['CFBundleIdentifier'] == 'dev.chienniuapp.NIU-LiveActivities'
    for key in ['CFBundleVersion', 'CFBundleShortVersionString', 'MinimumOSVersion']:
        assert built[key] == extension[key], key
    assert (extensions[0] / 'PrivacyInfo.xcprivacy').is_file()
    executable = (app / built['CFBundleExecutable']).read_bytes()
    assert b'your-domain.com' not in executable
    assert '模擬 QR Code 過期'.encode() not in executable
    assert b'scanner allocated' not in executable
    print(f"PASS: archive {built['CFBundleShortVersionString']} ({built['CFBundleVersion']}), "
          f"iOS {built['MinimumOSVersion']}, embedded extension/manifests, no DEBUG attendance controls")
