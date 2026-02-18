import Foundation

@MainActor
final class MoodleService {
    static let shared = MoodleService()
    
    private let baseURL = "https://euni.niu.edu.tw"
    private var token: String?
    private var privateToken: String?
    private var userId: Int?
    
    private init() {}
    
    // MARK: - Token Management
    
    var isAuthenticated: Bool {
        token != nil && userId != nil
    }
    
    /// Expose token for file URL rewriting (webservice/pluginfile.php)
    var currentToken: String? {
        token
    }
    
    func authenticate(username: String, password: String) async throws {
        let urlString = "\(baseURL)/login/token.php?username=\(username.urlEncoded)&password=\(password.urlEncoded)&service=moodle_mobile_app"
        guard let url = URL(string: urlString) else {
            throw MoodleError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // Check for error first
        if let errorResp = try? JSONDecoder().decode(MoodleTokenError.self, from: data),
           let error = errorResp.error, !error.isEmpty {
            throw MoodleError.authFailed(error)
        }
        
        let tokenResp = try JSONDecoder().decode(MoodleTokenResponse.self, from: data)
        self.token = tokenResp.token
        self.privateToken = tokenResp.privatetoken
        
        // Get user ID from site info
        let siteInfo = try await fetchSiteInfo()
        self.userId = siteInfo.userid
    }
    
    func logout() {
        token = nil
        privateToken = nil
        userId = nil
    }
    
    // MARK: - API Calls
    
    func fetchSiteInfo() async throws -> MoodleSiteInfo {
        try await callAPI(function: "core_webservice_get_site_info")
    }
    
    func fetchCourses() async throws -> [MoodleCourse] {
        guard let userId = userId else { throw MoodleError.notAuthenticated }
        return try await callAPI(
            function: "core_enrol_get_users_courses",
            params: ["userid": "\(userId)"]
        )
    }
    
    func fetchCourseContents(courseId: Int) async throws -> [MoodleCourseSection] {
        try await callAPI(
            function: "core_course_get_contents",
            params: ["courseid": "\(courseId)"]
        )
    }
    
    func fetchForumsByCourse(courseId: Int) async throws -> [MoodleForum] {
        try await callAPI(
            function: "mod_forum_get_forums_by_courses",
            params: ["courseids[0]": "\(courseId)"]
        )
    }
    
    func fetchForumDiscussions(forumId: Int) async throws -> MoodleDiscussionsResponse {
        try await callAPI(
            function: "mod_forum_get_forum_discussions",
            params: [
                "forumid": "\(forumId)",
                "sortorder": "3",  // newest first
                "perpage": "20"
            ]
        )
    }
    
    func fetchDiscussionPosts(discussionId: Int) async throws -> MoodlePostsResponse {
        try await callAPI(
            function: "mod_forum_get_discussion_posts",
            params: ["discussionid": "\(discussionId)"]
        )
    }
    
    func fetchAssignments(courseId: Int) async throws -> [MoodleAssignment] {
        let response: MoodleAssignmentsResponse = try await callAPI(
            function: "mod_assign_get_assignments",
            params: ["courseids[0]": "\(courseId)"]
        )
        return response.courses.first?.assignments ?? []
    }
    
    func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        try await callAPI(
            function: "mod_assign_get_submission_status",
            params: ["assignid": "\(assignId)"]
        )
    }
    
    func fetchGradeItems(courseId: Int) async throws -> [MoodleGradeItem] {
        guard let userId = userId else { throw MoodleError.notAuthenticated }
        let resp: MoodleGradeItemsResponse = try await callAPI(
            function: "gradereport_user_get_grade_items",
            params: [
                "courseid": "\(courseId)",
                "userid": "\(userId)"
            ]
        )
        return resp.usergrades.first?.gradeitems ?? []
    }

    func fetchAttendanceUserSessions(attendanceId: Int) async throws -> MoodleAttendanceUserSessionsResponse {
        guard let userId = userId else { throw MoodleError.notAuthenticated }
        return try await callAPI(
            function: "mod_attendance_get_user_sessions",
            params: [
                "attendanceid": "\(attendanceId)",
                "userid": "\(userId)"
            ]
        )
    }

    /// Resolve attendance instance id from a course module id (cmid).
    /// Useful when module list points to `/mod/attendance/view.php?id=CMID` via URL modules.
    func resolveAttendanceInstanceId(courseModuleId: Int) async throws -> Int? {
        guard let raw = try await callAPIRaw(
            function: "core_course_get_course_module",
            params: ["cmid": "\(courseModuleId)"]
        ) as? [String: Any],
              let cm = raw["cm"] as? [String: Any] else {
            return nil
        }

        let modName = (cm["modname"] as? String)?.lowercased()
        guard modName == "attendance" else { return nil }
        return intValue(cm["instance"])
    }

    func fetchPages(courseId: Int) async throws -> [MoodlePage] {
        let resp: MoodlePagesResponse = try await callAPI(
            function: "mod_page_get_pages_by_courses",
            params: ["courseids[0]": "\(courseId)"]
        )
        return resp.pages
    }

    func fetchUnusedDraftItemId() async throws -> Int {
        if let value: Int = try? await callAPI(function: "core_files_get_unused_draft_itemid") {
            return value
        }
        if let value: String = try? await callAPI(function: "core_files_get_unused_draft_itemid"),
           let intVal = Int(value) {
            return intVal
        }
        if let value: MoodleDraftItemResponse = try? await callAPI(function: "core_files_get_unused_draft_itemid") {
            return value.itemid
        }
        let raw = try await callAPIRaw(function: "core_files_get_unused_draft_itemid")
        if let dict = raw as? [String: Any], let itemid = intValue(dict["itemid"]) {
            return itemid
        }
        if let itemid = intValue(raw) {
            return itemid
        }
        throw MoodleError.decodeFailed("無法解析 draft item id")
    }

    func uploadAssignmentFile(localFileURL: URL, draftItemId: Int) async throws -> MoodleUploadedFile {
        guard let token else { throw MoodleError.notAuthenticated }
        guard let uploadURL = URL(string: "\(baseURL)/webservice/upload.php") else {
            throw MoodleError.invalidURL
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let filename = localFileURL.lastPathComponent
        let mimeType = mimeTypeForFileExtension(localFileURL.pathExtension)
        let fileData = try Data(contentsOf: localFileURL)

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("token", token)
        appendField("itemid", "\(draftItemId)")
        appendField("filepath", "/")
        appendField("filearea", "draft")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file_1\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MoodleError.serverError
        }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let arr = json as? [[String: Any]], let first = arr.first {
                if let itemid = intValue(first["itemid"]) {
                    return MoodleUploadedFile(itemid: itemid, filename: first["filename"] as? String)
                }
            }
            if let dict = json as? [String: Any] {
                if let exception = dict["exception"] as? String {
                    let message = dict["message"] as? String ?? exception
                    throw MoodleError.apiError(message)
                }
                if let itemid = intValue(dict["itemid"]) {
                    return MoodleUploadedFile(itemid: itemid, filename: dict["filename"] as? String)
                }
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            throw MoodleError.apiError("上傳失敗：\(text)")
        }
        throw MoodleError.decodeFailed("無法解析上傳回應")
    }

    func saveAssignmentSubmission(assignId: Int, draftItemId: Int) async throws {
        _ = try await callAPIRaw(
            function: "mod_assign_save_submission",
            params: [
                "assignmentid": "\(assignId)",
                "plugindata[files_filemanager]": "\(draftItemId)"
            ]
        )
    }

    func clearAssignmentSubmission(assignId: Int) async throws {
        let emptyDraftId = try await fetchUnusedDraftItemId()
        try await saveAssignmentSubmission(assignId: assignId, draftItemId: emptyDraftId)
    }

    func submitAssignmentForGrading(assignId: Int, acceptSubmissionStatement: Bool) async throws {
        _ = try await callAPIRaw(
            function: "mod_assign_submit_for_grading",
            params: [
                "assignmentid": "\(assignId)",
                "acceptsubmissionstatement": acceptSubmissionStatement ? "1" : "0"
            ]
        )
    }
    
    /// Build a file download URL with token appended
    func fileURL(for rawURL: String) -> URL? {
        guard let token = token else { return nil }
        let separator = rawURL.contains("?") ? "&" : "?"
        return URL(string: "\(rawURL)\(separator)token=\(token)")
    }
    
    /// Get an auto-login URL that will authenticate and redirect to the target page.
    /// Uses Moodle's `tool_mobile_get_autologin_key` to get a one-time key.
    func autologinURL(for targetURL: String) async throws -> URL {
        guard let privateKey = privateToken else {
            // Fallback: just return the original URL
            guard let url = URL(string: targetURL) else { throw MoodleError.invalidURL }
            return url
        }
        
        let response: MoodleAutologinResponse = try await callAPI(
            function: "tool_mobile_get_autologin_key",
            params: ["privatetoken": privateKey]
        )
        
        let key = response.key
        let autologinURLStr = "\(baseURL)/admin/tool/mobile/autologin.php?userid=\(userId ?? 0)&key=\(key)&urltogo=\(targetURL.urlEncoded)"
        guard let url = URL(string: autologinURLStr) else { throw MoodleError.invalidURL }
        return url
    }
    
    // MARK: - Generic API Call
    
    private func callAPI<T: Decodable>(
        function: String,
        params: [String: String] = [:]
    ) async throws -> T {
        guard let token = token else { throw MoodleError.notAuthenticated }
        
        var components = URLComponents(string: "\(baseURL)/webservice/rest/server.php")!
        var queryItems = [
            URLQueryItem(name: "wstoken", value: token),
            URLQueryItem(name: "wsfunction", value: function),
            URLQueryItem(name: "moodlewsrestformat", value: "json")
        ]
        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems
        
        guard let url = components.url else { throw MoodleError.invalidURL }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MoodleError.serverError
        }
        
        // Check for Moodle error response
        if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let exception = errorDict["exception"] as? String {
            let message = errorDict["message"] as? String ?? exception
            throw MoodleError.apiError(message)
        }
        
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[Moodle] Decode error for \(function): \(error)")
            throw MoodleError.decodeFailed(error.localizedDescription)
        }
    }

    private func callAPIRaw(
        function: String,
        params: [String: String] = [:]
    ) async throws -> Any? {
        guard let token = token else { throw MoodleError.notAuthenticated }

        var components = URLComponents(string: "\(baseURL)/webservice/rest/server.php")!
        var queryItems = [
            URLQueryItem(name: "wstoken", value: token),
            URLQueryItem(name: "wsfunction", value: function),
            URLQueryItem(name: "moodlewsrestformat", value: "json")
        ]
        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw MoodleError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MoodleError.serverError
        }

        let jsonObj = try? JSONSerialization.jsonObject(with: data)
        if let errorDict = jsonObj as? [String: Any],
           let exception = errorDict["exception"] as? String {
            let message = errorDict["message"] as? String ?? exception
            throw MoodleError.apiError(message)
        }
        return jsonObj
    }

    private func mimeTypeForFileExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "zip": return "application/zip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: return "application/octet-stream"
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let strVal = value as? String { return Int(strVal) }
        if let numVal = value as? NSNumber { return numVal.intValue }
        return nil
    }
}

// MARK: - Error Types

enum MoodleError: LocalizedError {
    case invalidURL
    case notAuthenticated
    case authFailed(String)
    case serverError
    case apiError(String)
    case decodeFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "無效的 URL"
        case .notAuthenticated: return "尚未登入 Moodle"
        case .authFailed(let msg): return "Moodle 登入失敗：\(msg)"
        case .serverError: return "伺服器錯誤"
        case .apiError(let msg): return "API 錯誤：\(msg)"
        case .decodeFailed(let msg): return "資料解析失敗：\(msg)"
        }
    }
}

// MARK: - String Extension

private extension String {
    nonisolated var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
