import Foundation
import WebKit

final class MoodleService {
    static let shared = MoodleService()
    
    private let baseURL = "https://euni.niu.edu.tw"
    private var token: String?
    private var privateToken: String?
    private var userId: Int?
    private var userContextId: Int?
    private var popupNotificationCache: [MoodlePopupNotification] = []
    private var popupNotificationCacheAt: Date?
    private let popupNotificationCacheTTL: TimeInterval = 3600
    
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
        self.userContextId = siteInfo.usercontextid
    }
    
    func logout() {
        token = nil
        privateToken = nil
        userId = nil
        userContextId = nil
        popupNotificationCache = []
        popupNotificationCacheAt = nil
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

    func fetchAttendanceFromHTML(attendanceId: Int? = nil, courseModuleId: Int? = nil) async throws -> MoodleAttendanceHTMLResult {
        guard attendanceId != nil || courseModuleId != nil else {
            throw MoodleError.invalidURL
        }

        guard let targetURL = buildAttendanceViewURL(attendanceId: attendanceId, courseModuleId: courseModuleId) else {
            throw MoodleError.invalidURL
        }

        await syncWebKitCookiesToSharedStorage()
        await establishEUNISessionViaSSO()

        // Prefer Moodle mobile autologin first for attendance pages.
        // This is the most reliable way to ensure we land on a real Moodle page
        // instead of an expired web session that redirects to login.
        if let autoURL = try? await autologinURL(for: targetURL.absoluteString),
           let autoPage = try? await loadEUNIHTMLPage(url: autoURL, allowSilentRefresh: false),
           !looksLikeLoginPage(html: autoPage.html, finalURL: autoPage.finalURL) {
            return try await resolveBestAttendanceResult(from: autoPage, fallbackURL: targetURL)
        }

        // Fast path fallback: if current shared cookies are still valid, direct load is enough.
        if let directPage = try? await loadEUNIHTMLPage(url: targetURL, allowSilentRefresh: false),
           !looksLikeLoginPage(html: directPage.html, finalURL: directPage.finalURL) {
            return try await resolveBestAttendanceResult(from: directPage, fallbackURL: targetURL)
        }

        // Retry autologin once more after establishing web session, in case token/cookies just synced.
        if let autoURL = try? await autologinURL(for: targetURL.absoluteString),
           let autoPage = try? await loadEUNIHTMLPage(url: autoURL, allowSilentRefresh: true),
           !looksLikeLoginPage(html: autoPage.html, finalURL: autoPage.finalURL) {
            return try await resolveBestAttendanceResult(from: autoPage, fallbackURL: targetURL)
        }

        // Last fallback: allow silent refresh when session has definitely expired.
        let page = try await loadEUNIHTMLPage(url: targetURL, allowSilentRefresh: true)
        return try await resolveBestAttendanceResult(from: page, fallbackURL: targetURL)
    }

    private func resolveBestAttendanceResult(
        from firstPage: (html: String, finalURL: URL?),
        fallbackURL: URL
    ) async throws -> MoodleAttendanceHTMLResult {
        var bestResult = parseAttendanceHTML(firstPage.html)
        let baseURL = firstPage.finalURL ?? fallbackURL
        let candidateURLs = attendanceAllSessionsCandidates(from: firstPage.html, baseURL: baseURL)

        // Keep extra probing bounded for performance, but cover known full-data variants.
        for url in candidateURLs.prefix(4) {
            guard let altPage = try? await loadEUNIHTMLPage(url: url, allowSilentRefresh: false),
                  !looksLikeLoginPage(html: altPage.html, finalURL: altPage.finalURL) else {
                continue
            }

            let altResult = parseAttendanceHTML(altPage.html)
            if isAttendanceResult(altResult, betterThan: bestResult) {
                bestResult = altResult
            }
        }

        return bestResult
    }

    private func isAttendanceResult(_ lhs: MoodleAttendanceHTMLResult, betterThan rhs: MoodleAttendanceHTMLResult) -> Bool {
        if lhs.records.count != rhs.records.count {
            return lhs.records.count > rhs.records.count
        }
        if lhs.total != rhs.total {
            return lhs.total > rhs.total
        }
        let lhsEarliest = lhs.records.map(\.date).min() ?? .distantFuture
        let rhsEarliest = rhs.records.map(\.date).min() ?? .distantFuture
        return lhsEarliest < rhsEarliest
    }

    private func attendanceAllSessionsCandidates(from html: String, baseURL: URL) -> [URL] {
        var urls: [URL] = []

        // 1) Extract explicit links whose label suggests "all sessions".
        let anchorRegex = try? NSRegularExpression(
            pattern: "<a[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        )
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = anchorRegex?.matches(in: html, options: [], range: range) ?? []
        let keywordRegex = try? NSRegularExpression(
            pattern: "過去全部|全部|所有課程|所有|all\\s*courses?|all",
            options: [.caseInsensitive]
        )

        for match in matches where match.numberOfRanges >= 3 {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let href = String(html[hrefRange]).htmlDecoded
            let text = sanitizeAttendanceText(String(html[textRange])) ?? ""
            let textNSRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let hasKeyword = keywordRegex?.firstMatch(in: text, options: [], range: textNSRange) != nil
            guard hasKeyword, href.contains("/mod/attendance/view.php") else { continue }
            if let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                urls.append(resolved)
            }
        }

        // 2) Heuristic fallback: try known filter parameters on current URL.
        if let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) {
            var queryItems = components.queryItems ?? []
            let existingNames = Set(queryItems.map { $0.name.lowercased() })

            func appendingQueryItems(_ appended: [URLQueryItem]) {
                var c = components
                var merged = queryItems
                let existing = Set(merged.map { $0.name.lowercased() })
                for item in appended where !existing.contains(item.name.lowercased()) {
                    merged.append(item)
                }
                c.queryItems = merged
                if let u = c.url { urls.append(u) }
            }

            // Prefer same-course attendance views; do not prioritize mode=2 because it can
            // switch into cross-course summaries instead of the course attendance table.
            appendingQueryItems([URLQueryItem(name: "view", value: "4")])
            appendingQueryItems([URLQueryItem(name: "view", value: "5")])
            appendingQueryItems([URLQueryItem(name: "sesscourses", value: "all")])
            appendingQueryItems([
                URLQueryItem(name: "sesscourses", value: "all"),
                URLQueryItem(name: "view", value: "4")
            ])
            appendingQueryItems([
                URLQueryItem(name: "sesscourses", value: "all"),
                URLQueryItem(name: "view", value: "5")
            ])

            if !existingNames.contains("view") {
                appendingQueryItems([URLQueryItem(name: "view", value: "all")])
            }
            if !existingNames.contains("perpage") {
                appendingQueryItems([URLQueryItem(name: "perpage", value: "500")])
            }
            if !existingNames.contains("status") {
                appendingQueryItems([URLQueryItem(name: "status", value: "all")])
            }
            if !existingNames.contains("showall") {
                appendingQueryItems([URLQueryItem(name: "showall", value: "1")])
            }

            queryItems.removeAll(keepingCapacity: true)
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
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

    func fetchPopupNotifications(limit: Int = 30, offset: Int = 0, forceRefresh: Bool = false) async throws -> [MoodlePopupNotification] {
        let normalizedLimit = max(1, min(limit, 100))
        let normalizedOffset = max(0, offset)

        if !forceRefresh,
           let cacheAt = popupNotificationCacheAt,
           Date().timeIntervalSince(cacheAt) < popupNotificationCacheTTL {
            return Array(popupNotificationCache.prefix(normalizedLimit))
        }

        let params = [
            "limit": "\(normalizedLimit)",
            "offset": "\(normalizedOffset)"
        ]

        if let fromCoreMessage = try? await fetchNotificationsViaCoreMessage(limit: normalizedLimit),
           !fromCoreMessage.isEmpty {
            popupNotificationCache = fromCoreMessage
            popupNotificationCacheAt = Date()
            return Array(fromCoreMessage.prefix(normalizedLimit))
        }

        let candidates = [
            "message_popup_get_popup_notifications",
            "core_message_get_popup_notifications"
        ]

        var lastError: Error?
        for functionName in candidates {
            do {
                let raw = try await callAPIRaw(function: functionName, params: params)
                let parsed = parsePopupNotifications(raw)
                if !parsed.isEmpty {
                    popupNotificationCache = parsed
                    popupNotificationCacheAt = Date()
                    return Array(parsed.prefix(normalizedLimit))
                }
            } catch {
                lastError = error
            }
        }

        do {
            let crawled = try await fetchPopupNotificationsViaCrawler(limit: normalizedLimit)
            popupNotificationCache = crawled
            popupNotificationCacheAt = Date()
            return Array(crawled.prefix(normalizedLimit))
        } catch {
            if let lastError, isNoRecordError(lastError) {
                popupNotificationCache = []
                popupNotificationCacheAt = Date()
                return []
            }
            lastError = lastError ?? error
        }

        throw lastError ?? MoodleError.serverError
    }

    private func fetchNotificationsViaCoreMessage(limit: Int) async throws -> [MoodlePopupNotification] {
        guard let userId else { throw MoodleError.notAuthenticated }

        let notificationsParams = [
            "useridto": "\(userId)",
            "useridfrom": "0",
            "type": "notifications",
            "newestfirst": "1",
            "limitfrom": "0",
            "limitnum": "\(limit)"
        ]

        let rawNotifications = try await callAPIRaw(function: "core_message_get_messages", params: notificationsParams)
        let parsedNotifications = parsePopupNotifications(rawNotifications)
        if !parsedNotifications.isEmpty {
            return parsedNotifications
        }

        let bothParams = [
            "useridto": "\(userId)",
            "useridfrom": "0",
            "type": "both",
            "newestfirst": "1",
            "limitfrom": "0",
            "limitnum": "\(limit)"
        ]
        let rawBoth = try await callAPIRaw(function: "core_message_get_messages", params: bothParams)
        return parsePopupNotifications(rawBoth)
    }

    func fetchUnusedDraftItemId() async throws -> Int {
        if let value: Int = try? await callAPI(function: "core_files_get_unused_draft_itemid", logDecodeError: false) {
            return value
        }
        if let value: String = try? await callAPI(function: "core_files_get_unused_draft_itemid", logDecodeError: false),
           let intVal = Int(value) {
            return intVal
        }
        if let value: MoodleDraftItemResponse = try? await callAPI(function: "core_files_get_unused_draft_itemid", logDecodeError: false) {
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

    func uploadAssignmentFile(
        localFileURL: URL,
        draftItemId: Int,
        assignmentCMID: Int? = nil,
        assignmentCourseID: Int? = nil
    ) async throws -> MoodleUploadedFile {
        guard let token else { throw MoodleError.notAuthenticated }
        var components = URLComponents(string: "\(baseURL)/webservice/upload.php")
        components?.queryItems = [
            URLQueryItem(name: "token", value: token)
        ]
        guard let uploadURL = components?.url else {
            throw MoodleError.invalidURL
        }

        let originalFilename = localFileURL.lastPathComponent
        let filename = multipartSafeFilename(from: originalFilename, pathExtension: localFileURL.pathExtension)
        let mimeType = mimeTypeForFileExtension(localFileURL.pathExtension)
        let fileData = try Data(contentsOf: localFileURL)
        guard !fileData.isEmpty else {
            throw MoodleError.apiError("選取的檔案內容為空，請重新選擇檔案")
        }

        func performUpload(fileFieldName: String) async throws -> MoodleUploadedFile? {
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            var body = Data()
            func appendField(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }

            appendField("token", token)
            appendField("itemid", "\(draftItemId)")
            appendField("component", "user")
            appendField("filepath", "/")
            appendField("filearea", "draft")
            appendField("author", "NIU APP")
            appendField("license", "allrightsreserved")
            appendField("repo_upload_file", "1")
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body

            #if DEBUG
            print("[MoodleUpload] field=\(fileFieldName) filename=\(filename) bytes=\(fileData.count) draft=\(draftItemId)")
            #endif

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw MoodleError.serverError
            }

            if let json = try? JSONSerialization.jsonObject(with: data) {
                if let arr = json as? [Any], arr.isEmpty {
                    return nil
                }
                if let arr = json as? [[String: Any]], let first = arr.first,
                   let itemid = intValue(first["itemid"]) {
                    return MoodleUploadedFile(itemid: itemid, filename: first["filename"] as? String)
                }
                if let dict = json as? [String: Any] {
                    if let exception = dict["exception"] as? String {
                        let message = dict["message"] as? String ?? exception
                        throw MoodleError.apiError(message)
                    }
                    if let errorCode = dict["errorcode"] as? String,
                       let errorMessage = dict["error"] as? String {
                        throw MoodleError.apiError("\(errorMessage) (\(errorCode))")
                    }
                    if let errorMessage = dict["error"] as? String {
                        throw MoodleError.apiError(errorMessage)
                    }
                    if let itemid = intValue(dict["itemid"]) {
                        return MoodleUploadedFile(itemid: itemid, filename: dict["filename"] as? String)
                    }
                }
            }

            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                throw MoodleError.apiError("上傳失敗：\(text)")
            }
            return nil
        }

        var failureReasons: [String] = []

        do {
            if let uploaded = try await performUpload(fileFieldName: "file_1") {
                return uploaded
            }
            failureReasons.append("upload.php(file_1): empty response")
        } catch {
            failureReasons.append("upload.php(file_1): \(error.localizedDescription)")
        }

        do {
            if let uploaded = try await performUpload(fileFieldName: "file") {
                return uploaded
            }
            failureReasons.append("upload.php(file): empty response")
        } catch {
            failureReasons.append("upload.php(file): \(error.localizedDescription)")
        }

        do {
            let uploaded = try await uploadAssignmentFileViaCoreFiles(
                filename: filename,
                fileData: fileData,
                draftItemId: draftItemId
            )
            return uploaded
        } catch {
            failureReasons.append("core_files_upload: \(error.localizedDescription)")
        }

        if let cmid = assignmentCMID {
            do {
                let uploaded = try await uploadAssignmentFileViaRepositoryCrawler(
                    filename: filename,
                    fileData: fileData,
                    draftItemId: draftItemId,
                    assignmentCMID: cmid,
                    assignmentCourseID: assignmentCourseID
                )
                return uploaded
            } catch {
                failureReasons.append("repository_ajax: \(error.localizedDescription)")
            }
        } else {
            failureReasons.append("repository_ajax: 缺少 assignment CMID")
        }

        #if DEBUG
        print("[MoodleUpload] All fallbacks failed: \(failureReasons.joined(separator: " | "))")
        #endif
        throw MoodleError.apiError(
            "伺服器未接收檔案內容（upload.php/core_files_upload/repository_ajax 皆失敗）\n" +
            failureReasons.joined(separator: "\n")
        )
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

    func uploadAssignmentSubmissionFile(
        assignId: Int,
        assignmentCMID: Int,
        assignmentCourseID: Int?,
        localFileURL: URL
    ) async throws -> MoodleUploadedFile {
        let draftItemId = try await fetchUnusedDraftItemId()
        let uploaded = try await uploadAssignmentFile(
            localFileURL: localFileURL,
            draftItemId: draftItemId,
            assignmentCMID: assignmentCMID,
            assignmentCourseID: assignmentCourseID
        )
        let effectiveDraftItemId = uploaded.itemid > 0 ? uploaded.itemid : draftItemId
        try await saveAssignmentSubmission(assignId: assignId, draftItemId: effectiveDraftItemId)
        return uploaded
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
        
        let response: MoodleAutologinResponse = try await callAutologinKey(privateToken: privateKey)
        
        let key = response.key
        let autologinURLStr = "\(baseURL)/admin/tool/mobile/autologin.php?userid=\(userId ?? 0)&key=\(key)&urltogo=\(targetURL.urlEncoded)"
        guard let url = URL(string: autologinURLStr) else { throw MoodleError.invalidURL }
        return url
    }
    
    // MARK: - Generic API Call
    
    private func callAPI<T: Decodable>(
        function: String,
        params: [String: String] = [:],
        logDecodeError: Bool = true
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
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyMoodleMobileHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        
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
            if logDecodeError {
                print("[Moodle] Decode error for \(function): \(error)")
            }
            throw MoodleError.decodeFailed(error.localizedDescription)
        }
    }

    private func callAutologinKey(privateToken: String) async throws -> MoodleAutologinResponse {
        guard let token else { throw MoodleError.notAuthenticated }

        var components = URLComponents(string: "\(baseURL)/webservice/rest/server.php")!
        components.queryItems = [
            URLQueryItem(name: "wstoken", value: token),
            URLQueryItem(name: "wsfunction", value: "tool_mobile_get_autologin_key"),
            URLQueryItem(name: "moodlewsrestformat", value: "json")
        ]
        guard let url = components.url else { throw MoodleError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyMoodleMobileHeaders(to: &request)
        request.httpBody = "privatetoken=\(privateToken.urlEncoded)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw MoodleError.serverError
        }

        if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let exception = errorDict["exception"] as? String {
            let message = errorDict["message"] as? String ?? exception
            throw MoodleError.apiError(message)
        }

        do {
            return try JSONDecoder().decode(MoodleAutologinResponse.self, from: data)
        } catch {
            print("[Moodle] Decode error for tool_mobile_get_autologin_key(POST): \(error)")
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyMoodleMobileHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
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

    private func callAPIRawPOST(
        function: String,
        params: [String: String] = [:]
    ) async throws -> Any? {
        guard let token = token else { throw MoodleError.notAuthenticated }

        var components = URLComponents(string: "\(baseURL)/webservice/rest/server.php")!
        components.queryItems = [
            URLQueryItem(name: "wstoken", value: token),
            URLQueryItem(name: "wsfunction", value: function),
            URLQueryItem(name: "moodlewsrestformat", value: "json")
        ]
        guard let url = components.url else { throw MoodleError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        applyMoodleMobileHeaders(to: &request)
        let form = params
            .map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }
            .joined(separator: "&")
        request.httpBody = form.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
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

    private func multipartSafeFilename(from original: String, pathExtension ext: String) -> String {
        let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let filteredBase = base
            .unicodeScalars
            .filter { $0.isASCII && allowed.contains($0) }
            .map(String.init)
            .joined()
        let safeBase = filteredBase.isEmpty ? "upload_\(Int(Date().timeIntervalSince1970))" : filteredBase
        let cleanExt = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanExt.isEmpty {
            return safeBase
        }
        return "\(safeBase).\(cleanExt)"
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let strVal = value as? String { return Int(strVal) }
        if let numVal = value as? NSNumber { return numVal.intValue }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let boolVal = value as? Bool { return boolVal }
        if let intVal = intValue(value) { return intVal != 0 }
        if let strVal = value as? String {
            let normalized = strVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "y"].contains(normalized) { return true }
            if ["0", "false", "no", "n"].contains(normalized) { return false }
        }
        return nil
    }

    private func parsePopupNotifications(_ raw: Any?) -> [MoodlePopupNotification] {
        let dictArray: [[String: Any]]

        if let array = raw as? [[String: Any]] {
            dictArray = array
        } else if let dict = raw as? [String: Any] {
            if let notifications = dict["notifications"] as? [[String: Any]] {
                dictArray = notifications
            } else if let messages = dict["messages"] as? [[String: Any]] {
                dictArray = messages
            } else if let single = dict["notification"] as? [String: Any] {
                dictArray = [single]
            } else {
                dictArray = []
            }
        } else {
            dictArray = []
        }

        let parsed = dictArray.enumerated().map { index, item in
            mapPopupNotification(item, fallbackID: index + 1_000_000)
        }

        return parsed.sorted { lhs, rhs in
            let left = lhs.timeCreated ?? .distantPast
            let right = rhs.timeCreated ?? .distantPast
            return left > right
        }
    }

    private func mapPopupNotification(_ dict: [String: Any], fallbackID: Int) -> MoodlePopupNotification {
        let id = intValue(dict["id"]) ?? intValue(dict["notificationid"]) ?? fallbackID

        let subject = (dict["shortenedsubject"] as? String)
            ?? (dict["subject"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["title"] as? String)
            ?? (dict["contexturlname"] as? String)
            ?? ""

        let message = (dict["fullmessagehtml"] as? String)
            ?? (dict["smallmessage"] as? String)
            ?? (dict["text"] as? String)
            ?? (dict["fullmessage"] as? String)
            ?? (dict["message"] as? String)
            ?? ""

        let rawTimeCreatedTS = intValue(dict["timecreated"]) ?? intValue(dict["timecreatedus"])
        let normalizedTS = rawTimeCreatedTS.map { $0 > 4_000_000_000 ? ($0 / 1000) : $0 }
        let timeCreated = normalizedTS.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        let timeCreatedPretty = (dict["timecreatedpretty"] as? String)
            ?? (dict["timesent"] as? String)

        let contextURL = (dict["contexturl"] as? String)
            ?? (dict["url"] as? String)

        let timeread = intValue(dict["timeread"]) ?? 0
        let isRead = boolValue(dict["read"])
            ?? boolValue(dict["isread"])
            ?? (timeread > 0)

        return MoodlePopupNotification(
            id: id,
            subject: subject,
            message: message,
            timeCreated: timeCreated,
            timeCreatedPretty: timeCreatedPretty,
            contextURL: contextURL,
            component: dict["component"] as? String,
            isRead: isRead
        )
    }

    private func fetchPopupNotificationsViaCrawler(limit: Int) async throws -> [MoodlePopupNotification] {
        guard let targetURL = URL(string: "\(baseURL)/message/output/popup/notifications.php") else {
            throw MoodleError.invalidURL
        }

        await syncWebKitCookiesToSharedStorage()
        await establishEUNISessionViaSSO()

        if let autoURL = try? await autologinURL(for: targetURL.absoluteString),
           let page = try? await loadEUNIHTMLPage(url: autoURL, allowSilentRefresh: true) {
            let parsed = parsePopupNotificationsFromHTML(page.html, baseURL: page.finalURL ?? targetURL)
            return Array(parsed.prefix(limit))
        }

        let page = try await loadEUNIHTMLPage(url: targetURL, allowSilentRefresh: true)
        let parsed = parsePopupNotificationsFromHTML(page.html, baseURL: page.finalURL ?? targetURL)
        return Array(parsed.prefix(limit))
    }

    private func parsePopupNotificationsFromHTML(_ html: String, baseURL: URL) -> [MoodlePopupNotification] {
        var parsed: [MoodlePopupNotification] = []

        let anchorRegex = try? NSRegularExpression(
            pattern: "<a[^>]*href=\"([^\"]*(?:notificationid=\\d+|messageid=\\d+)[^\"]*)\"[^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        )
        if let anchorRegex {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = anchorRegex.matches(in: html, options: [], range: range)
            for (index, match) in matches.enumerated() where match.numberOfRanges >= 3 {
                guard let hrefRange = Range(match.range(at: 1), in: html),
                      let innerRange = Range(match.range(at: 2), in: html) else {
                    continue
                }
                let href = String(html[hrefRange])
                let inner = String(html[innerRange])

                let idText = extractFirstMatch(in: href, patterns: [
                    "notificationid=(\\d+)",
                    "messageid=(\\d+)"
                ])
                let id = Int(idText ?? "") ?? (2_000_000 + index)

                let title = sanitizeNotificationText(extractFirstMatch(in: inner, patterns: [
                    "<(?:div|span)[^>]*class=\"[^\"]*(?:subject|title|notification)[^\"]*\"[^>]*>([\\s\\S]*?)</(?:div|span)>",
                    "<strong[^>]*>([\\s\\S]*?)</strong>",
                    "<h[1-6][^>]*>([\\s\\S]*?)</h[1-6]>"
                ])) ?? sanitizeNotificationText(inner) ?? "M 園區通知"

                let timeText = sanitizeNotificationText(extractFirstMatch(in: inner, patterns: [
                    "<(?:div|span)[^>]*class=\"[^\"]*time[^\"]*\"[^>]*>([\\s\\S]*?)</(?:div|span)>",
                    "<time[^>]*>([\\s\\S]*?)</time>"
                ]))

                let preview = sanitizeNotificationText(extractFirstMatch(in: inner, patterns: [
                    "<(?:div|span)[^>]*class=\"[^\"]*(?:preview|excerpt|summary|message)[^\"]*\"[^>]*>([\\s\\S]*?)</(?:div|span)>",
                    "<p[^>]*>([\\s\\S]*?)</p>"
                ]))

                let contextURL = resolveNotificationURL(href, baseURL: baseURL)
                let lower = inner.lowercased()
                let isRead = !(lower.contains("unread") || lower.contains("is-unread") || lower.contains("notification-unread"))

                parsed.append(
                    MoodlePopupNotification(
                        id: id,
                        subject: title,
                        message: preview ?? title,
                        timeCreated: nil,
                        timeCreatedPretty: timeText,
                        contextURL: contextURL,
                        component: "message_popup",
                        isRead: isRead
                    )
                )
            }
        }

        if parsed.isEmpty {
            let blocks = notificationItemBlocks(from: html)
            parsed = blocks.enumerated().compactMap { index, block in
                let idText = extractFirstMatch(in: block, patterns: [
                    "data-notificationid=\"(\\d+)\"",
                    "data-id=\"(\\d+)\"",
                    "id=\"notification-(\\d+)\"",
                    "notificationid=(\\d+)"
                ])
                let id = Int(idText ?? "") ?? (2_000_000 + index)
                let title = sanitizeNotificationText(extractFirstMatch(in: block, patterns: [
                    "<h[1-6][^>]*>([\\s\\S]*?)</h[1-6]>",
                    "<strong[^>]*>([\\s\\S]*?)</strong>",
                    "data-region=\"subject\"[^>]*>([\\s\\S]*?)</"
                ])) ?? "M 園區通知"
                let body = sanitizeNotificationText(extractFirstMatch(in: block, patterns: [
                    "data-region=\"notification-content\"[^>]*>([\\s\\S]*?)</",
                    "class=\"[^\"]*(?:content-item-body|notification-message|message)[^\"]*\"[^>]*>([\\s\\S]*?)</",
                    "<p[^>]*>([\\s\\S]*?)</p>"
                ])) ?? title
                let lower = block.lowercased()
                let isRead = !(lower.contains("unread") || lower.contains("is-unread") || lower.contains("notification-unread"))

                guard !(title == "M 園區通知" && body == "M 園區通知") else { return nil }

                return MoodlePopupNotification(
                    id: id,
                    subject: title,
                    message: body,
                    timeCreated: nil,
                    timeCreatedPretty: nil,
                    contextURL: nil,
                    component: "message_popup",
                    isRead: isRead
                )
            }
        }

        if let detail = sanitizeNotificationText(extractFirstMatch(in: html, patterns: [
            "<div[^>]*class=\"[^\"]*(?:message|notification)[^\"]*(?:content|detail|full)[^\"]*\"[^>]*>([\\s\\S]*?)</div>",
            "<article[^>]*>([\\s\\S]*?)</article>"
        ])),
           !detail.isEmpty,
           !parsed.isEmpty {
            let first = parsed[0]
            parsed[0] = MoodlePopupNotification(
                id: first.id,
                subject: first.subject,
                message: detail,
                timeCreated: first.timeCreated,
                timeCreatedPretty: first.timeCreatedPretty,
                contextURL: first.contextURL,
                component: first.component,
                isRead: first.isRead
            )
        }

        var seen = Set<String>()
        parsed = parsed.filter { item in
            let key = "\(item.id)-\(item.subject)-\(item.timeCreatedPretty ?? "")"
            return seen.insert(key).inserted
        }

        return parsed.sorted { lhs, rhs in
            let left = lhs.timeCreated ?? .distantPast
            let right = rhs.timeCreated ?? .distantPast
            return left > right
        }
    }

    private func notificationItemBlocks(from html: String) -> [String] {
        let patterns = [
            "<(?:li|div)[^>]*(?:data-region=\\\"notification\\\"|data-notificationid|class=\\\"[^\\\"]*notification[^\\\"]*\\\")[^>]*>([\\s\\S]*?)</(?:li|div)>",
            "<(?:li|div)[^>]*(?:class=\\\"[^\\\"]*message[^\\\"]*\\\"|data-region=\\\"message\\\")[^>]*>([\\s\\S]*?)</(?:li|div)>"
        ]

        var blocks: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            blocks.append(contentsOf: captureGroups(in: html, regex: regex))
        }

        var seen = Set<String>()
        return blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 }
            .filter { seen.insert($0).inserted }
    }

    private func sanitizeNotificationText(_ raw: String?) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: [.caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.htmlDecoded
        text = text.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolveNotificationURL(_ rawURL: String?, baseURL: URL) -> String? {
        guard let rawURL else { return nil }
        let cleaned = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return URL(string: cleaned, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private func isNoRecordError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("找不到資料紀錄")
            || text.contains("找不到資料记录")
            || text.contains("cannot find data record")
    }

    private func applyMoodleMobileHeaders(to request: inout URLRequest) {
        // Some NIU Moodle endpoints only allow requests that look like official mobile app traffic.
        request.setValue(
            "MoodleMobile/4.5.0 (iPhone; iOS 17.0; Scale/3.00)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    }

    private func ensureUserContextId() async throws -> Int {
        if let userContextId { return userContextId }

        if let siteInfo = try? await fetchSiteInfo(), let context = siteInfo.usercontextid {
            userContextId = context
            return context
        }

        // Fallback: resolve from user files page via existing SSO/EUNI session (avoid autologin rate limit).
        await establishEUNISessionViaSSO()
        guard let target = URL(string: "\(baseURL)/user/files.php") else {
            throw MoodleError.invalidURL
        }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        applyMoodleMobileHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MoodleError.serverError
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        if let contextText = extractFirstMatch(in: html, patterns: [
            "name=\"ctx_id\"\\s+value=\"(\\d+)\"",
            "contextid=(\\d+)",
            "\"contextid\"\\s*:\\s*(\\d+)"
        ]), let context = Int(contextText) {
            userContextId = context
            return context
        }

        throw MoodleError.apiError("無法取得使用者 context id")
    }

    private func resolveModuleContextId(cmid: Int, courseId: Int?) async -> Int? {
        if let raw = try? await callAPIRaw(
            function: "core_course_get_course_module",
            params: ["cmid": "\(cmid)"]
        ) as? [String: Any],
        let cm = raw["cm"] as? [String: Any] {
            if let contextId = intValue(cm["contextid"]) {
                return contextId
            }
            if let context = cm["context"] as? [String: Any],
               let contextId = intValue(context["id"]) {
                return contextId
            }
        }

        guard let courseId else { return nil }
        guard let rawSections = try? await callAPIRaw(
            function: "core_course_get_contents",
            params: ["courseid": "\(courseId)"]
        ) as? [[String: Any]] else {
            return nil
        }
        for section in rawSections {
            guard let modules = section["modules"] as? [[String: Any]] else { continue }
            for module in modules {
                guard intValue(module["id"]) == cmid else { continue }
                if let contextId = intValue(module["contextid"]) {
                    return contextId
                }
            }
        }
        return nil
    }

    private func extractNumericMatches(in text: String, patterns: [String]) -> [Int] {
        var result: [Int] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches where match.numberOfRanges > 1 {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                if let val = Int(String(text[r])) {
                    result.append(val)
                }
            }
        }
        return result
    }

    private func extractHiddenInputValue(in html: String, name: String) -> String? {
        extractFirstMatch(in: html, patterns: [
            "<input[^>]*name=\"\(NSRegularExpression.escapedPattern(for: name))\"[^>]*value=\"([^\"]*)\"",
            "<input[^>]*value=\"([^\"]*)\"[^>]*name=\"\(NSRegularExpression.escapedPattern(for: name))\""
        ])
    }

    private func establishEUNISessionViaSSO() async {
        guard let euniURL = SSOEUNISettings.shared.euniFullURL,
              let url = URL(string: euniURL) else { return }
        await syncWebKitCookiesToSharedStorage()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyMoodleMobileHeaders(to: &req)
        req.timeoutInterval = 20
        _ = try? await URLSession.shared.data(for: req)
    }

    private func syncWebKitCookiesToSharedStorage() async {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        guard !cookies.isEmpty else { return }
        let storage = HTTPCookieStorage.shared
        for cookie in cookies {
            storage.setCookie(cookie)
        }
    }

    private func buildAttendanceViewURL(attendanceId: Int?, courseModuleId: Int?) -> URL? {
        if let cmid = courseModuleId {
            return URL(string: "\(baseURL)/mod/attendance/view.php?id=\(cmid)")
        }
        if let attendanceId {
            return URL(string: "\(baseURL)/mod/attendance/view.php?id=\(attendanceId)")
        }
        return nil
    }

    private func loadEUNIHTMLPage(url: URL, allowSilentRefresh: Bool) async throws -> (html: String, finalURL: URL?) {
        func loadHTML(_ url: URL) async throws -> (html: String, finalURL: URL?) {
            await syncWebKitCookiesToSharedStorage()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 12
            applyMoodleMobileHeaders(to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw MoodleError.serverError
            }
            return (String(data: data, encoding: .utf8) ?? "", http.url)
        }

        var page = try await loadHTML(url)
        guard allowSilentRefresh else { return page }

        if looksLikeLoginPage(html: page.html, finalURL: page.finalURL) {
            let refreshed = await SSOSessionService.shared.requestRefresh()
            if refreshed {
                await establishEUNISessionViaSSO()
                page = try await loadHTML(url)
            }
        }

        // If it is still a login page after refresh attempts, treat as a real auth failure.
        if looksLikeLoginPage(html: page.html, finalURL: page.finalURL) {
            throw MoodleError.notAuthenticated
        }

        return page
    }

    private func looksLikeLoginPage(html: String, finalURL: URL?) -> Bool {
        let url = finalURL?.absoluteString.lowercased() ?? ""
        if url.contains("/login/index.php") || url.contains("/sso/default.aspx") {
            return true
        }
        let lower = html.lowercased()
        if lower.contains("name=\"username\"") && lower.contains("name=\"password\"") {
            return true
        }
        if lower.contains("id=\"login\"") && lower.contains("login/index.php") {
            return true
        }
        return false
    }

    private func parseAttendanceHTML(_ html: String) -> MoodleAttendanceHTMLResult {
        let tableRegex = try? NSRegularExpression(
            pattern: "(<table[^>]*>[\\s\\S]*?</table>)",
            options: [.caseInsensitive]
        )
        let allTables = captureGroups(in: html, regex: tableRegex)

        let candidateTables = allTables.filter { table in
            let lower = table.lowercased()
            guard !lower.contains("class=\"attlist") else { return false }
            let hasHeaderSet = ["日期", "描述", "狀態", "分數", "備註"].allSatisfy { table.contains($0) }
            return hasHeaderSet || lower.contains("datecol") || lower.contains("statuscol")
        }

        let parseTargets = candidateTables.isEmpty ? [html] : candidateTables
        var parsedCandidates = parseTargets.map { parseAttendanceRecords(from: $0) }
        parsedCandidates.append(parseAttendanceRecords(from: html))

        let records = parsedCandidates.max(by: { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            let lhsEarliest = lhs.map(\.date).min() ?? .distantFuture
            let rhsEarliest = rhs.map(\.date).min() ?? .distantFuture
            return lhsEarliest > rhsEarliest
        }) ?? []

        let statsRowsRegex = try? NSRegularExpression(
            pattern: "<table[^>]*class=\"[^\"]*attlist[^\"]*\"[^>]*>[\\s\\S]*?</table>",
            options: [.caseInsensitive]
        )
        let statsTable = firstMatch(in: html, regex: statsRowsRegex)
        let totalText = extractStatValue(from: statsTable, keyContains: "已記錄的上課時段")
        let percentText = extractStatValue(from: statsTable, keyContains: "出席次數百分比")
        let parsedTotal = Int((totalText ?? "").replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression))
        let total = parsedTotal ?? records.count
        let presentCount = records.filter { $0.isPresent }.count
        let absentCount = max(total - presentCount, 0)

        return MoodleAttendanceHTMLResult(
            records: records,
            total: total,
            presentCount: presentCount,
            absentCount: absentCount,
            percentageText: percentText
        )
    }

    private func parseAttendanceRecords(from tableHTML: String) -> [MoodleAttendanceHTMLRecord] {
        let rowRegex = try? NSRegularExpression(
            pattern: "<tr[^>]*>([\\s\\S]*?)</tr>",
            options: [.caseInsensitive]
        )
        let rows = captureGroups(in: tableHTML, regex: rowRegex)

        var records: [MoodleAttendanceHTMLRecord] = []
        var runningId = 1

        for row in rows {
            let lowerRow = row.lowercased()
            guard lowerRow.contains("<td") else { continue }

            let cells = extractTableCells(row)
            let dateCell = extractTableCell(row, classHint: "datecol")
            let descCell = extractTableCell(row, classHint: "desccol")
            let statusCell = extractTableCell(row, classHint: "statuscol")
            let pointsCell = extractTableCell(row, classHint: "pointscol")
            let remarksCell = extractTableCell(row, classHint: "remarkscol")

            let mergedDateCell = !dateCell.isEmpty ? dateCell : (cells.indices.contains(0) ? cells[0] : "")
            let mergedDescCell = !descCell.isEmpty ? descCell : (cells.indices.contains(1) ? cells[1] : "")
            let mergedStatusCell = !statusCell.isEmpty ? statusCell : (cells.indices.contains(2) ? cells[2] : "")
            let mergedPointsCell = !pointsCell.isEmpty ? pointsCell : (cells.indices.contains(3) ? cells[3] : "")
            let mergedRemarksCell = !remarksCell.isEmpty ? remarksCell : (cells.indices.contains(4) ? cells[4] : "")

            let dateTime = parseAttendanceDateTime(raw: mergedDateCell)
            let statusLabel = sanitizeAttendanceText(mergedStatusCell) ?? "未簽到"
            let scoreText = sanitizeAttendanceText(mergedPointsCell)
            let description = sanitizeAttendanceText(mergedDescCell)
            let remarks = sanitizeAttendanceText(mergedRemarksCell)

            let hasDate = dateTime.date.timeIntervalSince1970 > 0
            let hasMeaningfulStatus = !statusLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasDate || !hasMeaningfulStatus {
                continue
            }

            let isPresent = inferAttendancePresence(from: statusLabel)

            records.append(
                MoodleAttendanceHTMLRecord(
                    id: runningId,
                    date: dateTime.date,
                    timeText: dateTime.timeText,
                    description: description,
                    statusLabel: statusLabel,
                    scoreText: scoreText,
                    remarks: remarks,
                    isPresent: isPresent
                )
            )
            runningId += 1
        }

        return records
    }

    private func extractTableCell(_ rowHTML: String, classHint: String) -> String {
        let pattern = "<td[^>]*class=\"[^\"]*\(NSRegularExpression.escapedPattern(for: classHint))[^\"]*\"[^>]*>([\\s\\S]*?)</td>"
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        if let raw = firstCapturedValue(in: rowHTML, regex: regex) {
            return raw
        }

        return ""
    }

    private func extractTableCells(_ rowHTML: String) -> [String] {
        let regex = try? NSRegularExpression(
            pattern: "<td[^>]*>([\\s\\S]*?)</td>",
            options: [.caseInsensitive]
        )
        return captureGroups(in: rowHTML, regex: regex)
    }

    private func extractStatValue(from tableHTML: String?, keyContains: String) -> String? {
        guard let tableHTML else { return nil }
        let rowRegex = try? NSRegularExpression(pattern: "<tr[^>]*>([\\s\\S]*?)</tr>", options: [.caseInsensitive])
        let rows = captureGroups(in: tableHTML, regex: rowRegex)

        for row in rows {
            let cellsRegex = try? NSRegularExpression(pattern: "<td[^>]*>([\\s\\S]*?)</td>", options: [.caseInsensitive])
            let cells = captureGroups(in: row, regex: cellsRegex)
            guard cells.count >= 2 else { continue }

            let key = sanitizeAttendanceText(cells[0]) ?? ""
            if key.contains(keyContains) {
                return sanitizeAttendanceText(cells[1])
            }
        }

        return nil
    }

    private func parseAttendanceDateTime(raw: String) -> (date: Date, timeText: String) {
        let plain = sanitizeAttendanceText(raw) ?? ""
        let normalized = plain
            .replacingOccurrences(of: "[\u{00A0}\u{2000}-\u{200B}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let datePattern = "(\\d{4})年\\s*(\\d{1,2})月\\s*(\\d{1,2})日"
        let regex = try? NSRegularExpression(pattern: datePattern)

        if let regex,
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)),
           match.numberOfRanges >= 4,
           let yRange = Range(match.range(at: 1), in: normalized),
           let mRange = Range(match.range(at: 2), in: normalized),
           let dRange = Range(match.range(at: 3), in: normalized),
           let y = Int(normalized[yRange]), let m = Int(normalized[mRange]), let d = Int(normalized[dRange]) {
            var comp = DateComponents()
            comp.calendar = Calendar(identifier: .gregorian)
            comp.year = y
            comp.month = m
            comp.day = d
            let date = comp.date ?? Date(timeIntervalSince1970: 0)

            let timeText = normalized.replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\(週.\\)", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return (date, timeText)
        }

        return (Date(timeIntervalSince1970: 0), normalized)
    }

    private func inferAttendancePresence(from statusLabel: String) -> Bool {
        let s = statusLabel.lowercased()
        if s.contains("出席") || s == "p" { return true }
        if s.contains("未到") || s.contains("缺席") || s.contains("曠課") || s == "a" { return false }
        if s.contains("遲到") || s.contains("late") || s == "l" { return true }
        if s.contains("請假") || s.contains("leave") || s == "e" { return true }
        return false
    }

    private func sanitizeAttendanceText(_ raw: String?) -> String? {
        guard var text = raw, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: [.caseInsensitive])
        text = text.replacingOccurrences(of: "</nobr>", with: " ", options: [.caseInsensitive])
        text = text.replacingOccurrences(of: "<nobr[^>]*>", with: "", options: [.caseInsensitive, .regularExpression])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.htmlDecoded
        text = text.replacingOccurrences(of: "\\n{2,}", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func firstMatch(in text: String, regex: NSRegularExpression?) -> String? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range, in: text) else {
            return nil
        }
        return String(text[r])
    }

    private func captureGroups(in text: String, regex: NSRegularExpression?) -> [String] {
        guard let regex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[r])
        }
    }

    private func firstCapturedValue(in text: String, regex: NSRegularExpression?) -> String? {
        captureGroups(in: text, regex: regex).first
    }

    private func uploadAssignmentFileViaCoreFiles(
        filename: String,
        fileData: Data,
        draftItemId: Int
    ) async throws -> MoodleUploadedFile {
        let contextId = try await ensureUserContextId()

        let raw = try await callAPIRawPOST(
            function: "core_files_upload",
            params: [
                "contextid": "\(contextId)",
                "component": "user",
                "filearea": "draft",
                "itemid": "\(draftItemId)",
                "filepath": "/",
                "filename": filename,
                "filecontent": fileData.base64EncodedString()
            ]
        )

        if let dict = raw as? [String: Any] {
            if let exception = dict["exception"] as? String {
                let message = dict["message"] as? String ?? exception
                throw MoodleError.apiError(message)
            }
            if let itemid = intValue(dict["itemid"]) {
                return MoodleUploadedFile(itemid: itemid, filename: dict["filename"] as? String ?? filename)
            }
            if intValue(dict["contextid"]) != nil {
                return MoodleUploadedFile(itemid: draftItemId, filename: dict["filename"] as? String ?? filename)
            }
        }

        if let arr = raw as? [[String: Any]], let first = arr.first {
            if let itemid = intValue(first["itemid"]) {
                return MoodleUploadedFile(itemid: itemid, filename: first["filename"] as? String ?? filename)
            }
        }

        throw MoodleError.decodeFailed("core_files_upload 回傳格式無法解析")
    }

    private func uploadAssignmentFileViaRepositoryCrawler(
        filename: String,
        fileData: Data,
        draftItemId: Int,
        assignmentCMID: Int,
        assignmentCourseID: Int?
    ) async throws -> MoodleUploadedFile {
        let editURL = "https://euni.niu.edu.tw/mod/assign/view.php?id=\(assignmentCMID)&action=editsubmission"
        // Prefer existing SSO/EUNI web session first to avoid autologin-key rate limits.
        await establishEUNISessionViaSSO()
        let direct = URL(string: editURL) ?? URL(string: "https://euni.niu.edu.tw")!
        var target = direct
        var usedAutologin = false
        #if DEBUG
        print("[MoodleCrawlerUpload] load editsubmission: \(target.absoluteString)")
        #endif

        func loadHTML(_ url: URL) async throws -> (html: String, finalURL: URL?) {
            await syncWebKitCookiesToSharedStorage()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMoodleMobileHeaders(to: &request)
            let (htmlData, htmlResp) = try await URLSession.shared.data(for: request)
            guard let http = htmlResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw MoodleError.serverError
            }
            return (String(data: htmlData, encoding: .utf8) ?? "", http.url)
        }

        func looksLikeLoginPage(html: String, finalURL: URL?) -> Bool {
            let url = finalURL?.absoluteString.lowercased() ?? ""
            if url.contains("/login/index.php") || url.contains("/sso/default.aspx") {
                return true
            }
            let lower = html.lowercased()
            if lower.contains("name=\"username\"") && lower.contains("name=\"password\"") {
                return true
            }
            if lower.contains("id=\"login\"") && lower.contains("login/index.php") {
                return true
            }
            return false
        }

        var page = try await loadHTML(target)
        var html = page.html
        var finalURL = page.finalURL
        var didSilentRefresh = false

        if looksLikeLoginPage(html: html, finalURL: finalURL) {
            #if DEBUG
            print("[MoodleCrawlerUpload] got login page, request silent refresh then retry editsubmission")
            #endif
            let refreshed = await SSOSessionService.shared.requestRefresh()
            if refreshed {
                didSilentRefresh = true
                await establishEUNISessionViaSSO()
                page = try await loadHTML(direct)
                html = page.html
                finalURL = page.finalURL
            }
        }

        let sesskey = extractFirstMatch(in: html, patterns: [
            "name=\"sesskey\"\\s+value=\"([^\"]+)\"",
            "\"sesskey\"\\s*:\\s*\"([^\"]+)\""
        ])

        var resolvedSesskey = sesskey
        if resolvedSesskey == nil || resolvedSesskey?.isEmpty == true {
            // Last fallback: autologin URL (can be rate-limited).
            if let autoURL = try? await autologinURL(for: editURL) {
                usedAutologin = true
                target = autoURL
                if let reloaded = try? await loadHTML(autoURL) {
                    html = reloaded.html
                    finalURL = reloaded.finalURL
                }
                resolvedSesskey = extractFirstMatch(in: html, patterns: [
                    "name=\"sesskey\"\\s+value=\"([^\"]+)\"",
                    "\"sesskey\"\\s*:\\s*\"([^\"]+)\""
                ])
            }
        }

        guard let sesskey = resolvedSesskey, !sesskey.isEmpty else {
            #if DEBUG
            print("[MoodleCrawlerUpload] failed to parse sesskey, html prefix: \(html.prefix(180))")
            #endif
            throw MoodleError.apiError("無法從作業頁取得 sesskey")
        }

        let clientID = extractFirstMatch(in: html, patterns: [
            "name=\"client_id\"\\s+value=\"([^\"]+)\"",
            "\"client_id\"\\s*:\\s*\"([^\"]+)\""
        ]) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let htmlContextCandidates = extractNumericMatches(in: html, patterns: [
            "name=\"ctx_id\"\\s+value=\"(\\d+)\"",
            "name=\"contextid\"\\s+value=\"(\\d+)\"",
            "data-contextid=\"(\\d+)\"",
            "\"ctx_id\"\\s*:\\s*(\\d+)",
            "\"contextid\"\\s*:\\s*(\\d+)",
            "\"context\"\\s*:\\s*\\{\\s*\"id\"\\s*:\\s*(\\d+)"
        ])
        let bestHTMLContext = htmlContextCandidates
            .filter { $0 > 1 }
            .max()

        let moduleContextId = await resolveModuleContextId(cmid: assignmentCMID, courseId: assignmentCourseID)
        let fallbackUserContextId = try? await ensureUserContextId()
        let finalContextId = moduleContextId
            ?? bestHTMLContext
            ?? fallbackUserContextId
            ?? 0
        let ctxID = "\(finalContextId)"

        let maxBytes = extractFirstMatch(in: html, patterns: [
            "name=\"maxbytes\"\\s+value=\"([^\"]+)\"",
            "\"maxbytes\"\\s*:\\s*(\\d+)"
        ]) ?? "0"

        let areaMaxBytes = extractFirstMatch(in: html, patterns: [
            "name=\"areamaxbytes\"\\s+value=\"([^\"]+)\"",
            "\"areamaxbytes\"\\s*:\\s*(\\d+)"
        ]) ?? "104857600"

        let uploadRepoCandidates = extractNumericMatches(in: html, patterns: [
            "\"id\"\\s*:\\s*(\\d+)\\s*,\\s*\"type\"\\s*:\\s*\"upload\"",
            "\"type\"\\s*:\\s*\"upload\"\\s*,\\s*\"id\"\\s*:\\s*(\\d+)",
            "name=\"repo_id\"\\s+value=\"(\\d+)\""
        ])
        let pageDraftItemID = extractFirstMatch(in: html, patterns: [
            "name=\"files_filemanager\"\\s+value=\"(\\d+)\"",
            "name=\"[^\"]*_filemanager\"\\s+value=\"(\\d+)\"",
            "\"itemid\"\\s*:\\s*(\\d+)"
        ])
        let effectiveDraftItemID = pageDraftItemID ?? "\(draftItemId)"

        let hiddenEnv = extractHiddenInputValue(in: html, name: "env") ?? "filemanager"
        let hiddenPage = extractHiddenInputValue(in: html, name: "page") ?? ""
        let hiddenP = extractHiddenInputValue(in: html, name: "p") ?? ""
        let hiddenSubdirs = extractHiddenInputValue(in: html, name: "subdirs") ?? "0"
        let hiddenAcceptedTypes = extractHiddenInputValue(in: html, name: "accepted_types")

        func resolveUploadRepoIDFromList(
            itemID: String,
            contextID: String,
            clientID: String
        ) async -> Int? {
            var listComponents = URLComponents(string: "\(baseURL)/repository/repository_ajax.php")!
            listComponents.queryItems = [URLQueryItem(name: "action", value: "list")]
            guard let listURL = listComponents.url else { return nil }

            var req = URLRequest(url: listURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            applyMoodleMobileHeaders(to: &req)
            req.setValue(editURL, forHTTPHeaderField: "Referer")
            await syncWebKitCookiesToSharedStorage()

            var form: [(String, String)] = [
                ("sesskey", sesskey),
                ("client_id", clientID),
                ("itemid", itemID),
                ("ctx_id", contextID),
                ("maxbytes", maxBytes),
                ("areamaxbytes", areaMaxBytes),
                ("env", hiddenEnv),
                ("p", hiddenP),
                ("page", hiddenPage),
                ("subdirs", hiddenSubdirs),
                ("savepath", "/")
            ]
            if let hiddenAcceptedTypes, !hiddenAcceptedTypes.isEmpty {
                form.append(("accepted_types[]", hiddenAcceptedTypes))
            }
            req.httpBody = form
                .map { "\($0.0.urlEncoded)=\($0.1.urlEncoded)" }
                .joined(separator: "&")
                .data(using: .utf8)

            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }

            func findUploadID(in array: [[String: Any]]) -> Int? {
                for item in array {
                    let type = (item["type"] as? String)?.lowercased()
                    if type == "upload", let id = intValue(item["id"]), id > 0 {
                        return id
                    }
                }
                return nil
            }

            if let dict = json as? [String: Any] {
                if let list = dict["list"] as? [[String: Any]], let id = findUploadID(in: list) { return id }
                if let repositories = dict["repositories"] as? [[String: Any]], let id = findUploadID(in: repositories) { return id }
                if let error = dict["error"] as? String, !error.isEmpty {
                    #if DEBUG
                    print("[MoodleCrawlerUpload] repository list error: \(error)")
                    #endif
                }
            } else if let arr = json as? [[String: Any]], let id = findUploadID(in: arr) {
                return id
            }
            return nil
        }

        let repoIDIntFromHTML = uploadRepoCandidates.first(where: { $0 > 1 })
        let repoIDFromList = await resolveUploadRepoIDFromList(
            itemID: effectiveDraftItemID,
            contextID: ctxID,
            clientID: clientID
        )
        let repoID = String(repoIDFromList ?? repoIDIntFromHTML ?? uploadRepoCandidates.first ?? 1)

        var ajax = URLComponents(string: "\(baseURL)/repository/repository_ajax.php")!
        ajax.queryItems = [URLQueryItem(name: "action", value: "upload")]
        guard let ajaxURL = ajax.url else { throw MoodleError.invalidURL }

        let boundary = "Boundary-\(UUID().uuidString)"
        var uploadReq = URLRequest(url: ajaxURL)
        uploadReq.httpMethod = "POST"
        uploadReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyMoodleMobileHeaders(to: &uploadReq)
        uploadReq.setValue(editURL, forHTTPHeaderField: "Referer")
        await syncWebKitCookiesToSharedStorage()

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("title", filename)
        appendField("author", "NIU APP")
        appendField("license", "allrightsreserved")
        appendField("itemid", effectiveDraftItemID)
        appendField("repo_id", repoID)
        appendField("p", hiddenP)
        appendField("page", hiddenPage)
        appendField("env", hiddenEnv)
        appendField("sesskey", sesskey)
        appendField("client_id", clientID)
        appendField("maxbytes", maxBytes)
        appendField("areamaxbytes", areaMaxBytes)
        appendField("ctx_id", ctxID)
        appendField("savepath", "/")
        appendField("subdirs", hiddenSubdirs)
        if let hiddenAcceptedTypes, !hiddenAcceptedTypes.isEmpty {
            appendField("accepted_types[]", hiddenAcceptedTypes)
        }
        appendField("repo_upload_file", "1")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"repo_upload_file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeTypeForFileExtension(URL(fileURLWithPath: filename).pathExtension))\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        uploadReq.httpBody = body

        #if DEBUG
        print("[MoodleCrawlerUpload] cmid=\(assignmentCMID) draft=\(effectiveDraftItemID) repo=\(repoID) repoFromList=\(repoIDFromList.map(String.init) ?? "nil") repoCandidates=\(uploadRepoCandidates.prefix(6)) ctx=\(ctxID) bytes=\(fileData.count) autologin=\(usedAutologin) silentRefresh=\(didSilentRefresh) finalURL=\(finalURL?.absoluteString ?? "nil") env=\(hiddenEnv) p=\(hiddenP) page=\(hiddenPage) htmlCtxCandidates=\(htmlContextCandidates.prefix(6)) moduleCtx=\(moduleContextId.map(String.init) ?? "nil")")
        #endif

        let (data, response) = try await URLSession.shared.data(for: uploadReq)
        guard let uploadHTTP = response as? HTTPURLResponse, (200...299).contains(uploadHTTP.statusCode) else {
            throw MoodleError.serverError
        }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                if let error = dict["error"] as? String, !error.isEmpty {
                    throw MoodleError.apiError(error)
                }
                if let exception = dict["exception"] as? String {
                    let message = dict["message"] as? String ?? exception
                    throw MoodleError.apiError(message)
                }
                if dict["url"] != nil || dict["id"] != nil || dict["filepath"] != nil {
                    return MoodleUploadedFile(itemid: Int(effectiveDraftItemID) ?? draftItemId, filename: filename)
                }
            }
            if let arr = json as? [[String: Any]], !arr.isEmpty {
                return MoodleUploadedFile(itemid: Int(effectiveDraftItemID) ?? draftItemId, filename: filename)
            }
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            throw MoodleError.apiError("repository_ajax 上傳失敗：\(text)")
        }
        throw MoodleError.decodeFailed("repository_ajax 回傳格式無法解析")
    }

    private func extractFirstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if let match = regex.firstMatch(in: text, options: [], range: range),
                   match.numberOfRanges > 1,
                   let r = Range(match.range(at: 1), in: text) {
                    let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { return value }
                }
            }
        }
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
