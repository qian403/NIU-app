import Foundation

struct MoodleAttendanceRecord: Identifiable {
    enum Status {
        case present
        case absent
        case pending
    }

    let id: Int
    let date: Date
    let timeText: String
    let description: String?
    let statusLabel: String
    let scoreText: String?
    let remarks: String?
    let status: Status

    var isPresent: Bool { status == .present }
}

struct MoodleAttendanceSection: Identifiable {
    enum Source {
        case webService
        case htmlFallback
    }

    let id: Int
    let sectionName: String
    let moduleName: String
    let records: [MoodleAttendanceRecord]
    let total: Int
    let source: Source

    var presentCount: Int {
        records.filter { $0.status == .present }.count
    }

    var absentCount: Int {
        records.filter { $0.status == .absent }.count
    }

    var pendingCount: Int {
        max(total - presentCount - absentCount, 0)
    }

    var resolvedCount: Int {
        presentCount + absentCount
    }

    var attendanceRate: Double {
        guard resolvedCount > 0 else { return 0 }
        return Double(presentCount) / Double(resolvedCount)
    }
}
