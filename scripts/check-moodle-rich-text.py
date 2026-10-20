#!/usr/bin/env python3
"""Compile production Moodle rich-text parsing; superscript/subscript must survive."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

CHECKS = r'''
import Foundation

func plain(_ html: String) -> String {
    MoodleRichText.runs(html).map { MoodleRichText.scripted($0.text, $0.position) ?? $0.text }.joined()
}

func expect(_ actual: String, _ expected: String, _ label: String) {
    guard actual == expected else {
        print("FAIL \(label): \(actual.debugDescription) != \(expected.debugDescription)")
        exit(1)
    }
}

@main
struct Checks {
    static func main() {
        expect(plain("<p>求 x<sup>2</sup> + y<sup>-1</sup> 的值</p>"), "求 x² + y⁻¹ 的值", "digit superscript")
        expect(plain("H<sub>2</sub>O 與 log<sub>10</sub>"), "H₂O 與 log₁₀", "subscript")
        expect(plain("2<sup>n</sup>、e<SUP class=\"x\">i</SUP>"), "2ⁿ、eⁱ", "letter superscript")
        expect(plain("x&sup2; &times; 3 &lt;b&gt; &#178; &#x2074;"), "x² × 3 <b> ² ⁴", "entities after markup")

        // Characters without Unicode forms stay a separate superscript run for styling.
        let runs = MoodleRichText.runs("10<sup>th</sup> 名, a<sup>2b</sup>")
        guard runs == [
            .init(text: "10", position: .normal), .init(text: "th", position: .superscript),
            .init(text: " 名, a", position: .normal), .init(text: "2b", position: .superscript),
        ] else { print("FAIL fallback runs: \(runs)"); exit(1) }
        guard MoodleRichText.scripted("th", .superscript) == nil else { print("FAIL partial map"); exit(1) }

        expect(plain("<p>第一段\n  說明</p><p>第二段<br>換行</p><ul><li>甲</li><li>乙</li></ul>"),
               "第一段 說明\n\n第二段\n換行\n\n• 甲\n• 乙", "block structure")
        expect(plain("  <div><p>&nbsp;</p></div><p>內容</p><div></div>  "), "內容", "trim empty blocks")
        expect(plain("<style>p{}</style><!-- 註解 --><script>x<sup>9</sup></script>a"), "a", "drop hidden markup")
        expect(plain(""), "", "empty intro")
        print("PASS: assignment intro keeps superscript/subscript, entities and block breaks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-moodle-rich-text-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text(CHECKS)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-module-cache-path", str(folder / "ModuleCache"),
        str(ROOT / "Features/Moodle/Models/MoodleModels.swift"),
        str(ROOT / "Features/Moodle/Models/MoodleSearch.swift"), str(checks), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
