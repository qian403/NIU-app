import Foundation
import ActivityKit

nonisolated struct ClassLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let mode: String // "current" or "upcoming"
        let courseName: String
        let classroom: String
        let teacher: String
        let periodLabel: String
        let startDate: Date
        let endDate: Date
        /// Start and end of each period when consecutive periods of one course are
        /// merged. Optional so pushes and states without them decode as one period.
        var periodStartDates: [Date]? = nil
        var periodEndDates: [Date]? = nil

        /// Timer-backed class time of each period; the breaks between them are not
        /// part of any span. Malformed periods fall back to one span for the block.
        var progressSegments: [ClosedRange<Date>]? {
            guard endDate > startDate else { return nil }
            guard let starts = periodStartDates, let ends = periodEndDates,
                  starts.count > 1, starts.count == ends.count,
                  starts.first == startDate, ends.last == endDate,
                  zip(starts, ends).allSatisfy({ $0 < $1 }),
                  zip(ends, starts.dropFirst()).allSatisfy({ $0 <= $1 }) else {
                return [startDate...endDate]
            }
            return zip(starts, ends).map { $0...$1 }
        }
    }

    let startedAt: Date
    let token: String
}
