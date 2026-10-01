#!/usr/bin/env python3
"""Compile and exercise the production Moodle request-body helpers, offline.
Usage: python3 scripts/check-moodle-request-body.py
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Features/Moodle/Services/MoodleService.swift").read_text()
helpers = source[source.index("private extension String {"):]
fixture = "import Foundation\n" + helpers.replace("private ", "") + r'''
@main
struct Checks {
    static func main() async throws {
        // Base64 contains + / =; they must not be decoded as space or separators.
        let file = Data([0xfb, 0xff, 0xbf, 0x00, 0x3e])
        let encoded = await MoodleRequestBody.base64(file)
        precondition(encoded.contains("+") && encoded.contains("/") && encoded.contains("="))
        let form = String(decoding: await MoodleRequestBody.form(["filecontent": encoded]), as: UTF8.self)
        precondition(!form.dropFirst("filecontent=".count).contains(where: { "+/=&".contains($0) }), form)
        var components = URLComponents()
        components.percentEncodedQuery = form
        precondition(components.queryItems?.first?.value == encoded)

        let pair = String(decoding: await MoodleRequestBody.form(["filename": "a&b=c d.pdf"]), as: UTF8.self)
        precondition(pair == "filename=a%26b%3Dc%20d.pdf", pair)
        precondition("https://euni.niu.edu.tw/x.php?a=1&b=2".urlEncoded
            == "https%3A%2F%2Feuni.niu.edu.tw%2Fx.php%3Fa%3D1%26b%3D2")

        let body = await MoodleRequestBody.multipart(
            boundary: "B", fields: [("itemid", "7"), ("filepath", "/")],
            file: .init(field: "file_1", filename: "報告.pdf", mimeType: "application/pdf", data: file))
        var expected = Data((
            "--B\r\nContent-Disposition: form-data; name=\"itemid\"\r\n\r\n7\r\n" +
            "--B\r\nContent-Disposition: form-data; name=\"filepath\"\r\n\r\n/\r\n" +
            "--B\r\nContent-Disposition: form-data; name=\"file_1\"; filename=\"報告.pdf\"\r\n" +
            "Content-Type: application/pdf\r\n\r\n").utf8)
        expected.append(file)
        expected.append(Data("\r\n--B--\r\n".utf8))
        precondition(body == expected, "Multipart body changed")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("niu-moodle-body-\(UUID()).bin")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try await MoodleRequestBody.readFile(at: url)
        precondition(read == file)

        let row = "<tr><td class=\"datecol c0\">2026年9月30日 (週三) 10:10</td><td class=\"statuscol\">出席</td></tr>"
        let cells = AttendanceHTMLRegex.cell!.matches(in: row, range: NSRange(row.startIndex..., in: row))
        precondition(cells.count == 2)
        precondition(AttendanceHTMLRegex.cell(classHint: "statuscol")!.firstMatch(
            in: row, range: NSRange(row.startIndex..., in: row)) != nil)
        precondition(AttendanceHTMLRegex.cell(classHint: "unknowncol")!.firstMatch(
            in: row, range: NSRange(row.startIndex..., in: row)) == nil)
        let date = "2026年9月30日 (週三) 10:10"
        let match = AttendanceHTMLRegex.date!.firstMatch(in: date, range: NSRange(date.startIndex..., in: date))
        precondition(match?.numberOfRanges == 4)
        print("PASS: form encoding keeps + / = & intact, multipart layout, off-main file read, cached attendance patterns")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-moodle-body-") as directory:
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
