import Foundation

enum MoodleQuestionActivityKind: String, CaseIterable {
    case quiz, irs, choice, feedback, questionnaire, survey

    var title: String {
        switch self {
        case .quiz: "測驗"
        case .irs: "即時問答"
        case .choice: "選擇"
        case .feedback: "回饋"
        case .questionnaire: "問卷"
        case .survey: "調查"
        }
    }

    static func matches(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "euni.niu.edu.tw",
              url.port == nil || url.port == 443 else { return false }
        return allCases.contains { url.path == "/mod/\($0.rawValue)/view.php" }
    }
}

extension MoodleModule {
    var questionActivityKind: MoodleQuestionActivityKind? {
        MoodleQuestionActivityKind(rawValue: modname.lowercased())
    }

    var questionActivityURL: URL? {
        guard let kind = questionActivityKind, id > 0,
              visible != 0, uservisible != false else { return nil }
        // Missing URLs may also represent activities restricted by Moodle.
        guard (availabilityinfo ?? "").isEmpty || uservisible == true else { return nil }
        // The course module ID identifies view.php; instance is the activity's
        // internal ID. A canonical entry also avoids replaying attempt URLs.
        return URL(string: "https://euni.niu.edu.tw/mod/\(kind.rawValue)/view.php?id=\(id)")
    }
}

struct MoodleQuestionSection: Identifiable {
    let id: Int
    let name: String
    let modules: [MoodleModule]

    static func sections(from contents: [MoodleCourseSection]) -> [Self] {
        var seen = Set<Int>()
        return contents.compactMap { section in
            guard section.visible != 0 else { return nil }
            let modules = section.modules.filter {
                $0.visible != 0 && $0.questionActivityKind != nil && seen.insert($0.id).inserted
            }
            guard !modules.isEmpty else { return nil }
            return Self(id: section.id, name: section.name, modules: modules)
        }
    }
}
