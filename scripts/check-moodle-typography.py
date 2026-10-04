#!/usr/bin/env python3
"""Static guard for semantic Moodle typography and isolated DEBUG fixture entry."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
base = ROOT / "Features/Moodle"
violations = []
for file in base.rglob("*.swift"):
    for number, line in enumerate(file.read_text().splitlines(), 1):
        if re.search(r"\.font\s*\(\s*\.system\s*\(\s*size\s*:", line):
            violations.append(f"{file.relative_to(ROOT)}:{number}: {line.strip()}")
assert not violations, "Fixed Moodle font sizes:\n" + "\n".join(violations)
home = (base / "Views/MoodleView.swift").read_text().split("// MARK: - Schedule")[0]
assert "semesterRenderToken" not in home and ".onChange" not in home
assert 'Picker("學期", selection: Binding(get: { viewModel.selectedSemester }, set: {' in home
assert 'upcoming.invalidate()' in home and 'viewModel.selectedSemester = $0' in home
assert 'semesterRequest += 1' in home
assert ".glassEffect" not in home and "displaySemesters" not in home
assert "ContentUnavailableView" in home and 'case .empty:' in home
fixture = (base / "Fixtures/MoodleUIFixture.swift").read_text()
assert fixture.startswith("#if DEBUG\n") and fixture.strip().endswith("#endif")
assert "MoodleService.shared" not in fixture and "LoginRepository" not in fixture
app = (ROOT / "App/NIUApp.swift").read_text()
# Evaluate these simple conditional blocks rather than accepting an unguarded root reference.
active = True
stack = []
release_lines = []
for line in app.splitlines():
    if line.strip() == "#if DEBUG":
        stack.append(active)
        active = False
    elif line.strip() == "#else":
        active = stack[-1] and not active
    elif line.strip() == "#endif":
        active = stack.pop()
    elif active:
        release_lines.append(line)
assert "MoodleUIFixture" not in "\n".join(release_lines)
project = (ROOT / "NIU-App.xcodeproj/project.pbxproj").read_text()
assert "Features/Moodle/Fixtures/MoodleUIFixture.swift" in project
ids = re.findall(r"^\t\t([A-F0-9]{24})[^\n]* = \{", project, re.M)
assert len(ids) == len(set(ids)), "Duplicate Xcode project object IDs"
assignment = (base / "Views/MoodleAssignmentView.swift").read_text()
assert "if let editSubmissionURL = repository.webSubmissionURL(for: assignment)" in assignment
print("PASS: Moodle semantic fonts (0 fixed sizes), bound semester picker and DEBUG-only fixture entry")
