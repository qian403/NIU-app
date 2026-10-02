#!/usr/bin/env python3
"""Check that Moodle tokens only reach the school host and stay out of REST URLs, offline.
Usage: python3 scripts/check-moodle-token-scope.py
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Features/Moodle/Services/MoodleService.swift").read_text()


def method(signature: str) -> str:
    start = source.index(signature)
    end = source.index("\n    }\n", start) + len("\n    }\n")
    return source[start:end]


assert not re.search(r'URLQueryItem\(name: "wstoken"', source), "wstoken must not be a URL query item"
# Log statements must not expose raw URLs, HTML, response text or error payloads.
logs = "\n".join(line for line in source.splitlines() if "print(" in line)
for unsafe in ["absoluteString", ".query", "html.prefix", r"\(error)", "failureReasons.joined",
               r"\(hiddenEnv)", r"\(hiddenP)", r"\(hiddenPage)"]:
    assert unsafe not in logs, f"Unsafe diagnostic: {unsafe}"
assert r"htmlBytes=\(html.utf8.count)" in logs
assert logs.count("diagnosticLocation(for:") == 2
helpers = source[source.index("private extension String {"):]
attendance = helpers.index("// MARK: - Attendance HTML Patterns")
request_body = helpers[helpers.index("nonisolated enum MoodleRequestBody"):]

fixture = "import Foundation\n" + helpers[:attendance].replace("private ", "") + \
    request_body.replace("private ", "") + r'''
enum MoodleError: Error { case invalidURL }

struct Service {
    let token: String?
    let baseURL = "https://euni.niu.edu.tw"
    func applyMoodleMobileHeaders(to request: inout URLRequest) {}
''' + method("    func fileURL(for rawURL: String) -> URL? {") + \
    method("    private func webServiceRequest(").replace("private ", "") + \
    method("    private func diagnosticLocation(").replace("private ", "") + r'''
}

@main
struct Checks {
    static func main() async throws {
        let service = Service(token: "SYNTHETIC")
        for raw in ["https://user:password@euni.niu.edu.tw/admin/tool/mobile/autologin.php?key=SYNTHETIC#private",
                    "https://euni.niu.edu.tw/admin/tool/mobile/autologin.php?urltogo=secret&token=SYNTHETIC"] {
            precondition(service.diagnosticLocation(for: URL(string: raw))
                == "euni.niu.edu.tw/admin/tool/mobile/autologin.php")
        }
        precondition(service.diagnosticLocation(for: nil) == "nil")
        print("PASS: diagnostic URLs retain only host/path; log statements omit HTML and raw errors")
        for raw in ["https://evil.example/a.png", "//evil.example/a.png",
                    "https://euni.niu.edu.tw.evil.example/a.png", "https://euni.niu.edu.tw:8443/a.png",
                    "https://user@euni.niu.edu.tw/a.png"] {
            let url = service.fileURL(for: raw)
            precondition(url != nil && !url!.absoluteString.contains("SYNTHETIC"), raw)
        }
        precondition(service.fileURL(for: "https://evil.example/a.png")?.absoluteString
            == "https://evil.example/a.png")
        precondition(service.fileURL(for: "https://euni.niu.edu.tw/webservice/pluginfile.php/1/a.png")?.absoluteString
            == "https://euni.niu.edu.tw/webservice/pluginfile.php/1/a.png?token=SYNTHETIC")
        precondition(service.fileURL(for: "https://EUNI.niu.edu.tw/webservice/pluginfile.php/1/a.png?forcedownload=1")?
            .absoluteString == "https://EUNI.niu.edu.tw/webservice/pluginfile.php/1/a.png?forcedownload=1&token=SYNTHETIC")
        precondition(service.fileURL(for: "http://euni.niu.edu.tw/webservice/pluginfile.php/1/a.png")?.absoluteString
            == "https://euni.niu.edu.tw/webservice/pluginfile.php/1/a.png?token=SYNTHETIC")
        precondition(Service(token: nil).fileURL(for: "https://euni.niu.edu.tw/a.png") == nil)

        let request = try await service.webServiceRequest(
            function: "core_webservice_get_site_info", token: "SYN+TOKEN", params: ["q": "a+b&c"])
        precondition(request.httpMethod == "POST")
        precondition(!request.url!.absoluteString.contains("TOKEN"), request.url!.absoluteString)
        precondition(request.url!.absoluteString == "https://euni.niu.edu.tw/webservice/rest/server.php"
            + "?wsfunction=core_webservice_get_site_info&moodlewsrestformat=json")
        var body = URLComponents()
        body.percentEncodedQuery = String(decoding: request.httpBody!, as: UTF8.self)
        let fields = Dictionary(uniqueKeysWithValues: body.queryItems!.map { ($0.name, $0.value ?? "") })
        precondition(fields == ["wstoken": "SYN+TOKEN", "q": "a+b&c"], "\(fields)")
        print("PASS: token only on https school host, external images unchanged, wstoken in POST body only")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-moodle-token-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text(fixture)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-module-cache-path", str(folder / "ModuleCache"), str(checks), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
