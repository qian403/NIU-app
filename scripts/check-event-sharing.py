#!/usr/bin/env python3
"""Exercise public activity sharing with synthetic data; never read credentials."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
models = root / 'Features/EventRegistration/Models/EventRegistrationModels.swift'
checks = r'''
@main struct Checks {
    static func main() throws {
        let meeting = "https://teams.microsoft.com/meet/123456789?p=synthetic&source=app#join"
        let form = "https://forms.gle/syntheticExample"
        let raw = "活動說明 👋\n" + meeting + "<br />講者：測試講師\n相關連結：" + form
        let linked = EventTextLinks.attributedText(raw)
        let urls = linked.runs.compactMap { $0.link?.absoluteString }
        precondition(urls == [meeting, form], "URLs must preserve query parameters and fragments")
        precondition(String(linked.characters) == raw.replacingOccurrences(of: "<br />", with: "\n"))
        precondition(EventTextLinks.attributedText("純文字說明").runs.allSatisfy { $0.link == nil })
        precondition(EventTextLinks.attributedText("file:///tmp/test").runs.allSatisfy { $0.link == nil })
        print("PASS: embedded web links, Unicode ranges, line breaks, full query and fragment")
        let fields: [String: String] = [
            "name": "測試活動", "department": "測試單位", "event_state": "報名中",
            "state": "私人報名狀態", "eventSerialID": "12345", "eventTime": "2026/10/1",
            "eventLocation": "測試教室", "eventRegisterTime": "2026/9/30",
            "eventDetail": "說明", "contactInfoName": "聯絡人", "contactInfoTel": "電話",
            "contactInfoMail": "信箱", "Related_links": "https://example.com/?token=private",
            "Multi_factor_authentication": "認證", "eventPeople": "1", "Remark": "私人備註"
        ]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let available = try JSONDecoder().decode(EventData.self, from: data).shareContent
        let applied = try JSONDecoder().decode(EventData_Apply.self, from: data).shareContent
        precondition(available.text == applied.text)
        precondition(available.url?.absoluteString == "https://ccsys.niu.edu.tw/MvcTeam/Act/Apply/12345")
        for value in ["測試活動", "測試單位", "2026/10/1", "測試教室", "2026/9/30", "活動連結："] {
            precondition(available.text.contains(value))
        }
        for value in ["私人", "token", "聯絡人", "信箱"] {
            precondition(!applied.text.contains(value))
        }
        for id in ["", "../123", "123?token=private", "123#fragment", "１２３", "123\n", "https://example.com"] {
            let invalid = EventShareContent(name: "活動", department: "", time: "", location: "", registrationTime: "", eventID: id)
            precondition(invalid.url == nil, "invalid IDs must not create share URLs")
            precondition(invalid.text == "活動")
        }
        print("PASS: both activity types share public fields and canonical links; invalid IDs rejected")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='niu-event-share-') as directory:
    directory = Path(directory)
    source = directory / 'Checks.swift'
    source.write_text(models.read_text() + checks)
    binary = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(directory / 'ModuleCache'),
                    '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
