import Foundation

/// Search only cached visible text; never interpret HTML on each keystroke.
nonisolated enum MoodleSearch {
    static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(query: String, fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { word in
            fields.contains { $0.localizedStandardContains(String(word)) }
        }
    }

    static func plainText(_ html: String) -> String {
        // Preserve block boundaries, but allow words split by inline emphasis.
        var text = html.replacingOccurrences(
            of: "(?is)<!--.*?-->|<(script|style)\\b[^>]*>.*?</\\1\\s*>",
            with: "", options: .regularExpression
        ).replacingOccurrences(
            of: "(?i)</?(?:p|div|br|li|ul|ol|tr|td|th|h[1-6]|section|blockquote)\\b[^>]*>",
            with: " ", options: .regularExpression
        ).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode only after removing markup so escaped <text> stays visible.
        let entities = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
                        "apos": "'", "ndash": "–", "mdash": "—", "hellip": "…",
                        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©"]
        let pattern = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
        let matches = pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text),
                  let entityRange = Range(match.range(at: 1), in: text) else { continue }
            let entity = String(text[entityRange])
            let decoded: String?
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                decoded = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10)
                    .flatMap(UnicodeScalar.init).map(String.init)
            } else {
                decoded = entities[entity]
            }
            if let decoded { text.replaceSubrange(range, with: decoded) }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Built on data replacement, reused for filtering and result counts.
nonisolated struct MoodleSearchIndex {
    private var fields: [Int: [String]] = [:]

    init<T: Identifiable>(_ items: [T], fields: (T) -> [String]) where T.ID == Int {
        for item in items { self.fields[item.id] = fields(item) }
    }

    init() {}

    func filter<T: Identifiable>(_ items: [T], query: String) -> [T] where T.ID == Int {
        guard !MoodleSearch.trimmed(query).isEmpty else { return items }
        return items.filter { MoodleSearch.matches(query: query, fields: fields[$0.id] ?? []) }
    }
}

struct MoodleResourceSearchIndex {
    private let titles: MoodleSearchIndex
    private let modules: [Int: MoodleSearchIndex]

    init(_ sections: [MoodleCourseSection] = []) {
        titles = MoodleSearchIndex(sections) { [MoodleSearch.plainText($0.name)] }
        modules = sections.reduce(into: [:]) { result, section in
            result[section.id] = MoodleSearchIndex(section.modules) { [MoodleSearch.plainText($0.name)] }
        }
    }

    func filter(_ sections: [MoodleCourseSection], query: String) -> [MoodleCourseSection] {
        guard !MoodleSearch.trimmed(query).isEmpty else { return sections }
        let matchingSections = Set(titles.filter(sections, query: query).map(\.id))
        return sections.compactMap { section in
            if matchingSections.contains(section.id) { return section }
            let matches = modules[section.id]?.filter(section.modules, query: query) ?? []
            guard !matches.isEmpty else { return nil }
            return MoodleCourseSection(id: section.id, name: section.name, visible: section.visible,
                                       summary: section.summary, modules: matches)
        }
    }
}

/// Coalesce overlapping consumers (overview/search/detail). Cancel transport only
/// when its last consumer leaves, or an explicit refresh replaces the request.
@MainActor
final class MoodleCourseLoadCoordinator {
    enum Phase { case content, completeAnnouncements }
    private struct Request {
        let id: UUID
        let phase: Phase
        let key: String
        let task: Task<Void, Never>
        var consumers: Set<UUID>
    }
    private var request: Request?

    func run(force: Bool, key: String = "", phase: Phase = .content, operation: @escaping @MainActor () async -> Void) async {
        guard !Task.isCancelled else { return }
        let consumer = UUID()
        if force || (request != nil && request?.key != key) {
            request?.task.cancel()
            request = nil
        }
        if request == nil {
            request = Request(id: UUID(), phase: phase, key: key, task: Task {
                guard !Task.isCancelled else { return }
                await operation()
            }, consumers: [])
        }
        guard let current = request else { return }
        request?.consumers.insert(consumer)
        defer { release(consumer, requestID: current.id) }
        await withTaskCancellationHandler {
            await current.task.value
            // A completed request must not swallow a follow-up operation (for
            // example, announcement pagination after its shared preview).
            if request?.id == current.id { request = nil }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release(consumer, requestID: current.id)
            }
        }
        // Waiting on a preview is not equivalent to completing pagination.
        // Resume the requested phase even if a refresh replaced its predecessor.
        if !Task.isCancelled,
           current.phase != phase || (!force && current.task.isCancelled && request?.key == key && request?.id != current.id) {
            await run(force: false, key: key, phase: phase, operation: operation)
        }
    }

    private func release(_ consumer: UUID, requestID: UUID) {
        guard request?.id == requestID else { return }
        request?.consumers.remove(consumer)
        if request?.consumers.isEmpty == true {
            request?.task.cancel()
            request = nil
        }
    }
}
