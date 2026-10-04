#!/usr/bin/env python3
"""Run the production activity filters with synthetic data, without login or WebKit."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
feature = root / "Features/EventRegistration"
source = (feature / "Models/EventRegistrationModels.swift").read_text()

# Compile the actual computed properties, avoiding ViewModel initialization and sessions.
for tab, model in [(1, "EventData"), (2, "EventData_Apply")]:
    view_model = (
        feature / f"ViewModels/EventRegistration_Tab{tab}_ViewModel.swift"
    ).read_text()
    start = view_model.index("    var filteredEvents:")
    end = view_model.index("    // MARK: - Loading", start)
    source += f"""
struct SearchTab{tab} {{
    var events: [{model}]
    var searchText = ""
    var favoritesOnly = false
    var favoriteIDs = Set<String>()
{view_model[start:end]}
}}
"""

source += r'''
@main struct Checks {
    static func main() throws {
        func fixture(id: String, name: String, department: String,
                     detail: String, state: String) -> [String: String] {
            [
                "eventSerialID": id, "name": name, "department": department,
                "eventDetail": detail, "state": state, "event_state": "報名中",
                "eventTime": "", "eventLocation": "", "eventRegisterTime": "",
                "contactInfoName": "", "contactInfoTel": "", "contactInfoMail": "",
                "Related_links": "", "Multi_factor_authentication": "",
                "eventPeople": "", "Remark": ""
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            fixture(id: "0012345", name: "Swift 工作坊", department: "資訊中心",
                    detail: "程式設計入門", state: "報名成功"),
            fixture(id: "98765", name: "攝影講座", department: "學務處",
                    detail: "構圖技巧", state: "候補")
        ])
        var available = SearchTab1(events: try JSONDecoder().decode([EventData].self, from: data))
        var applied = SearchTab2(events: try JSONDecoder().decode([EventData_Apply].self, from: data))
        let all = ["0012345", "98765"]
        let cases: [(String, [String])] = [
            ("0012345", ["0012345"]), ("123", ["0012345"]),
            ("001", ["0012345"]), ("98765", ["98765"]),
            (" 0012345\n", ["0012345"]), ("９８７６５", ["98765"]),
            ("SWIFT", ["0012345"]), ("資訊中心", ["0012345"]),
            ("構圖", ["98765"]), (" 攝影 ", ["98765"]),
            ("不存在", []), ("000000", []), ("", all), (" \n\t ", all)
        ]
        for (query, expected) in cases {
            available.searchText = query
            applied.searchText = query
            precondition(available.filteredEvents.map(\.id) == expected,
                         "Available events failed query: \(query)")
            precondition(applied.filteredEvents.map(\.id) == expected,
                         "Applied events failed query: \(query)")
        }
        applied.searchText = "候補"
        precondition(applied.filteredEvents.map(\.id) == ["98765"])
        available.searchText = "候補"
        precondition(available.filteredEvents.isEmpty)
        applied.searchText = ""
        precondition(applied.filteredEvents.map(\.id) == all)
        print("PASS: both tabs search full/partial IDs, leading zeros, pasted whitespace, full-width digits")
        print("PASS: existing text/status search, no matches, empty query, clearing search, stable order")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-event-search-") as directory:
    directory = Path(directory)
    swift = directory / "Checks.swift"
    swift.write_text(source)
    binary = directory / "checks"
    subprocess.run(
        ["xcrun", "swiftc", "-module-cache-path", str(directory / "ModuleCache"),
         "-parse-as-library", str(swift), "-o", str(binary)],
        check=True,
    )
    subprocess.run([str(binary)], check=True, timeout=10)
