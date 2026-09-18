import Foundation
import CryptoKit

/// Campus dates stay in Taiwan even when the device uses another time zone/calendar.
nonisolated enum CampusCalendarDate {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return value
    }
    static let monthOrder = Array(8...12) + Array(1...7)

    static func academicYear(at date: Date = Date()) -> Int {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return parts.year! - (parts.month! >= 8 ? 1911 : 1912)
    }
    static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let result = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              dayKey(result) == text else { return nil }
        return result
    }
    static func dayKey(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
    static func tomorrow(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }
    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

nonisolated struct CampusCalendarIndex: Codable, Sendable {
    struct Entry: Codable, Sendable, Equatable {
        let academicYear: Int
        let revision: Int
        let path: String
        let sha256: String
    }
    let schemaVersion: Int
    let calendars: [Entry]

    func validate() throws {
        guard schemaVersion == 1 else { throw CampusCalendarError.unsupportedVersion }
        guard !calendars.isEmpty, Set(calendars.map(\.academicYear)).count == calendars.count,
              calendars.allSatisfy({ (100...999).contains($0.academicYear) && $0.revision > 0 &&
                  $0.path == "years/\($0.academicYear).json" && $0.sha256.count == 64 &&
                  $0.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) }) else {
            throw CampusCalendarError.invalidData
        }
    }
}

nonisolated struct CampusCalendarEvent: Codable, Sendable, Identifiable, Hashable {
    enum Category: String, Codable, Sendable {
        case semester, registration, exam, holiday, deadline, activity, academic, other
    }
    let id: String
    let title: String
    let startDate: String
    let endDate: String
    let category: Category
    let semester: Int
    let note: String?
    let sourceId: String
    let sourcePage: Int
    let sourceText: String

    var start: Date? { CampusCalendarDate.parse(startDate) }
    var end: Date? { CampusCalendarDate.parse(endDate) }
    var isMultiDay: Bool { startDate != endDate }
    func contains(_ date: Date) -> Bool {
        let key = CampusCalendarDate.dayKey(date)
        return startDate <= key && key <= endDate
    }
    var months: [Int] {
        guard let start, let end else { return [] }
        let calendar = CampusCalendarDate.calendar
        var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: start))!
        var result: [Int] = []
        while cursor <= end {
            result.append(calendar.component(.month, from: cursor))
            cursor = calendar.date(byAdding: .month, value: 1, to: cursor)!
        }
        return result
    }
}

nonisolated struct CampusCalendarDocument: Codable, Sendable {
    struct Source: Codable, Sendable {
        let id: String
        let title: String
        let url: String
        let maintainedOn: String
        let pageCount: Int
    }
    struct Semester: Codable, Sendable {
        let number: Int
        let startDate: String
        let endDate: String
        let classesStartDate: String
    }
    struct Week: Codable, Sendable {
        let startDate: String
        let endDate: String
        let semester: Int
        let kind: String
        let number: Int?
        let label: String
        let sourceId: String
        let sourcePage: Int
    }
    let schemaVersion: Int
    let academicYear: Int
    let revision: Int
    let updatedAt: String
    let timeZone: String
    let startDate: String
    let endDate: String
    let sources: [Source]
    let semesters: [Semester]
    let events: [CampusCalendarEvent]
    let weeks: [Week]

    static func decode(_ data: Data, entry: CampusCalendarIndex.Entry) throws -> Self {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == entry.sha256 else { throw CampusCalendarError.invalidData }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1 else { throw CampusCalendarError.unsupportedVersion }
        let first = String(format: "%04d-08-01", entry.academicYear + 1911)
        let last = String(format: "%04d-07-31", entry.academicYear + 1912)
        guard result.academicYear == entry.academicYear, result.revision == entry.revision,
              result.timeZone == "Asia/Taipei", result.startDate == first, result.endDate == last,
              ISO8601DateFormatter().date(from: result.updatedAt) != nil,
              !result.sources.isEmpty,
              Set(result.sources.map(\.id)).count == result.sources.count,
              result.sources.allSatisfy({ CampusCalendarDate.parse($0.maintainedOn) != nil &&
                  URL(string: $0.url)?.scheme == "https" && $0.pageCount > 0 }),
              result.semesters.map(\.number) == [1, 2],
              !result.events.isEmpty, Set(result.events.map(\.id)).count == result.events.count else {
            throw CampusCalendarError.invalidData
        }
        for semester in result.semesters {
            let lower = semester.number == 1 ? first : "\(entry.academicYear + 1912)-02-01"
            let upper = semester.number == 1 ? "\(entry.academicYear + 1912)-01-31" : last
            guard semester.startDate == lower, semester.endDate == upper,
                  CampusCalendarDate.parse(semester.classesStartDate) != nil,
                  lower <= semester.classesStartDate, semester.classesStartDate <= upper else {
                throw CampusCalendarError.invalidData
            }
        }
        for event in result.events {
            guard !event.title.isEmpty, !event.id.isEmpty, !event.sourceText.isEmpty,
                  event.start != nil, event.end != nil, event.startDate <= event.endDate,
                  event.startDate >= first, event.endDate <= last,
                  let semester = result.semesters.first(where: { $0.number == event.semester }),
                  semester.startDate <= event.startDate, event.startDate <= semester.endDate,
                  result.sources.contains(where: { $0.id == event.sourceId && (1...$0.pageCount).contains(event.sourcePage) }) else {
                throw CampusCalendarError.invalidData
            }
        }
        var cursor = first
        for week in result.weeks {
            guard let start = CampusCalendarDate.parse(week.startDate), let end = CampusCalendarDate.parse(week.endDate),
                  week.startDate == cursor, start <= end, week.endDate <= last,
                  CampusCalendarDate.calendar.dateComponents([.day], from: start, to: end).day! <= 6,
                  let semester = result.semesters.first(where: { $0.number == week.semester }),
                  semester.startDate <= week.startDate, week.endDate <= semester.endDate,
                  ["teaching", "preparation", "winter", "summer"].contains(week.kind), !week.label.isEmpty,
                  (week.kind == "preparation" ? week.number == nil : (week.number ?? 0) > 0),
                  result.sources.contains(where: { $0.id == week.sourceId && (1...$0.pageCount).contains(week.sourcePage) }) else {
                throw CampusCalendarError.invalidData
            }
            cursor = CampusCalendarDate.dayKey(CampusCalendarDate.tomorrow(after: end))
        }
        guard cursor == "\(entry.academicYear + 1912)-08-01" else { throw CampusCalendarError.invalidData }
        return result
    }
}

nonisolated enum CampusCalendarError: Error { case invalidData, unsupportedVersion, network }

nonisolated struct CampusCalendarResult: Sendable {
    enum Origin: Sendable { case bundled, cached, remote }
    let year: Int
    let document: CampusCalendarDocument?
    let availableYears: [Int]
    let origin: Origin
    let checkedAt: Date?
    let notice: String?
    let isNotPublished: Bool

    var statusText: String {
        if let notice { return notice }
        guard let document else { return "尚未取得 \(year) 學年度資料" }
        let sourceDate = document.sources.map(\.maintainedOn).max() ?? ""
        let prefix = origin == .bundled ? "內建資料" : "校方更新"
        return "\(prefix) \(sourceDate)"
    }
}

/// Shared source, validation and per-year cache for app and extension. No student data.
actor AcademicCalendarStore {
    static let shared = AcademicCalendarStore()
    static let baseURL = URL(string: "https://raw.githubusercontent.com/qian403/NIU-app/main/calendar-data/")!
    typealias Fetch = @Sendable (URL) async throws -> Data

    private struct StoredIndex: Codable { let data: Data; let checkedAt: Date }
    private struct Snapshot: Codable {
        let entry: CampusCalendarIndex.Entry
        let data: Data
        let checkedAt: Date
    }
    private let directory: URL?
    private let bundleDirectory: URL?
    private let fetch: Fetch
    private let refreshInterval: TimeInterval = 6 * 60 * 60

    init(directory: URL? = nil, bundleDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("AcademicCalendar"),
         fetch: @escaping Fetch = { try await AcademicCalendarStore.fetchURL($0) }) {
        self.directory = directory ?? (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.chien.niuapp") ??
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)?.appendingPathComponent("AcademicCalendar-v1")
        self.bundleDirectory = bundleDirectory
        self.fetch = fetch
    }

    nonisolated private static func fetchURL(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000 else {
            throw CampusCalendarError.network
        }
        return data
    }

    private func index(from data: Data?) -> CampusCalendarIndex? {
        guard let data, let index = try? JSONDecoder().decode(CampusCalendarIndex.self, from: data),
              (try? index.validate()) != nil else { return nil }
        return index
    }
    private func storedIndex() -> StoredIndex? {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let records = files.filter { $0.lastPathComponent.hasPrefix("index-") && $0.pathExtension == "json" }.compactMap { url -> StoredIndex? in
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(StoredIndex.self, from: data), index(from: stored.data) != nil else { return nil }
            return stored
        }.sorted { $0.checkedAt < $1.checkedAt }
        guard let latest = records.last else { return nil }
        let catalogs = records.compactMap { index(from: $0.data) }
        guard let data = try? JSONEncoder().encode(mergedCatalogs(catalogs)) else { return nil }
        return StoredIndex(data: data, checkedAt: latest.checkedAt)
    }
    private func mergedCatalogs(_ catalogs: [CampusCalendarIndex]) -> CampusCalendarIndex {
        var entries: [Int: CampusCalendarIndex.Entry] = [:]
        for catalog in catalogs {
            for entry in catalog.calendars {
                // Published years are append-only; revision never decreases under the feed contract.
                if entries[entry.academicYear].map({ $0.revision >= entry.revision }) != true {
                    entries[entry.academicYear] = entry
                }
            }
        }
        return CampusCalendarIndex(schemaVersion: 1, calendars: entries.values.sorted { $0.academicYear < $1.academicYear })
    }
    private func bundledIndex() -> CampusCalendarIndex? {
        index(from: bundleDirectory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("index.json")) })
    }
    private func cachedSnapshot(year: Int) -> Snapshot? {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.filter { $0.lastPathComponent.hasPrefix("\(year)-") && $0.pathExtension == "json" }.compactMap { url -> Snapshot? in
            guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Snapshot.self, from: data),
                  value.entry.academicYear == year, (try? CampusCalendarDocument.decode(value.data, entry: value.entry)) != nil else { return nil }
            return value
        }.max { a, b in a.entry.revision == b.entry.revision ? a.checkedAt < b.checkedAt : a.entry.revision < b.entry.revision }
    }
    private func bundleSnapshot(year: Int) -> Snapshot? {
        guard let entry = bundledIndex()?.calendars.first(where: { $0.academicYear == year }),
              let bundleDirectory, let data = try? Data(contentsOf: bundleDirectory.appendingPathComponent(entry.path)),
              (try? CampusCalendarDocument.decode(data, entry: entry)) != nil else { return nil }
        return Snapshot(entry: entry, data: data, checkedAt: .distantPast)
    }
    private func localSnapshot(year: Int) -> (Snapshot, CampusCalendarResult.Origin)? {
        let cache = cachedSnapshot(year: year), bundled = bundleSnapshot(year: year)
        if let cache, cache.entry.revision >= (bundled?.entry.revision ?? 0) { return (cache, .cached) }
        return bundled.map { ($0, .bundled) }
    }
    private func knownYears(in catalog: CampusCalendarIndex? = nil, requested: Int) -> [Int] {
        var years = Set(catalog?.calendars.map(\.academicYear) ?? [])
        // A second process may publish a newer catalog while this process awaits the year file.
        years.formUnion(storedIndex().flatMap { index(from: $0.data) }?.calendars.map(\.academicYear) ?? [])
        years.formUnion(bundledIndex()?.calendars.map(\.academicYear) ?? [])
        years.insert(requested)
        return years.sorted(by: >)
    }
    private func result(year: Int, local: (Snapshot, CampusCalendarResult.Origin)?, catalog: CampusCalendarIndex? = nil,
                        notice: String? = nil, isNotPublished: Bool = false) -> CampusCalendarResult {
        CampusCalendarResult(year: year, document: local.flatMap { try? CampusCalendarDocument.decode($0.0.data, entry: $0.0.entry) },
                             availableYears: knownYears(in: catalog, requested: year), origin: local?.1 ?? .cached,
                             checkedAt: local.flatMap { $0.1 == .bundled ? nil : $0.0.checkedAt }, notice: notice, isNotPublished: isNotPublished)
    }
    func cached(year: Int) -> CampusCalendarResult { result(year: year, local: localSnapshot(year: year)) }

    private func persist<T: Encodable>(_ value: T, named name: String) throws {
        guard let directory else { throw CampusCalendarError.invalidData }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func refresh(year: Int, now: Date = Date(), force: Bool = false) async -> CampusCalendarResult {
        do {
            let stored = storedIndex()
            let catalog: CampusCalendarIndex
            let catalogCheckedAt: Date
            var catalogNotice: String?
            if !force, let stored, now >= stored.checkedAt, now.timeIntervalSince(stored.checkedAt) < refreshInterval,
               CampusCalendarDate.academicYear(at: stored.checkedAt) == CampusCalendarDate.academicYear(at: now),
               let saved = index(from: stored.data) {
                catalog = saved
                catalogCheckedAt = stored.checkedAt
            } else {
                let data = try await fetch(Self.baseURL.appendingPathComponent("index.json"))
                try Task.checkCancellation()
                let decoded = try JSONDecoder().decode(CampusCalendarIndex.self, from: data)
                try decoded.validate()
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                // Immutable catalog identities preserve newly discovered years across app/widget races.
                try? persist(StoredIndex(data: data, checkedAt: now), named: "index-\(hash).json")
                let known = storedIndex().flatMap { index(from: $0.data) }
                catalog = mergedCatalogs([known, decoded].compactMap { $0 })
                catalogCheckedAt = now
                if catalog.calendars.first(where: { $0.academicYear == year }) != decoded.calendars.first(where: { $0.academicYear == year }) {
                    catalogNotice = "遠端目錄尚未同步，保留已確認的資料"
                }
            }
            guard let entry = catalog.calendars.first(where: { $0.academicYear == year }) else {
                let local = localSnapshot(year: year)
                return result(year: year, local: local, catalog: catalog,
                              notice: local == nil ? "\(year) 學年度行事曆尚未公布" : "最新目錄未列出此年度，顯示已儲存資料",
                              isNotPublished: local == nil)
            }
            let local = localSnapshot(year: year)
            if let local, local.0.entry.revision > entry.revision {
                return result(year: year, local: local, catalog: catalog, notice: "遠端資料尚未同步，保留較新版本")
            }
            if let local, local.0.entry.revision == entry.revision, local.0.entry.sha256 != entry.sha256 {
                throw CampusCalendarError.invalidData
            }
            let data: Data
            if let local, local.0.entry == entry { data = local.0.data }
            else { data = try await fetch(Self.baseURL.appendingPathComponent(entry.path)) }
            try Task.checkCancellation()
            _ = try CampusCalendarDocument.decode(data, entry: entry)
            // Re-check after the await so a slower response cannot replace a newer download.
            if let newer = localSnapshot(year: year), newer.0.entry.revision > entry.revision {
                return result(year: year, local: newer, catalog: catalog)
            }
            let snapshot = Snapshot(entry: entry, data: data, checkedAt: catalogNotice == nil ? catalogCheckedAt : (local?.0.checkedAt ?? catalogCheckedAt))
            // Revision/hash-specific files are atomic; concurrent app/widget writes cannot downgrade a newer revision.
            do {
                try persist(snapshot, named: "\(year)-\(entry.revision)-\(entry.sha256).json")
                return result(year: year, local: (snapshot, .remote), catalog: catalog, notice: catalogNotice)
            } catch {
                return result(year: year, local: (snapshot, .remote), catalog: catalog, notice: "已更新，暫時無法保存離線資料")
            }
        } catch {
            let local = localSnapshot(year: year)
            let message: String
            if case CampusCalendarError.unsupportedVersion = error { message = "行事曆格式已更新，請更新 App" }
            else { message = local == nil ? "無法取得 \(year) 學年度資料，請連線後重試" : "更新失敗，顯示已儲存資料" }
            return result(year: year, local: local, notice: message)
        }
    }
}
