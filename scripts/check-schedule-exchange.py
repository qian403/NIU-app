#!/usr/bin/env python3
"""Compile the real timetable share model and store; exercise encoding, hostile input, terms, free periods,
store write ordering and the encrypted file format with synthetic data and an in-memory backend only."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKS = r'''
import Foundation
import Compression

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
func error(_ text: String, _ now: Date) -> ScheduleShareError? {
    do { _ = try ScheduleSharePayload.decode(text, now: now); return nil } catch { return error as? ScheduleShareError }
}
/// Builds a code from raw JSON so hostile payloads skip the encoder's own cleaning.
func code(json: String) -> String {
    let data = json.data(using: .utf8)!
    var output = Data(count: data.count + 1024)
    let written = output.withUnsafeMutableBytes { dst in
        data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, data.count + 1024,
                                      src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    let base = output.prefix(written).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return ScheduleSharePayload.prefix + base
}

let now = instant("2026-10-23T02:00:00Z")   // Taipei Fri 2026-10-23 10:00
let headers = ["星期一", "星期二", "星期三", "星期四", "星期五"]
func periods(_ fill: (Int, Int) -> CourseInfo?) -> [ClassPeriod] {
    (1...10).map { row -> ClassPeriod in
        var courses: [Int: CourseInfo] = [:]
        for day in 0..<5 { if let course = fill(row, day) { courses[day] = course } }
        return ClassPeriod(id: "\(row)", timeRange: String(format: "%02d:10~%02d:00", row + 7, row + 8), courses: courses)
    }
}
/// Stand-ins for app types the store reads; the real Keychain is never touched.
enum StorageKeys {
    static let username = "check.username"
    static let authSessionID = "check.sessionID"
}

final class MemoryBackend: ScheduleExchangeBackend, @unchecked Sendable {
    var index: [String: ScheduleExchangeAccountEntry] = [:]
    var files: [UUID: [ExchangedSchedule]] = [:]
    var failure: ScheduleExchangeBackendError?
    func accountEntry(for account: String) throws -> ScheduleExchangeAccountEntry {
        if let failure { throw failure }
        if let entry = index[account] { return entry }
        let entry = ScheduleExchangeAccountEntry(storageID: UUID(), preferences: ScheduleSharePreferences())
        index[account] = entry
        return entry
    }
    func savePreferences(_ preferences: ScheduleSharePreferences, for account: String) throws {
        if let failure { throw failure }
        index[account]?.preferences = preferences
    }
    func load(storageID: UUID) throws -> [ExchangedSchedule] {
        if let failure { throw failure }
        return files[storageID] ?? []
    }
    func save(_ list: [ExchangedSchedule], storageID: UUID) throws {
        if let failure { throw failure }
        files[storageID] = list.isEmpty ? nil : list
    }
    func removeAccount(_ account: String) throws {
        if let failure { throw failure }
        if let entry = index.removeValue(forKey: account) { files[entry.storageID] = nil }
    }
}

let wire = #"{"v":1,"i":"6F1C2E0B-6E57-4D6A-9E0F-0B9E3C1D2A4B","y":115,"s":1,"t":1792720800,"n":"小明","d":[0,1],"p":["1","2"],"a":[490,540,550,600],"c":["微積分"],"x":[0,0,0,-1,-1]}"#

@main struct Checks {
    @MainActor static func main() {
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!

        let term = ScheduleShareTerm(containing: now)
        require(term == ScheduleShareTerm(academicYear: 115, semester: 1), "2026-10 is 115-1")
        require(ScheduleShareTerm(containing: instant("2027-01-31T15:59:00Z")) == term, "Taipei 1/31 23:59 still semester 1")
        require(ScheduleShareTerm(containing: instant("2027-01-31T16:00:00Z")) == ScheduleShareTerm(academicYear: 115, semester: 2), "Taipei 2/1 00:00 is semester 2")
        require(ScheduleShareTerm(containing: instant("2026-07-31T16:00:00Z")) == ScheduleShareTerm(academicYear: 115, semester: 1), "Taipei 8/1 starts the new academic year")
        require(term.endDate == instant("2027-01-31T16:00:00Z"), "semester 1 ends at Taipei 2/1 midnight")
        require(term.next.endDate == instant("2027-07-31T16:00:00Z"), "semester 2 ends at Taipei 8/1 midnight")
        print("PASS: Asia/Taipei semester boundaries")

        // Worst realistic case: every weekday period filled, 40 distinct long names, rooms and teachers.
        let busy = ClassSchedule(periods: periods { row, day in
            let n = (row * 5 + day) % 40
            return CourseInfo(name: "跨領域人工智慧應用專題實作（二）第\(n)組", teacher: "授課教師\(n % 25)", classroom: "綜合大樓\(n % 20)樓教室")
        }, dayCount: 5, dayHeaders: headers, fetchedAt: now)
        let shareID = UUID()
        let minimal = ScheduleSharePayload(schedule: busy, shareID: shareID, term: term, nickname: "小明",
                                           includeRooms: false, includeTeachers: false, createdAt: now)
        let minimalCode = try! minimal.encoded()
        print("INFO: 50 slots / 40 names without rooms or teachers -> \(minimalCode.count) characters")
        let full = ScheduleSharePayload(schedule: busy, shareID: shareID, term: term, nickname: "小明",
                                        includeRooms: true, includeTeachers: true, createdAt: now)
        let fullLength = (try? full.encoded())?.count
        print("INFO: with rooms and teachers -> \(fullLength.map(String.init) ?? "over the limit")")
        require(minimalCode.count <= ScheduleSharePayload.maxEncodedLength, "worst case without extras fits")

        let typical = ClassSchedule(periods: periods { row, day in
            row % 3 == 0 ? nil : CourseInfo(name: "課程\(day)-\(row / 3)", teacher: "教師", classroom: "E\(day)0\(row)")
        }, dayCount: 5, dayHeaders: headers, fetchedAt: now)
        let typicalPayload = ScheduleSharePayload(schedule: typical, shareID: shareID, term: term, nickname: "小明",
                                                  includeRooms: true, includeTeachers: true, createdAt: now)
        let typicalCode = try! typicalPayload.encoded()
        print("INFO: typical table with rooms and teachers -> \(typicalCode.count) characters")
        require(try! ScheduleSharePayload.decode(typicalCode, now: now) == typicalPayload, "round trip with extras")
        require(try! ScheduleSharePayload.decode(minimalCode, now: now) == minimal, "round trip")
        require(minimal.rooms.isEmpty && minimal.teachers.isEmpty && minimal.slots.allSatisfy { $0.room == nil && $0.teacher == nil }, "extras omitted unless chosen")
        require(!minimalCode.contains("授課") && minimal.days == [0, 1, 2, 3, 4], "only whitelisted fields")
        print("PASS: size budget and round trip")

        var owned = typical
        owned.ownerSessionID = "secret-session"
        let ownedCode = try! ScheduleSharePayload(schedule: owned, shareID: shareID, term: term, nickname: "x",
                                                  includeRooms: true, includeTeachers: true, createdAt: now).encoded()
        let plainCode = try! ScheduleSharePayload(schedule: typical, shareID: shareID, term: term, nickname: "x",
                                                  includeRooms: true, includeTeachers: true, createdAt: now).encoded()
        require(ownedCode == plainCode, "session ID never encoded; sorted keys keep output stable")
        let custom = ClassSchedule(periods: periods { row, day in
            row == 1 && day == 0 ? CourseInfo(name: "自訂", customCourseID: UUID(), customColorID: "red") : nil
        }, dayCount: 5, dayHeaders: headers, fetchedAt: now)
        require(ScheduleSharePayload(schedule: custom, shareID: shareID, term: term, nickname: "x", includeRooms: true,
                                     includeTeachers: true, createdAt: now).slots.count == 1, "callers pass the school schedule; IDs are not fields")
        print("PASS: whitelist excludes session and custom course IDs")

        require(ScheduleSharePayload.clean("\u{202E}微積分\u{0000}\n(一)") == "微積分 (一)", "bidi and control characters removed")
        require(ScheduleSharePayload.cleanNickname(String(repeating: "長", count: 40)).count == 20, "nickname capped")
        require(ScheduleSharePayload.clean(String(repeating: "字", count: 40)).utf8.count <= 64, "UTF-8 cap on whole characters")
        require(ScheduleSharePayload.cleanNickname("👨‍👩‍👧 小明") == "👨‍👩‍👧 小明", "emoji joiners kept")
        print("PASS: text cleaning")

        let ok = code(json: wire)
        require((try? ScheduleSharePayload.decode(ok, now: now))?.nickname == "小明", "hand-built code accepted")
        require(error("https://example.com", now) == .notScheduleCode, "foreign QR rejected")
        require(error("NIUTT2:abc", now) == .unsupportedVersion, "newer version rejected")
        require(error(ScheduleSharePayload.prefix + "!!!", now) == .malformed, "bad base64")
        require(error(String(repeating: "A", count: 5000), now) == .tooLarge, "oversized input")
        require(error(code(json: wire.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)), now) == .unsupportedVersion, "wire version checked")
        require(error(code(json: wire.replacingOccurrences(of: "小明", with: "\u{202E}小明")), now) == .malformed, "bidi in nickname")
        require(error(code(json: wire.replacingOccurrences(of: "微積分", with: "微積分\u{0007}")), now) == .malformed, "control in name")
        require(error(code(json: wire.replacingOccurrences(of: "[0,0,0,-1,-1]", with: "[0,0,5,-1,-1]")), now) == .malformed, "name index out of range")
        require(error(code(json: wire.replacingOccurrences(of: "[0,0,0,-1,-1]", with: "[0,0,0,0,-1]")), now) == .malformed, "room index without rooms")
        require(error(code(json: wire.replacingOccurrences(of: "[0,0,0,-1,-1]", with: "[3,0,0,-1,-1]")), now) == .malformed, "slot on uncovered day")
        require(error(code(json: wire.replacingOccurrences(of: "[0,0,0,-1,-1]", with: "[0,0,0,-1,-1,0,0,0,-1,-1]")), now) == .malformed, "duplicate slot")
        require(error(code(json: wire.replacingOccurrences(of: "[490,540,550,600]", with: "[540,490,550,600]")), now) == .malformed, "reversed period")
        require(error(code(json: wire.replacingOccurrences(of: "[490,540,550,600]", with: "[490,2000,550,600]")), now) == .malformed, "minutes bounded")
        require(error(code(json: wire.replacingOccurrences(of: "[0,0,0,-1,-1]", with: "[]")), now) == .empty, "empty table")
        let bomb = wire.replacingOccurrences(of: #""n":"小明""#, with: #""n":"小明","z":""# + String(repeating: "a", count: 40_000) + #"""#)
        require(error(code(json: bomb), now) == .malformed, "decompression past 32 KiB rejected")
        print("PASS: hostile input rejected")

        require(error(ok, instant("2026-10-24T02:00:01Z")) == .expiredCode, "older than 24 hours")
        require(error(ok, instant("2026-10-24T01:59:59Z")) == nil, "within 24 hours")
        require(error(ok, instant("2026-10-23T01:57:00Z")) == nil, "small clock skew tolerated")
        require(error(ok, instant("2026-10-23T01:00:00Z")) == .futureCode, "future code rejected")
        let ended = code(json: wire.replacingOccurrences(of: #""y":115"#, with: #""y":114"#))
        require(error(ended, now) == .termEnded, "ended semester rejected")
        print("PASS: code age and term")

        // Free periods compare real minutes: the friend's periods start 10 minutes earlier than mine.
        func friend(_ name: String, days: [Int], periods: [ScheduleSharePayload.Period], slots: [(Int, Int)]) -> ScheduleSharePayload {
            ScheduleSharePayload(shareID: UUID(), term: term, createdAt: now, nickname: name, days: days, periods: periods,
                                 names: ["課"], rooms: [], teachers: [],
                                 slots: slots.map { ScheduleSharePayload.Slot(day: $0.0, period: $0.1, name: 0, room: nil, teacher: nil) })
        }
        let early = (0..<10).map { ScheduleSharePayload.Period(id: "\($0 + 1)", start: 480 + $0 * 60, end: 530 + $0 * 60) }
        let sparse = ScheduleSharePayload(schedule: typical, shareID: shareID, term: term, nickname: "我",
                                          includeRooms: false, includeTeachers: false, createdAt: now)
        let a = friend("甲", days: [0, 1, 2, 3, 4], periods: early, slots: [(1, 0), (4, 3)])
        let b = friend("乙", days: [0, 1, 2], periods: early, slots: [])
        let grid = ScheduleFreeTime.grid(base: sparse, others: [a, b], days: [0, 1, 2, 3, 4])
        require(grid.count == 10 && grid[0].count == 5, "rows follow base periods")
        require(grid[2][0] == .free, "第3節 Monday free for everyone")
        require(grid[0][1] == .busy(["我", "甲"]), "08:00–08:50 overlaps 08:10–09:00")
        require(grid[2][4] == .unknown(["乙"]), "uncovered weekday is unknown, not free")
        require(grid[3][4] == .busy(["我", "甲"]), "11:00–11:50 overlaps 11:10–12:00")
        require(grid[1][0] == .busy(["我"]), "own classes count")
        require(grid[5][0] == .free, "10-minute breaks between periods are covered")

        // 乙's table lost 第5–6節 (unparseable times): that afternoon is unknown, not free.
        let gappy = friend("乙", days: [0, 1, 2], periods: early.enumerated().filter { ![4, 5].contains($0.offset) }.map(\.element), slots: [])
        let gapGrid = ScheduleFreeTime.grid(base: sparse, others: [gappy], days: [0])
        require(gapGrid[5][0] == .unknown(["乙"]), "missing rows are unknown")
        require(gapGrid[2][0] == .free, "covered rows still compared")
        require(!gappy.covers(day: 0, start: 1000, end: 1100) && gappy.covers(day: 0, start: 480, end: 700), "coverage spans short breaks only")
        let shown = a.classSchedule
        require(shown.dayHeaders == ["星期一", "星期二", "星期三", "星期四", "星期五"] && shown.periods.count == 10, "shared table as a timetable")
        require(shown.periods[0].course(for: 1)?.name == "課" && shown.periods[0].timeRange == "08:00~08:50"
                && shown.periods[0].startMinutes == 480 && shown.periods[0].course(for: 0) == nil, "slots placed by weekday column")
        require(b.classSchedule.dayHeaders == ["星期一", "星期二", "星期三"], "only covered days become columns")
        let withRoom = ScheduleSharePayload(schedule: typical, shareID: shareID, term: term, nickname: "x",
                                            includeRooms: true, includeTeachers: true, createdAt: now).classSchedule
        require(withRoom.periods[0].course(for: 0)?.classroom == "E001" && withRoom.periods[0].course(for: 0)?.teacher == "教師", "room and teacher kept")
        // 甲 vs 我: free only where neither has class and both tables cover the time.
        let together = a.freeSlots(with: [sparse])
        require(!together.contains(100 + 0) && !together.contains(0 * 100 + 0), "either person's class blocks the slot")
        require(together.contains(2), "Monday 10:00–10:50 free for both (my 第3節 starts 10:10)")
        require(!b.freeSlots(with: [sparse]).contains(400), "a day the classmate does not cover is never free")
        // Three people: my table as the base, 甲 and 乙 together.
        let group = sparse.freeSlots(with: [a, b])
        require(group.contains(2) && !group.contains(400 + 2), "everyone free on Monday 第3節; Friday unknown for 乙")
        require(group.isSubset(of: sparse.freeSlots(with: [a])), "adding people never adds free slots")
        print("PASS: common free periods by minute overlap")

        let backend = MemoryBackend()
        let storeA = ScheduleExchangeStore(backend: backend, account: "a")
        storeA.reload(now: now)
        require(storeA.status == .ready && storeA.schedules.isEmpty && storeA.isCurrent, "fresh account ready")
        require(storeA.save(a, replacing: nil, now: now) == storeA.schedules.first?.id && storeA.schedules.count == 1, "saved")
        let storageA = backend.index["a"]!.storageID
        require(backend.files[storageA]?.count == 1, "written through the backend")
        require(storeA.existing(matching: a)?.payload == a, "same share ID and term matches")
        var nextTerm = a; nextTerm.term = term.next
        require(storeA.existing(matching: nextTerm) == nil, "another term is a separate entry")
        require(storeA.save(a, replacing: storeA.schedules[0].id, now: now) == storeA.schedules[0].id && storeA.schedules.count == 1, "update replaces")

        backend.failure = .unreadable
        let kept = storeA.schedules
        require(!storeA.delete(id: kept[0].id) && storeA.schedules == kept && storeA.errorMessage != nil, "failed delete keeps the entry visible")
        require(storeA.save(b, replacing: nil, now: now) == nil && storeA.schedules == kept, "failed save changes nothing")
        backend.failure = .locked
        require(!storeA.delete(id: kept[0].id) && storeA.status == .locked && !storeA.isCurrent, "locked write marks the store locked")
        require(storeA.save(b, replacing: nil, now: now) == nil, "no writes while locked")
        storeA.reload(now: now)
        require(storeA.status == .locked && storeA.schedules.isEmpty, "locked read shows nothing and changes nothing")
        require(backend.files[storageA]?.count == 1, "data on disk untouched while locked")
        backend.failure = nil
        storeA.reload(now: now)
        require(storeA.status == .ready && storeA.schedules.count == 1, "readable again after unlock")
        print("PASS: store writes before memory; locked and failed writes")

        let storeB = ScheduleExchangeStore(backend: backend, account: "b")
        storeB.reload(now: now)
        require(storeB.schedules.isEmpty && backend.index["b"]!.storageID != storageA, "accounts isolated")
        storeA.clearMemory()
        require(storeA.schedules.isEmpty && storeA.status == .signedOut && !storeA.isCurrent, "logout clears memory only")
        require(backend.files[storageA]?.count == 1, "logout keeps the account's file")
        print("PASS: per-account storage")

        var old = a; old.term = ScheduleShareTerm(academicYear: 114, semester: 2)   // ended 2026-08-01
        var recent = a; recent.term = ScheduleShareTerm(academicYear: 115, semester: 1)
        backend.files[storageA] = [ExchangedSchedule(id: UUID(), payload: old, importedAt: now),
                                   ExchangedSchedule(id: UUID(), payload: recent, importedAt: now)]
        let feb20 = instant("2027-02-20T00:00:00Z")
        storeA.reload(now: feb20)
        require(storeA.schedules.count == 1 && storeA.schedules[0].isExpired(at: feb20), "ended term kept for 30 days, older removed")
        require(backend.files[storageA]?.count == 1, "cleanup persisted")
        storeA.reload(now: instant("2027-03-04T00:00:00Z"))
        require(storeA.schedules.isEmpty, "removed after the grace period")
        print("PASS: expiry and 30-day cleanup")

        let key = Data(repeating: 7, count: 32), sid = UUID()
        let entries = [ExchangedSchedule(id: UUID(), payload: a, importedAt: now)]
        let sealed = try! KeychainFileScheduleExchangeBackend.seal(entries, key: key, storageID: sid)
        require(try! KeychainFileScheduleExchangeBackend.open(sealed, key: key, storageID: sid) == entries, "round trip")
        require(!String(decoding: sealed, as: UTF8.self).contains("甲"), "ciphertext only")
        require((try? KeychainFileScheduleExchangeBackend.open(sealed, key: key, storageID: UUID())) == nil, "bound to its storage ID")
        require((try? KeychainFileScheduleExchangeBackend.open(sealed, key: Data(repeating: 8, count: 32), storageID: sid)) == nil, "wrong key")
        var tampered = sealed; tampered[tampered.count / 2] ^= 1
        require((try? KeychainFileScheduleExchangeBackend.open(tampered, key: key, storageID: sid)) == nil, "tampering detected")
        print("PASS: AES-GCM file format")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-schedule-exchange-") as folder:
    temp = Path(folder)
    main = temp / "Checks.swift"
    main.write_text(CHECKS)
    binary = temp / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-D", "DEBUG", "-module-cache-path", str(temp / "module-cache"),
        str(ROOT / "NIU-LiveActivities/ClassScheduleModels.swift"),
        str(ROOT / "Features/ClassSchedule/Models/ScheduleShareModels.swift"),
        str(ROOT / "Features/ClassSchedule/Services/ScheduleExchangeStore.swift"),
        str(main), "-o", str(binary),
    ], check=True)
    print(subprocess.check_output([str(binary)], text=True), end="")
