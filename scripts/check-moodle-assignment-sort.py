#!/usr/bin/env python3
"""Compile production assignment sorting and ViewModel with synthetic offline data."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
tabs = (ROOT / "Features/Moodle/CourseDetail/MoodleCourseTabViews.swift").read_text()
start = tabs.index("@MainActor\nfinal class MoodleAssignmentsListViewModel")
end = tabs.index("\nstruct MoodleCourseAssignmentsView", start)

CHECKS = r'''
import Foundation
import Combine

struct MoodleAssignmentsSnapshot {
    let assignments: [MoodleAssignment]
    let submittedStatus: [Int: Bool]
}

@MainActor protocol MoodleAssignmentsRepositoryProtocol {
    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot
}

@MainActor final class MoodleAssignmentsRepository: MoodleAssignmentsRepositoryProtocol {
    var result: [MoodleAssignment] = []
    var pending: CheckedContinuation<MoodleAssignmentsSnapshot, Never>?
    var hold = false
    func fetchAssignments(courseId: Int) async throws -> MoodleAssignmentsSnapshot {
        if hold { return await withCheckedContinuation { pending = $0 } }
        return MoodleAssignmentsSnapshot(assignments: result, submittedStatus: [2: true])
    }
}

func assignment(_ id: Int, due: Int) -> MoodleAssignment {
    MoodleAssignment(id: id, cmid: id, course: 1, name: "同名作業", intro: "",
                     duedate: due, allowsubmissionsfromdate: 0, grade: nil, timemodified: 0)
}

@main struct Checks {
    @MainActor static func main() async {
        let items = [assignment(9, due: 0), assignment(4, due: 200),
                     assignment(2, due: 100), assignment(7, due: 0),
                     assignment(3, due: 200), assignment(1, due: 50)]
        let soonest = [1, 2, 3, 4, 7, 9]
        let latest = [3, 4, 2, 1, 7, 9]
        precondition(MoodleAssignmentSortOrder.defaultOrder == .dueSoonestFirst)
        for order in MoodleAssignmentSortOrder.allCases {
            let expected = order == .dueSoonestFirst ? soonest : latest
            for offset in items.indices {
                let rotated = Array(items[offset...] + items[..<offset])
                precondition(order.sorted(rotated).map(\.id) == expected)
                precondition(order.sorted(Array(rotated.reversed())).map(\.id) == expected)
            }
            precondition(order.sorted([]).isEmpty)
            precondition(order.sorted([items[0]]).map(\.id) == [9])
            precondition(order.sorted([items[0], items[3]]).map(\.id) == [7, 9])
            precondition(order.sorted(order.sorted(items)).map(\.id) == expected)
        }
        print("PASS: both date orders, undated last, ID ties independent of input order, empty/single lists")

        let repository = MoodleAssignmentsRepository()
        repository.result = items
        let model = MoodleAssignmentsListViewModel(repository: repository)
        await model.load(courseId: 1)
        precondition(model.assignments.map(\.id) == soonest)
        model.setSortOrder(.dueLatestFirst)
        precondition(model.assignments.map(\.id) == latest)
        model.setSortOrder(.dueSoonestFirst)
        precondition(model.assignments.map(\.id) == soonest)
        precondition(model.submittedStatus[2] == true)
        model.setSortOrder(.dueLatestFirst)
        precondition(model.assignments.map(\.id) == latest)

        // A saved non-default choice is applied before the initial fetch.
        let restored = MoodleAssignmentsListViewModel(repository: repository)
        restored.setSortOrder(.dueLatestFirst)
        await restored.load(courseId: 1)
        precondition(restored.assignments.map(\.id) == latest)

        // Changing the choice during refresh must also sort the arriving data.
        repository.hold = true
        let refresh = Task { await model.load(courseId: 1, force: true) }
        while repository.pending == nil { await Task.yield() }
        model.setSortOrder(.dueSoonestFirst)
        model.updateSubmission(assignmentID: 4, submitted: true)
        repository.pending?.resume(returning: MoodleAssignmentsSnapshot(
            assignments: Array(items.reversed()), submittedStatus: [2: true]))
        repository.pending = nil
        await refresh.value
        precondition(model.assignments.map(\.id) == soonest)
        precondition(!model.isLoading && model.errorMessage == nil)
        precondition(model.submittedStatus[4] == true)
        model.updateSubmission(assignmentID: 4, submitted: false)
        precondition(model.submittedStatus[4] == false)
        model.updateSubmission(assignmentID: 4, submitted: true)
        repository.hold = false
        await model.load(courseId: 1, force: true)
        precondition(model.submittedStatus[4] == nil) // A later server snapshot replaces older local updates.
        print("PASS: soonest-first default, switching, saved non-default selection before load, selection during refresh; newer submission status survives stale refresh")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="niu-moodle-assignment-sort-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text(CHECKS + "\n" + tabs[start:end])
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
        "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
        "-module-cache-path", str(folder / "ModuleCache"),
        str(ROOT / "Features/Moodle/Models/MoodleModels.swift"),
        str(ROOT / "Features/Moodle/Models/MoodleSearch.swift"), str(checks), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
