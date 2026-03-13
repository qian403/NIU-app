import Foundation

// MARK: - Token Response
struct MoodleTokenResponse: Codable {
    let token: String
    let privatetoken: String?
}

struct MoodleTokenError: Codable {
    let error: String?
    let errorcode: String?
}

struct MoodleAutologinResponse: Codable {
    let key: String
    let autologinurl: String?
    let warnings: [MoodleWarning]?
}

struct MoodleWarning: Codable {
    let warningcode: String?
    let message: String?
}

// MARK: - Site Info
struct MoodleSiteInfo: Codable {
    let sitename: String
    let username: String
    let firstname: String
    let lastname: String
    let fullname: String
    let userid: Int
    let usercontextid: Int?
    let siteurl: String
    let userpictureurl: String?
}

// MARK: - Course
struct MoodleCourse: Codable, Identifiable {
    let id: Int
    let shortname: String
    let fullname: String
    let displayname: String
    let enrolledusercount: Int
    let idnumber: String
    let visible: Int
    let summary: String
    let format: String
    let courseimage: String?
    let showgrades: Bool
    let progress: Double?
    let completed: Bool
    let startdate: Int
    let enddate: Int
    let lastaccess: Int?
    let isfavourite: Bool
    let hidden: Bool
    
    /// Extract semester code from idnumber, e.g. "1141" from "1141_B4CS030018A"
    var semesterCode: String {
        let parts = idnumber.split(separator: "_")
        return parts.first.map(String.init) ?? ""
    }
    
    /// Human-readable semester label, e.g. "114-1"
    var semesterLabel: String {
        let code = semesterCode
        guard code.count == 4 else { return code }
        let year = String(code.prefix(3))
        let term = String(code.suffix(1))
        return "\(year)-\(term)"
    }
    
    /// Clean display name without semester prefix
    var cleanName: String {
        // displayname is like "資訊安全導論(1141_B4CS030018A)"
        // Extract just the course name
        if let parenRange = displayname.range(of: "(") {
            return String(displayname[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return displayname
    }
    
    /// Extract teacher name from summary
    var teacherName: String? {
        // summary contains "開課教師： 蘇維宗 助理教授 (suwt@niu.edu.tw);"
        guard let range = summary.range(of: "開課教師：") ?? summary.range(of: "開課教師:") else { return nil }
        let after = summary[range.upperBound...]
        let cleaned = after.trimmingCharacters(in: .whitespaces)
        if let semicolonIdx = cleaned.firstIndex(of: ";") {
            let teacherPart = String(cleaned[..<semicolonIdx]).trimmingCharacters(in: .whitespaces)
            // Remove email part: "蘇維宗 助理教授 (suwt@niu.edu.tw)"
            if let emailStart = teacherPart.range(of: "(") {
                return String(teacherPart[..<emailStart.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return teacherPart
        }
        return nil
    }
    
    /// Extract credits from summary
    var credits: String? {
        guard let range = summary.range(of: "學分數：") ?? summary.range(of: "學分數:") else { return nil }
        let after = summary[range.upperBound...]
        if let semicolonIdx = after.firstIndex(of: ";") {
            return String(after[..<semicolonIdx]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    
    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startdate))
    }
    
    var endDate: Date {
        Date(timeIntervalSince1970: TimeInterval(enddate))
    }
    
    var lastAccessDate: Date? {
        guard let ts = lastaccess else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }
}


// MARK: - Course Content (Sections)
struct MoodleCourseSection: Codable, Identifiable {
    let id: Int
    let name: String
    let visible: Int?
    let summary: String
    let modules: [MoodleModule]
}

struct MoodleModule: Codable, Identifiable {
    let id: Int
    let name: String
    let instance: Int?
    let modname: String  // "forum", "assign", "resource", "url", "page", "folder", etc.
    let modplural: String?
    let url: String?
    let visible: Int?
    let description: String?
    let contents: [MoodleContent]?
    
    var iconName: String {
        switch modname {
        case "forum": return "bubble.left.and.bubble.right"
        case "assign": return "doc.text"
        case "resource": return "doc.fill"
        case "url": return "link"
        case "page": return "doc.richtext"
        case "folder": return "folder"
        case "quiz": return "questionmark.circle"
        case "label": return "tag"
        case "feedback": return "star.bubble"
        case "choice": return "checklist"
        case "attendance": return "person.text.rectangle"
        case "bigbluebuttonbn": return "video"
        case "h5pactivity": return "play.rectangle"
        default: return "square"
        }
    }
}

struct MoodleContent: Codable {
    let type: String?       // "file", "url"
    let filename: String?
    let filepath: String?
    let filesize: Int?
    let fileurl: String?
    let timecreated: Int?
    let timemodified: Int?
    let mimetype: String?
}

// MARK: - Page
struct MoodlePagesResponse: Codable {
    let pages: [MoodlePage]
}

struct MoodlePage: Codable, Identifiable {
    let id: Int
    let coursemodule: Int?
    let name: String
    let intro: String?
    let content: String?

    var plainContent: String {
        (content ?? intro ?? "")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Attendance
struct MoodleAttendanceUserSessionsResponse: Decodable {
    let sessions: [MoodleAttendanceSession]
    let statuses: [MoodleAttendanceStatus]

    private enum CodingKeys: String, CodingKey {
        case sessions
        case statuses
        case statusses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([MoodleAttendanceSession].self, forKey: .sessions) ?? []
        if let parsed = try container.decodeIfPresent([MoodleAttendanceStatus].self, forKey: .statuses) {
            statuses = parsed
        } else if let legacyParsed = try container.decodeIfPresent([MoodleAttendanceStatus].self, forKey: .statusses) {
            statuses = legacyParsed
        } else {
            statuses = []
        }
    }
}

struct MoodleAttendanceSession: Codable, Identifiable {
    let id: Int
    let sessdate: Int
    let description: String?
    let statusid: Int?
    let remarks: String?
}

struct MoodleAttendanceStatus: Codable {
    let id: Int
    let acronym: String?
    let description: String?
    let grade: Double?
}

struct MoodleAttendanceHTMLResult {
    let records: [MoodleAttendanceHTMLRecord]
    let total: Int
    let presentCount: Int
    let absentCount: Int
    let percentageText: String?
}

struct MoodleAttendanceHTMLRecord: Identifiable {
    let id: Int
    let date: Date
    let timeText: String
    let description: String?
    let statusLabel: String
    let scoreText: String?
    let remarks: String?
    let isPresent: Bool
}

// MARK: - Forum
struct MoodleForum: Codable, Identifiable {
    let id: Int
    let course: Int
    let name: String
    let type: String       // "news", "general", etc.
    let intro: String
}

struct MoodleDiscussion: Codable, Identifiable {
    let id: Int
    let name: String
    let subject: String
    let message: String
    let timemodified: Int
    let userfullname: String
    let created: Int
    let numreplies: Int?
    let pinned: Bool?
    
    var timeModifiedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(timemodified))
    }
    
    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(created))
    }
    
    /// Strip HTML tags for preview
    var plainMessage: String {
        message.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MoodleDiscussionsResponse: Codable {
    let discussions: [MoodleDiscussion]
}

struct MoodlePost: Codable, Identifiable {
    let id: Int
    let subject: String
    let message: String
    let author: MoodlePostAuthor?
    let timecreated: Int
    
    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(timecreated))
    }
    
    var plainMessage: String {
        message.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MoodlePostAuthor: Codable {
    let id: Int?
    let fullname: String?
}

struct MoodlePostsResponse: Codable {
    let posts: [MoodlePost]
}

// MARK: - Assignments
struct MoodleAssignmentsResponse: Codable {
    let courses: [MoodleAssignmentCourse]
}

struct MoodleAssignmentCourse: Codable {
    let id: Int
    let assignments: [MoodleAssignment]
}

struct MoodleAssignment: Codable, Identifiable {
    let id: Int
    let cmid: Int
    let course: Int
    let name: String
    let intro: String
    let duedate: Int
    let allowsubmissionsfromdate: Int
    let grade: Double?
    let timemodified: Int
    
    var dueDateValue: Date? {
        duedate == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(duedate))
    }
    
    var isOverdue: Bool {
        guard let due = dueDateValue else { return false }
        return Date() > due
    }
    
    var plainIntro: String {
        intro.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MoodleSubmissionStatus: Codable {
    let lastattempt: MoodleLastAttempt?
}

struct MoodleLastAttempt: Codable {
    let submission: MoodleSubmission?
    let graded: Bool?
}

struct MoodleSubmission: Codable {
    let id: Int?
    let status: String?  // "new", "submitted", "draft"
    let timemodified: Int?
    let plugins: [MoodleSubmissionPlugin]?

    var submittedFiles: [MoodleSubmissionFile] {
        guard let plugins else { return [] }
        return plugins
            .flatMap { $0.fileareas ?? [] }
            .flatMap { $0.files ?? [] }
    }
}

struct MoodleSubmissionPlugin: Codable {
    let type: String?
    let name: String?
    let fileareas: [MoodleSubmissionFileArea]?
}

struct MoodleSubmissionFileArea: Codable {
    let area: String?
    let files: [MoodleSubmissionFile]?
}

struct MoodleSubmissionFile: Codable, Identifiable {
    let filename: String
    let fileurl: String?
    let filesize: Int?
    let timemodified: Int?

    var id: String { "\(filename)-\(fileurl ?? "")" }
}

struct MoodleUploadedFile: Codable {
    let itemid: Int
    let filename: String?
}

struct MoodleDraftItemResponse: Codable {
    let itemid: Int
}

// MARK: - Grades
struct MoodleGradesTableResponse: Codable {
    let tables: [MoodleGradeTable]
}

struct MoodleGradeTable: Codable {
    let courseid: Int
}

struct MoodleGradeItemsResponse: Codable {
    let usergrades: [MoodleUserGrade]
}

struct MoodleUserGrade: Codable {
    let courseid: Int
    let gradeitems: [MoodleGradeItem]
}

struct MoodleGradeItem: Codable, Identifiable {
    let id: Int
    let itemname: String?
    let itemtype: String?       // "course", "mod", "manual", "category"
    let itemmodule: String?     // "assign", "quiz", "forum", etc.
    let graderaw: Double?
    let gradeformatted: String?
    let grademin: Double?
    let grademax: Double?
    let percentageformatted: String?
    let feedback: String?
    let weightformatted: String?
    let contributiontocoursetotal: String?
    let rangeformatted: String?
    
    var isCategory: Bool {
        itemtype == "course" || itemtype == "category"
    }
    
    var cleanFeedback: String? {
        guard let fb = feedback, !fb.isEmpty else { return nil }
        return fb.htmlDecoded
    }
}

// MARK: - HTML Decode Helper
extension String {
    var htmlDecoded: String {
        var result = self
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&ndash;", "–"),
            ("&mdash;", "—"),
            ("&nbsp;", " "),
            ("&#160;", " "),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // Strip remaining HTML tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
