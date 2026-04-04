import Foundation
import ActivityKit

struct ClassLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let mode: String // "current" or "upcoming"
        let courseName: String
        let classroom: String
        let teacher: String
        let periodLabel: String
        let startDate: Date
        let endDate: Date
        let nextCourseName: String?
        let nextClassroom: String?
        let nextStartDate: Date?
    }

    let token: String
}
