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
        let text = html.replacingOccurrences(
            of: "(?is)<!--.*?-->|<(script|style)\\b[^>]*>.*?</\\1\\s*>",
            with: "", options: .regularExpression
        ).replacingOccurrences(
            of: "(?i)</?(?:p|div|br|li|ul|ol|tr|td|th|h[1-6]|section|blockquote)\\b[^>]*>",
            with: " ", options: .regularExpression
        ).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode only after removing markup so escaped <text> stays visible.
        return decodeEntities(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func decodeEntities(_ html: String) -> String {
        let entities = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
                        "apos": "'", "ndash": "–", "mdash": "—", "hellip": "…",
                        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©",
                        "sup1": "¹", "sup2": "²", "sup3": "³", "deg": "°", "plusmn": "±",
                        "times": "×", "divide": "÷", "minus": "−", "middot": "·", "micro": "µ",
                        "le": "≤", "ge": "≥", "ne": "≠"]
        var text = html
        let pattern = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z0-9]+);")
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
        return text
    }
}

/// Moodle rich text reduced to readable runs. Superscript and subscript survive,
/// so x<sup>2</sup> does not turn into x2.
nonisolated enum MoodleRichText {
    enum Position: Equatable { case normal, superscript, `subscript` }

    struct Run: Equatable {
        var text: String
        var position: Position
    }

    private static let blockTags: Set<String> = [
        "p", "div", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "blockquote", "pre",
    ]

    static func runs(_ html: String) -> [Run] {
        let source = html.replacingOccurrences(
            of: "(?is)<!--.*?-->|<(script|style)\\b[^>]*>.*?</\\1\\s*>",
            with: "", options: .regularExpression
        )
        let tag = try? NSRegularExpression(pattern: "<(/?)([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*>")
        let matches = tag?.matches(in: source, range: NSRange(source.startIndex..., in: source)) ?? []
        var runs: [Run] = []
        var superscriptDepth = 0
        var subscriptDepth = 0

        func append(_ text: String, _ position: Position) {
            guard !text.isEmpty else { return }
            if runs.last?.position == position {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, position: position))
            }
        }
        func appendText(_ raw: Substring) {
            // Collapse source whitespace first; decoded &nbsp; and escaped <text> stay visible.
            let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let position: Position = superscriptDepth > 0 ? .superscript
                : subscriptDepth > 0 ? .subscript : .normal
            append(MoodleSearch.decodeEntities(collapsed), position)
        }

        var cursor = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source),
                  let nameRange = Range(match.range(at: 2), in: source) else { continue }
            appendText(source[cursor..<range.lowerBound])
            cursor = range.upperBound
            let closing = match.range(at: 1).length > 0
            switch source[nameRange].lowercased() {
            case "sup": superscriptDepth = max(0, superscriptDepth + (closing ? -1 : 1))
            case "sub": subscriptDepth = max(0, subscriptDepth + (closing ? -1 : 1))
            case "br": append("\n", .normal)
            case "li": if !closing { append("\n• ", .normal) }
            case "td", "th": if closing { append(" ", .normal) }
            case let name where blockTags.contains(name): append("\n", .normal)
            default: break
            }
        }
        appendText(source[cursor...])
        return normalized(runs)
    }

    /// Unicode superscript/subscript form, or nil when any character has none.
    static func scripted(_ text: String, _ position: Position) -> String? {
        let map: [Character: Character]
        switch position {
        case .normal: return text
        case .superscript: map = superscripts
        case .subscript: map = subscripts
        }
        var result = ""
        for character in text {
            guard let mapped = map[character] else { return nil }
            result.append(mapped)
        }
        return result
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", " ": " ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ",
        "h": "ₕ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "p": "ₚ", "s": "ₛ", "t": "ₜ", " ": " ",
    ]

    private static func normalized(_ runs: [Run]) -> [Run] {
        var result = runs.map { run -> Run in
            guard run.position == .normal else { return run }
            let text = run.text
                .replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            return Run(text: text, position: run.position)
        }
        while let first = result.first {
            let trimmed = String(first.text.drop(while: \.isWhitespace))
            if trimmed.isEmpty { result.removeFirst(); continue }
            result[0].text = trimmed
            break
        }
        while let last = result.last {
            var text = last.text
            while text.last?.isWhitespace == true { text.removeLast() }
            if text.isEmpty { result.removeLast(); continue }
            result[result.count - 1].text = text
            break
        }
        return result
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
