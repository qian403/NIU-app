import Foundation
import Compression

// MARK: - Term

/// A school semester in Asia/Taipei: 第1學期 8/1–1/31, 第2學期 2/1–7/31.
nonisolated struct ScheduleShareTerm: Codable, Hashable, Sendable, Comparable {
    let academicYear: Int
    let semester: Int

    init(academicYear: Int, semester: Int) {
        self.academicYear = academicYear
        self.semester = semester
    }

    init(containing date: Date) {
        let parts = ScheduleClock.calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 2026, month = parts.month ?? 1
        academicYear = year - (month >= 8 ? 1911 : 1912)
        semester = month >= 8 || month == 1 ? 1 : 2
    }

    var title: String { "\(academicYear) 學年度第 \(semester) 學期" }

    /// Taipei midnight of the next semester's first day (2/1 or 8/1).
    var endDate: Date {
        let year = academicYear + 1912
        let month = semester == 1 ? 2 : 8
        return ScheduleClock.calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    var next: ScheduleShareTerm {
        semester == 1 ? ScheduleShareTerm(academicYear: academicYear, semester: 2)
                      : ScheduleShareTerm(academicYear: academicYear + 1, semester: 1)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.academicYear, lhs.semester) < (rhs.academicYear, rhs.semester)
    }
}

// MARK: - Payload

/// Whitelisted data in a timetable QR code. Built field by field from the school schedule so
/// session IDs, custom course IDs and anything else on `ClassSchedule` can never leak into it.
nonisolated struct ScheduleSharePayload: Codable, Equatable, Sendable {
    nonisolated struct Period: Codable, Equatable, Sendable {
        let id: String
        /// Minutes after Taipei midnight.
        let start: Int
        let end: Int
    }

    nonisolated struct Slot: Codable, Equatable, Sendable {
        /// Monday-based: 0 = 星期一 … 6 = 星期日.
        let day: Int
        let period: Int
        let name: Int
        let room: Int?
        let teacher: Int?
    }

    static let prefix = "NIUTT1:"
    /// QR codes are readable by anyone nearby; this only stops old screenshots from circulating.
    static let validity: TimeInterval = 24 * 60 * 60
    static let clockSkew: TimeInterval = 5 * 60
    /// Keeps the code scannable on a phone screen at error correction level M.
    static let maxEncodedLength = 1800

    static let maxInputLength = 4096
    static let maxDecompressedBytes = 32 * 1024
    static let maxPeriods = 20
    static let maxStrings = 80
    static let maxSlots = 140
    static let maxTextBytes = 64
    static let maxNicknameLength = 20

    var shareID: UUID
    var term: ScheduleShareTerm
    var createdAt: Date
    var nickname: String
    /// Weekdays the sharer's table covers; other days are unknown, not free.
    var days: [Int]
    var periods: [Period]
    var names: [String]
    var rooms: [String]
    var teachers: [String]
    var slots: [Slot]

    var hasRooms: Bool { !rooms.isEmpty }
    var hasTeachers: Bool { !teachers.isEmpty }
}

nonisolated enum ScheduleShareError: Error, Equatable {
    case notScheduleCode
    case unsupportedVersion
    case malformed
    case tooLarge
    case expiredCode
    case futureCode
    case termEnded
    case empty

    var message: String {
        switch self {
        case .notScheduleCode: "這不是 NIU App 的課表 QR Code。"
        case .unsupportedVersion: "這個 QR Code 來自較新版本的 App，請先更新 App 再掃描。"
        case .malformed: "QR Code 內容不完整或格式錯誤，請請對方重新產生。"
        case .tooLarge: "QR Code 內容超過可接受的大小。"
        case .expiredCode: "這個 QR Code 已超過 24 小時，請請對方重新產生。"
        case .futureCode: "QR Code 的建立時間晚於這台裝置的時間，請確認裝置時間設定。"
        case .termEnded: "這份課表的學期已經結束。"
        case .empty: "這份課表沒有任何課程。"
        }
    }
}

// MARK: - Building

extension ScheduleSharePayload {
    /// Monday-based weekday for a header such as "星期三".
    nonisolated static func mondayBasedDay(_ header: String) -> Int? {
        ScheduleClock.weekday(header).map { ($0 + 5) % 7 }
    }

    /// School courses only. Custom courses have per-day expiry and stay on this device.
    nonisolated init(schedule: ClassSchedule, shareID: UUID, term: ScheduleShareTerm, nickname: String,
         includeRooms: Bool, includeTeachers: Bool, createdAt: Date) {
        self.shareID = shareID
        self.term = term
        self.createdAt = createdAt
        self.nickname = Self.cleanNickname(nickname)

        let columns: [(column: Int, day: Int)] = schedule.dayHeaders.enumerated().compactMap { column, header in
            Self.mondayBasedDay(header).map { (column, $0) }
        }
        days = Array(Set(columns.map(\.day))).sorted()

        var periods: [Period] = []
        var names = StringTable(), rooms = StringTable(), teachers = StringTable()
        var slots: [Slot] = []
        for period in schedule.periods {
            guard let start = period.startMinutes, let end = period.endMinutes, start < end else { continue }
            let index = periods.count
            periods.append(Period(id: Self.clean(period.id), start: start, end: end))
            for (column, day) in columns {
                guard let course = period.course(for: column) else { continue }
                let name = Self.clean(course.name)
                guard !name.isEmpty else { continue }
                let room = includeRooms ? course.classroom.map { Self.clean($0) }.flatMap { $0.isEmpty ? nil : $0 } : nil
                let teacher = includeTeachers ? course.teacher.map { Self.clean($0) }.flatMap { $0.isEmpty ? nil : $0 } : nil
                slots.append(Slot(day: day, period: index, name: names.index(of: name),
                                  room: room.map { rooms.index(of: $0) },
                                  teacher: teacher.map { teachers.index(of: $0) }))
            }
        }
        self.periods = periods
        self.names = names.values
        self.rooms = rooms.values
        self.teachers = teachers.values
        self.slots = slots
    }

    /// Drops control and bidirectional-override characters, collapses whitespace and caps the UTF-8 size.
    nonisolated static func clean(_ text: String, maxBytes: Int = maxTextBytes) -> String {
        let bidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                 0x2066, 0x2067, 0x2068, 0x2069]
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if bidi.contains(scalar.value) { continue }
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        for character in collapsed {
            guard result.utf8.count + String(character).utf8.count <= maxBytes else { break }
            result.append(character)
        }
        return result
    }

    nonisolated static func cleanNickname(_ text: String) -> String {
        String(clean(text).prefix(maxNicknameLength))
    }

    nonisolated private struct StringTable {
        var values: [String] = []
        private var lookup: [String: Int] = [:]
        mutating func index(of value: String) -> Int {
            if let index = lookup[value] { return index }
            values.append(value)
            lookup[value] = values.count - 1
            return values.count - 1
        }
    }
}

// MARK: - Wire format

extension ScheduleSharePayload {
    /// Short keys keep the QR small; slots are flattened as [day, period, name, room, teacher] with -1 for none.
    nonisolated private struct Wire: Codable {
        let v: Int
        let i: String
        let y: Int
        let s: Int
        let t: Int64
        let n: String
        let d: [Int]
        let p: [String]
        let a: [Int]
        let c: [String]
        let r: [String]?
        let e: [String]?
        let x: [Int]
    }

    nonisolated func encoded() throws -> String {
        let wire = Wire(
            v: 1, i: shareID.uuidString, y: term.academicYear, s: term.semester,
            t: Int64(createdAt.timeIntervalSince1970.rounded()), n: nickname, d: days,
            p: periods.map(\.id), a: periods.flatMap { [$0.start, $0.end] }, c: names,
            r: rooms.isEmpty ? nil : rooms, e: teachers.isEmpty ? nil : teachers,
            x: slots.flatMap { [$0.day, $0.period, $0.name, $0.room ?? -1, $0.teacher ?? -1] })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys   // same input, same QR
        let json = try encoder.encode(wire)
        guard let compressed = Self.deflate(json) else { throw ScheduleShareError.malformed }
        let text = Self.prefix + Self.base64URL(compressed)
        guard text.count <= Self.maxEncodedLength else { throw ScheduleShareError.tooLarge }
        return text
    }

    /// Treats `text` as untrusted: every size, index and string is bounded before use.
    nonisolated static func decode(_ text: String, now: Date) throws -> ScheduleSharePayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxInputLength else { throw ScheduleShareError.tooLarge }
        guard trimmed.hasPrefix("NIUTT") else { throw ScheduleShareError.notScheduleCode }
        guard trimmed.hasPrefix(prefix) else { throw ScheduleShareError.unsupportedVersion }
        guard let compressed = data(base64URL: String(trimmed.dropFirst(prefix.count))),
              let json = inflate(compressed, limit: maxDecompressedBytes) else { throw ScheduleShareError.malformed }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: json) else { throw ScheduleShareError.malformed }
        guard wire.v == 1 else { throw ScheduleShareError.unsupportedVersion }

        let rooms = wire.r ?? [], teachers = wire.e ?? []
        guard wire.p.count <= maxPeriods, wire.c.count <= maxStrings, rooms.count <= maxStrings,
              teachers.count <= maxStrings, wire.x.count <= maxSlots * 5, wire.d.count <= 7
        else { throw ScheduleShareError.tooLarge }
        guard let shareID = UUID(uuidString: wire.i), (1...2).contains(wire.s), (100...300).contains(wire.y),
              wire.a.count == wire.p.count * 2, wire.x.count % 5 == 0,
              Set(wire.d).count == wire.d.count, wire.d.allSatisfy((0...6).contains)
        else { throw ScheduleShareError.malformed }

        func valid(_ values: [String]) -> Bool {
            values.allSatisfy { $0.utf8.count <= maxTextBytes && clean($0) == $0 && !$0.isEmpty }
        }
        guard valid(wire.c), valid(rooms), valid(teachers), wire.p.allSatisfy({ $0.utf8.count <= maxTextBytes && clean($0) == $0 }),
              cleanNickname(wire.n) == wire.n
        else { throw ScheduleShareError.malformed }

        var periods: [Period] = []
        for index in wire.p.indices {
            let start = wire.a[index * 2], end = wire.a[index * 2 + 1]
            guard (0..<1440).contains(start), (1...1440).contains(end), start < end else { throw ScheduleShareError.malformed }
            periods.append(Period(id: wire.p[index], start: start, end: end))
        }

        var slots: [Slot] = []
        var occupied = Set<Int>()
        for offset in stride(from: 0, to: wire.x.count, by: 5) {
            let day = wire.x[offset], period = wire.x[offset + 1], name = wire.x[offset + 2]
            let room = wire.x[offset + 3], teacher = wire.x[offset + 4]
            guard wire.d.contains(day), periods.indices.contains(period), wire.c.indices.contains(name),
                  room == -1 || rooms.indices.contains(room), teacher == -1 || teachers.indices.contains(teacher),
                  occupied.insert(day * 100 + period).inserted
            else { throw ScheduleShareError.malformed }
            slots.append(Slot(day: day, period: period, name: name,
                              room: room == -1 ? nil : room, teacher: teacher == -1 ? nil : teacher))
        }
        guard !slots.isEmpty else { throw ScheduleShareError.empty }

        let createdAt = Date(timeIntervalSince1970: TimeInterval(wire.t))
        guard createdAt <= now.addingTimeInterval(clockSkew) else { throw ScheduleShareError.futureCode }
        guard now.timeIntervalSince(createdAt) <= validity else { throw ScheduleShareError.expiredCode }
        let term = ScheduleShareTerm(academicYear: wire.y, semester: wire.s)
        guard term.endDate > now else { throw ScheduleShareError.termEnded }

        return ScheduleSharePayload(shareID: shareID, term: term, createdAt: createdAt, nickname: wire.n,
                                    days: wire.d.sorted(), periods: periods, names: wire.c, rooms: rooms,
                                    teachers: teachers, slots: slots)
    }

    // MARK: Compression

    nonisolated private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    /// Fixed-size output buffer: anything that inflates past `limit` is rejected rather than truncated.
    nonisolated private static func inflate(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = limit + 1
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written <= limit else { return nil }
        return output.prefix(written)
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func data(base64URL text: String) -> Data? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
}

// MARK: - Display

extension ScheduleSharePayload {
    nonisolated struct Entry: Equatable, Sendable {
        let day: Int
        let period: Period
        let name: String
        let room: String?
        let teacher: String?
    }

    nonisolated var entries: [Entry] {
        slots.map { slot in
            Entry(day: slot.day, period: periods[slot.period], name: names[slot.name],
                  room: slot.room.map { rooms[$0] }, teacher: slot.teacher.map { teachers[$0] })
        }
        .sorted { ($0.day, $0.period.start) < ($1.day, $1.period.start) }
    }

    nonisolated func entries(on day: Int) -> [Entry] { entries.filter { $0.day == day } }

    /// Distinct course names, for the import preview.
    nonisolated var courseCount: Int { names.count }
}

// MARK: - As a timetable

extension ScheduleSharePayload {
    private nonisolated static let weekdayHeaders = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]

    /// The shared table in the same shape as the user's own, so it can use the same week view.
    /// Row indices match `periods`.
    nonisolated var classSchedule: ClassSchedule {
        let rows = periods.enumerated().map { index, period -> ClassPeriod in
            var courses: [Int: CourseInfo] = [:]
            for slot in slots where slot.period == index {
                guard let column = days.firstIndex(of: slot.day) else { continue }
                courses[column] = CourseInfo(name: names[slot.name], teacher: slot.teacher.map { teachers[$0] },
                                             classroom: slot.room.map { rooms[$0] })
            }
            return ClassPeriod(id: period.id, timeRange: "\(ScheduleSharePayload.clock(period.start))~\(ScheduleSharePayload.clock(period.end))",
                               courses: courses)
        }
        return ClassSchedule(periods: rows, dayCount: days.count, dayHeaders: days.map { Self.weekdayHeaders[$0] },
                             fetchedAt: createdAt)
    }

    private nonisolated static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Rows of this table, keyed `day * 100 + row`, where nobody here or in `others` has class.
    /// Times any table does not cover are left out rather than counted as free.
    nonisolated func freeSlots(with others: [ScheduleSharePayload]) -> Set<Int> {
        let grid = ScheduleFreeTime.grid(base: self, others: others, days: days)
        var result = Set<Int>()
        for (row, cells) in grid.enumerated() {
            for (column, cell) in cells.enumerated() where cell == .free {
                result.insert(days[column] * 100 + row)
            }
        }
        return result
    }
}

// MARK: - Common free periods

extension ScheduleSharePayload {
    /// Breaks up to this long between two periods count as covered by the table.
    nonisolated static let maxCoveredBreak = 20

    /// Whether the sharer's table says anything about `start..<end` on `day`. Rows the school table
    /// omitted, or whose times failed to parse, never reach `periods`, so those minutes stay unknown.
    nonisolated func covers(day: Int, start: Int, end: Int) -> Bool {
        guard days.contains(day) else { return false }
        var reached: Int?
        for period in periods.sorted(by: { $0.start < $1.start }) {
            if let current = reached, period.start - current <= Self.maxCoveredBreak {
                reached = max(current, period.end)
            } else if period.start <= start {
                reached = period.end
            } else {
                break
            }
            if let current = reached, current >= end { return true }
        }
        return false
    }
}

nonisolated enum ScheduleFreeSlot: Equatable, Sendable {
    case free
    /// Someone has a class overlapping this period; names are the participants' nicknames.
    case busy([String])
    /// At least one participant's table does not cover this weekday.
    case unknown([String])
}

nonisolated enum ScheduleFreeTime {
    /// Rows follow `base`'s periods; each cell compares actual minute ranges, not period indices,
    /// because two timetables may number their periods differently.
    static func grid(base: ScheduleSharePayload, others: [ScheduleSharePayload], days: [Int])
        -> [[ScheduleFreeSlot]] {
        let participants = [base] + others
        return base.periods.map { period in
            days.map { day in
                let missing = participants.filter { !$0.covers(day: day, start: period.start, end: period.end) }
                    .map(\.nickname)
                let busy = participants.filter { payload in
                    payload.slots.contains { slot in
                        guard slot.day == day else { return false }
                        let other = payload.periods[slot.period]
                        return other.start < period.end && period.start < other.end
                    }
                }.map(\.nickname)
                if !busy.isEmpty { return .busy(busy) }
                if !missing.isEmpty { return .unknown(missing) }
                return .free
            }
        }
    }
}
