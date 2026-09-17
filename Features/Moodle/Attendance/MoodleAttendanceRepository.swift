import Foundation

@MainActor
protocol MoodleAttendanceRepositoryProtocol {
    func fetchCourseAttendance(courseId: Int) async throws -> [MoodleAttendanceSection]
    func fetchAttendance(
        module: MoodleModule,
        sectionName: String,
        attendanceId: Int?,
        courseModuleId: Int?
    ) async throws -> MoodleAttendanceSection
}

@MainActor
struct MoodleAttendanceRepository: MoodleAttendanceRepositoryProtocol {
    private let client: any MoodleAttendanceAPIClientProtocol

    init(client: (any MoodleAttendanceAPIClientProtocol)? = nil) {
        self.client = client ?? MoodleService.shared
    }

    func fetchCourseAttendance(courseId: Int) async throws -> [MoodleAttendanceSection] {
        let courseSections = try await client.fetchCourseContents(courseId: courseId)
        var results: [MoodleAttendanceSection] = []
        var lastError: Error?

        for courseSection in courseSections {
            for module in courseSection.modules where module.modname == "attendance" {
                do {
                    let result = try await fetchAttendance(
                        module: module,
                        sectionName: courseSection.name,
                        attendanceId: module.instance,
                        courseModuleId: module.id
                    )
                    results.append(result)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }

        if results.isEmpty, let lastError {
            throw lastError
        }
        return results
    }

    func fetchAttendance(
        module: MoodleModule,
        sectionName: String = "",
        attendanceId: Int? = nil,
        courseModuleId: Int? = nil
    ) async throws -> MoodleAttendanceSection {
        let resolvedAttendanceId: Int?
        if module.modname == "attendance" {
            if let directID = attendanceId ?? module.instance {
                resolvedAttendanceId = directID
            } else if let courseModuleId {
                resolvedAttendanceId = try await client.resolveAttendanceInstanceId(
                    courseModuleId: courseModuleId
                )
            } else {
                resolvedAttendanceId = nil
            }
        } else if let courseModuleId {
            // A URL module's `instance` belongs to mod_url, not mod_attendance.
            resolvedAttendanceId = try await client.resolveAttendanceInstanceId(
                courseModuleId: courseModuleId
            )
        } else {
            resolvedAttendanceId = attendanceId
        }

        guard let resolvedAttendanceId else {
            throw MoodleError.apiError("無法識別出缺席資料")
        }

        // Prefer the student-session Web Service when this Moodle installation
        // exposes it; it is faster and does not depend on WebKit cookies. Some
        // deployments/courses do not expose usable per-user status data, so
        // HTML stays isolated here as a compatibility fallback.
        var pendingAPICandidate: MoodleAttendanceSection?
        do {
            let response = try await client.fetchAttendanceUserSessions(attendanceId: resolvedAttendanceId)
            let apiRecords = mapAPIResponse(response)
            let section = MoodleAttendanceSection(
                id: module.id,
                sectionName: sectionName,
                moduleName: module.name,
                records: apiRecords,
                total: response.sessions.count,
                source: .webService
            )
            if apiRecords.contains(where: { $0.status != .pending }) {
                return section
            }
            // HTML may enrich an all-pending response, but the API result is
            // still valid and must survive a WebKit/session failure.
            pendingAPICandidate = section
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Continue to the compatibility path below. If that also fails its
            // concrete error is more useful to the user than this API failure.
        }

        do {
            let html = try await client.fetchAttendanceFromHTML(
                attendanceId: resolvedAttendanceId,
                courseModuleId: courseModuleId ?? module.id
            )
            let records = html.records.map {
                MoodleAttendanceRecord(
                    id: $0.id,
                    date: $0.date,
                    timeText: $0.timeText,
                    description: $0.description,
                    statusLabel: $0.statusLabel,
                    scoreText: $0.scoreText,
                    remarks: $0.remarks,
                    status: normalizedStatus(label: $0.statusLabel, grade: nil, hasRecordedStatus: true)
                )
            }
            if records.isEmpty,
               let pendingAPICandidate,
               !pendingAPICandidate.records.isEmpty {
                return pendingAPICandidate
            }
            return MoodleAttendanceSection(
                id: module.id,
                sectionName: sectionName,
                moduleName: module.name,
                records: records,
                total: max(html.total, records.count),
                source: .htmlFallback
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let pendingAPICandidate {
                return pendingAPICandidate
            }
            throw error
        }
    }

    private func mapAPIResponse(_ response: MoodleAttendanceUserSessionsResponse) -> [MoodleAttendanceRecord] {
        let statusByID = Dictionary(uniqueKeysWithValues: response.statuses.map { ($0.id, $0) })

        return response.sessions.map { session in
            let attendanceStatus = session.statusid.flatMap { statusByID[$0] }
            let statusLabel = attendanceStatus?.description ?? attendanceStatus?.acronym
            let status = normalizedStatus(
                label: statusLabel,
                grade: attendanceStatus?.grade,
                hasRecordedStatus: attendanceStatus != nil
            )

            let date = Date(timeIntervalSince1970: TimeInterval(session.sessdate))
            return MoodleAttendanceRecord(
                id: session.id,
                date: date,
                timeText: date.formatted(date: .omitted, time: .shortened),
                description: session.description?.strippingHTML,
                statusLabel: statusLabel ?? "尚未點名",
                scoreText: attendanceStatus?.grade.map { String(format: "%g", $0) },
                remarks: session.remarks,
                status: status
            )
        }
        .sorted { $0.date > $1.date }
    }

    private func normalizedStatus(
        label: String?,
        grade: Double?,
        hasRecordedStatus: Bool
    ) -> MoodleAttendanceRecord.Status {
        guard hasRecordedStatus else { return .pending }
        let normalized = (label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let absentTerms = ["未到", "缺席", "曠課", "absent"]
        if normalized == "a" || absentTerms.contains(where: normalized.contains) {
            return .absent
        }

        let presentTerms = ["出席", "遲到", "請假", "present", "late", "leave", "excused"]
        if ["p", "l", "e"].contains(normalized) || presentTerms.contains(where: normalized.contains) {
            return .present
        }

        let pendingTerms = ["尚未", "未簽到", "未記錄", "未結算", "not set", "unknown", "pending"]
        if normalized.isEmpty || pendingTerms.contains(where: normalized.contains) {
            return .pending
        }

        if let grade {
            return grade > 0 ? .present : .absent
        }
        return .pending
    }
}

private extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
