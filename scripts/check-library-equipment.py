#!/usr/bin/env python3
"""Exercise production equipment decoding and state with synthetic data, no Keychain or school requests."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
service = (root / "Features/Library/LibraryEquipmentService.swift").read_text()
protocol = service[service.index("@MainActor\nprotocol"):service.index("@MainActor\nfinal class")]
fixture = r'''
import Foundation
import WebKit
@MainActor enum StorageKeys {
    static let username = "fixture-account"
    static let authSessionID = "fixture-session"
}
@MainActor final class LoginRepository {
    static let shared = LoginRepository()
    func getSavedCredentials() -> (username: String, password: String)? {
        fatalError("Keychain access is forbidden in this fixture")
    }
}
@MainActor final class LibraryEquipmentService: LibraryEquipmentServing {
    var webView: WKWebView? { nil }
    var onWebViewCreated: ((WKWebView) -> Void)?
    var records: [LibraryEquipmentReservation] = []
    var mutationCount = 0
    var cancelledID: Int?
    var uncertain = false
    var busy = false
    var closed = false
    var connectionError: LibraryEquipmentError?
    var connections = 0
    var expireSession = false
    var policyError: LibraryEquipmentError?
    var recordsError: LibraryEquipmentError?
    var failRefreshAfterMutation = false
    var availableEquipment: [LibraryEquipmentItem]?
    var availableGroups: [LibraryEquipmentGroup]?
    var occupiedIntervals: [LibraryEquipmentInterval]?
    var pauseSchedule = false
    var delayed: CheckedContinuation<LibraryEquipmentSchedule, Never>?
    let group = LibraryEquipmentGroup(id: 5, name: "測試群組", timeType: 0, total: 1, available: 1)
    let item = LibraryEquipmentItem(id: 56, name: "測試設備")
    var rules = LibraryEquipmentPolicy(minimumHours: 1, maximumHours: 4, remainingHours: 28,
                                       openMinute: 480, closeMinute: 1290)
    func connect(account: String, password: String?) async throws {
        closed = false
        connections += 1
        if let connectionError { throw connectionError }
    }
    func resumeLogin() async throws {}
    func groups() async throws -> [LibraryEquipmentGroup] { availableGroups ?? [group] }
    func reservations() async throws -> [LibraryEquipmentReservation] {
        if expireSession { expireSession = false; throw LibraryEquipmentError.loginRequired }
        if let recordsError { throw recordsError }
        return records
    }
    func schedule(groupID: Int, date: Date) async throws -> LibraryEquipmentSchedule {
        let result = LibraryEquipmentSchedule(equipment: availableEquipment ?? [item], occupied: occupiedIntervals ?? (busy ? [
            LibraryEquipmentInterval(equipmentID: 56,
                start: LibraryEquipmentDate.at(480, on: date), end: LibraryEquipmentDate.at(540, on: date))
        ] : []))
        if pauseSchedule {
            pauseSchedule = false
            return await withCheckedContinuation { delayed = $0 }
        }
        return result
    }
    func policy(groupID: Int, equipmentID: Int, date: Date) async throws -> LibraryEquipmentPolicy {
        if let policyError { throw policyError }
        return rules
    }
    func reserve(_ draft: LibraryEquipmentDraft) async throws {
        mutationCount += 1
        try await Task.sleep(for: .milliseconds(20))
        if uncertain { throw LibraryEquipmentError.uncertainMutation }
        records = [LibraryEquipmentReservation(id: 901, equipmentID: 56, equipmentName: item.name,
                                               start: draft.start, end: draft.end, keepUntil: nil)]
        if failRefreshAfterMutation { recordsError = .unavailable }
    }
    func cancelReservation(_ reservation: LibraryEquipmentReservation) async throws {
        mutationCount += 1
        cancelledID = reservation.id
        records = []
    }
    func close() { closed = true }
}
@main struct Checks {
    @MainActor static func settle(_ model: LibraryEquipmentViewModel) async throws {
        for _ in 0..<200 {
            await Task.yield()
            if !model.isLoading && !model.isMutating { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("State did not settle")
    }
    static func reject(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Invalid input was accepted") } catch {}
    }
    static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor static func main() async throws {
        let day = LibraryEquipmentDate.parse("2099/10/01 00:00")!
        let epoch = LibraryEquipmentDate.parse("2026-09-30T16:00:00Z")!
        precondition(LibraryEquipmentDate.format(epoch) == "2026/10/01", "Dates must use Taipei")
        precondition(LibraryEquipmentDate.day(epoch) == epoch, "Taipei midnight boundary")
        precondition(LibraryEquipmentDate.minute("24:30") == nil)
        let service = LibraryEquipmentService()
        let free = LibraryEquipmentSchedule(equipment: [service.item], occupied: [])
        func draft(_ start: Int, _ end: Int) -> LibraryEquipmentDraft {
            LibraryEquipmentDraft(group: service.group, equipment: service.item, date: day,
                                  startMinute: start, endMinute: end, policy: service.rules)
        }
        try service.rules.validate(draft(480, 540), schedule: free)
        try service.rules.validate(draft(1230, 1290), schedule: free)
        reject { try service.rules.validate(draft(480, 510), schedule: free) }
        reject { try service.rules.validate(draft(480, 780), schedule: free) }
        reject { try service.rules.validate(draft(1230, 1320), schedule: free) }
        reject { try service.rules.validate(draft(481, 541), schedule: free) }
        let busy = LibraryEquipmentSchedule(equipment: [service.item], occupied: [
            LibraryEquipmentInterval(equipmentID: 56,
                start: LibraryEquipmentDate.at(540, on: day), end: LibraryEquipmentDate.at(600, on: day))
        ])
        try service.rules.validate(draft(480, 540), schedule: busy)
        try service.rules.validate(draft(600, 660), schedule: busy)
        reject { try service.rules.validate(draft(510, 630), schedule: busy) }
        reject { try service.rules.validate(draft(480, 540), schedule: free, now: draft(480, 540).end) }
        let noQuota = LibraryEquipmentPolicy(minimumHours: 1, maximumHours: 4, remainingHours: 0.5,
                                             openMinute: 480, closeMinute: 1290)
        reject { try noQuota.validate(draft(480, 540), schedule: free) }
        let policyJSON: [String: Any] = ["canReserveMinUnit": "1.0", "canReserveMaxUnit": 4,
            "maxCanReserveTotalUnit": "28.0", "inReserve": 3.5, "openTime": "08:00", "closeTime": "21:30"]
        let policyText = String(data: try JSONSerialization.data(withJSONObject: policyJSON), encoding: .utf8)!
        let decoded = try decode(LibraryEquipmentDecoding.PolicyResult.self,
            ["getDayReservedByReader": ["success": true, "data": policyText]])
        let decodedPolicy = try decoded.policy()
        precondition(decodedPolicy.remainingHours == 24.5)
        reject {
            let invalid = policyText.replacingOccurrences(of: "1.0", with: "NaN")
            _ = try decode(LibraryEquipmentDecoding.PolicyResult.self,
                ["getDayReservedByReader": ["success": true, "data": invalid]]).policy()
        }
        let groups = try decode(LibraryEquipmentDecoding.GroupResult.self, ["getEquipmentGroupInfo": [
            "eqgroupitemlist": [
                ["equipmentGroup": ["id": 5, "name": "有政策"], "ebPolicy": ["timeType": 0], "useNum": 0, "equipmentNum": 1],
                ["equipmentGroup": ["id": 7, "name": "無政策"], "ebPolicy": NSNull(), "useNum": 0, "equipmentNum": 1]
            ]]])
        precondition(groups.groups.map(\.id) == [5])
        let records = try decode(LibraryEquipmentDecoding.ReservationsResult.self, ["reservelist": [
            "success": true, "eqgroupitemlist": [
                ["equipment": ["id": 56, "name": "測試"], "equipmentCir": [
                    "id": 123, "startDate": "2099-10-01 08:00:00", "endDate": "2099-10-01 09:00:00"],
                 "equipmentCirContent": ["id": 901]]
            ]]])
        let decodedRecords = try records.reservations()
        precondition(decodedRecords.first?.id == 901, "Cancellation must use content ID")
        let emptyRecords = try decode(LibraryEquipmentDecoding.ReservationsResult.self,
            ["reservelist": ["success": false, "eqgroupitemlist": []]])
        let empty = try emptyRecords.reservations()
        precondition(empty.isEmpty, "School returns success=false with an empty list when no records exist")
        let searchRecords = [
            LibraryEquipmentReservation(id: 1, equipmentID: 56, equipmentName: "iSmart 504", start: LibraryEquipmentDate.at(480, on: day), end: LibraryEquipmentDate.at(540, on: day), keepUntil: nil),
            LibraryEquipmentReservation(id: 2, equipmentID: 57, equipmentName: "討論室", start: LibraryEquipmentDate.at(1380, on: day.addingTimeInterval(-86400)), end: LibraryEquipmentDate.at(60, on: day), keepUntil: nil),
            LibraryEquipmentReservation(id: 3, equipmentID: 58, equipmentName: "研究小間", start: LibraryEquipmentDate.at(480, on: day.addingTimeInterval(-86400)), end: LibraryEquipmentDate.at(540, on: day.addingTimeInterval(-86400)), keepUntil: nil),
            LibraryEquipmentReservation(id: 4, equipmentID: 56, equipmentName: "iSmart 504", start: LibraryEquipmentDate.at(480, on: day.addingTimeInterval(86400)), end: LibraryEquipmentDate.at(540, on: day.addingTimeInterval(86400)), keepUntil: nil),
            LibraryEquipmentReservation(id: 5, equipmentID: 56, equipmentName: "iSmart 504", start: LibraryEquipmentDate.at(480, on: day.addingTimeInterval(6 * 86400)), end: LibraryEquipmentDate.at(540, on: day.addingTimeInterval(6 * 86400)), keepUntil: nil),
            LibraryEquipmentReservation(id: 6, equipmentID: 56, equipmentName: "iSmart 504", start: LibraryEquipmentDate.at(0, on: day.addingTimeInterval(7 * 86400)), end: LibraryEquipmentDate.at(60, on: day.addingTimeInterval(7 * 86400)), keepUntil: nil)
        ]
        precondition(LibraryReservationSearch.filter(searchRecords, query: "ISMART 2099-10-01 08:00", period: .today, equipmentID: 56, now: day).map(\.id) == [1])
        precondition(LibraryReservationSearch.filter(searchRecords, query: "", period: .today, equipmentID: nil, now: day).map(\.id) == [2, 1], "Today includes a reservation crossing Taipei midnight")
        precondition(LibraryReservationSearch.filter(searchRecords, query: "", period: .tomorrow, equipmentID: nil, now: day).map(\.id) == [4])
        precondition(LibraryReservationSearch.filter(searchRecords, query: "", period: .week, equipmentID: nil, now: day).map(\.id) == [2, 1, 4, 5], "Week covers today through the sixth following day")
        precondition(LibraryReservationSearch.filter(searchRecords, query: "not found", period: .all, equipmentID: nil, now: day).isEmpty)

        var account = "synthetic"
        var session = "one"
        let model = LibraryEquipmentViewModel(service: service, currentAccount: { account },
            currentSession: { session }, password: { _ in nil })
        service.connectionError = .unavailable
        model.start()
        try await settle(model)
        precondition(!model.needsLogin && model.errorMessage != nil, "Offline is distinct from required login")
        service.connectionError = nil
        model.refresh()
        try await settle(model)
        precondition(model.policy != nil, "An initial network failure must support reconnect")
        model.start()
        try await settle(model)
        let connections = service.connections
        service.expireSession = true
        model.refresh()
        try await settle(model)
        precondition(service.connections == connections + 1 && !model.needsLogin && model.errorMessage == nil
                     && model.policy != nil, "An expired school session re-signs in quietly before showing login")
        service.expireSession = true
        service.connectionError = .loginRequired
        model.refresh()
        try await settle(model)
        precondition(service.connections == connections + 2 && model.errorMessage != nil,
                     "A failed quiet re-sign-in surfaces login and does not loop")
        service.connectionError = nil
        model.start()
        try await settle(model)
        model.select(date: day)
        try await settle(model)
        precondition(model.policy != nil && model.selectedStartMinute == nil, "No implicit booking selection")
        model.selectStart(480)
        precondition(model.selectionError == nil && model.durationMinutes == 60)
        precondition(model.maximumDuration == 240, "Slider must respect the school's per-booking maximum")
        model.setDuration(90)
        precondition(model.durationMinutes == 90)
        model.setDuration(75)
        precondition(model.durationMinutes == 90, "Slider only accepts 30-minute steps")
        precondition(model.slots.filter(\.isSelected).count == 3, "Whole chosen interval must be marked")
        model.changeDuration(by: 240)
        precondition(model.durationMinutes == 90, "Rejected length must preserve the original selection")
        model.selectStart(1260)
        precondition(model.selectedStartMinute == 480 && model.durationMinutes == 90,
                     "A new start that cannot fit must not shorten or move the chosen interval")
        model.changeDuration(by: -30)
        model.selectStart(1200)
        precondition(model.durationMinutes == 60 && model.maximumDuration == 90,
                     "A new start resets duration; slider stops at closing time")
        model.setDuration(90)
        model.selectStart(480)
        precondition(model.durationMinutes == 60, "Choose start before choosing length")
        service.occupiedIntervals = [LibraryEquipmentInterval(equipmentID: 56,
            start: LibraryEquipmentDate.at(570, on: day), end: LibraryEquipmentDate.at(600, on: day))]
        model.refresh()
        try await settle(model)
        precondition(model.maximumDuration == 90, "Slider cannot extend across occupied time")
        model.setDuration(120)
        precondition(model.durationMinutes == 60, "Out-of-range duration is rejected rather than submitted")
        model.setDuration(90)
        service.rules = LibraryEquipmentPolicy(minimumHours: 1, maximumHours: 4, remainingHours: 1,
                                               openMinute: 480, closeMinute: 1290)
        model.refresh()
        try await settle(model)
        precondition(model.selectedStartMinute == nil, "Quota changes invalidate old length")
        model.selectStart(480)
        precondition(model.maximumDuration == 60, "Single legal duration is shown without a degenerate slider")
        service.occupiedIntervals = nil
        service.rules = LibraryEquipmentPolicy(minimumHours: 1, maximumHours: 4, remainingHours: 28,
                                               openMinute: 480, closeMinute: 1290)
        model.refresh()
        try await settle(model)
        service.policyError = .rejected("測試：校方目前未開放")
        model.refresh()
        try await settle(model)
        precondition(model.selectedStartMinute == nil && model.policy == nil, "Policy refusal must invalidate selection")
        service.policyError = nil
        model.refresh()
        try await settle(model)
        model.selectStart(480)
        service.availableEquipment = [LibraryEquipmentItem(id: 57, name: "替代設備")]
        model.refresh()
        try await settle(model)
        precondition(model.selectedEquipment?.id == 57 && model.selectedStartMinute == nil,
                     "Refresh must never transfer selection to another device")
        model.selectStart(480)
        service.availableGroups = [LibraryEquipmentGroup(id: 8, name: "替代群組", timeType: 0, total: 1, available: 1)]
        model.refresh()
        try await settle(model)
        precondition(model.groupID == 8 && model.selectedStartMinute == nil,
                     "Refresh must never transfer selection to another group")
        service.availableEquipment = nil
        service.availableGroups = nil
        model.refresh()
        try await settle(model)
        service.pauseSchedule = true
        model.select(date: day.addingTimeInterval(86400))
        for _ in 0..<100 where service.delayed == nil { await Task.yield() }
        precondition(service.delayed != nil)
        model.select(date: day.addingTimeInterval(2 * 86400))
        try await settle(model)
        service.delayed?.resume(returning: LibraryEquipmentSchedule(equipment: [], occupied: []))
        service.delayed = nil
        try await Task.sleep(for: .milliseconds(20))
        precondition(model.selectedEquipment?.id == 56, "Old selection response must not overwrite new state")
        precondition(model.selectedStartMinute == nil, "Changing date must clear the old selection")
        model.selectStart(480)
        model.prepareConfirmation()
        try await settle(model)
        precondition(model.confirmation != nil)
        service.busy = true
        model.submit()
        try await settle(model)
        precondition(service.mutationCount == 0, "Recheck must reject newly occupied selection")
        precondition(model.selectedStartMinute == nil, "An invalidated confirmation must clear selection")
        service.busy = false
        model.refresh()
        try await settle(model)
        model.selectStart(480)
        model.prepareConfirmation()
        try await settle(model)
        model.submit()
        model.submit()
        let cancelledRefresh = Task { @MainActor in await model.refreshAndWait() }
        await cancelledRefresh.value
        precondition(model.isMutating, "Refresh must return immediately while a mutation is running")
        cancelledRefresh.cancel()
        try await settle(model)
        precondition(service.mutationCount == 1 && model.reservations.count == 1, "No duplicate mutations")
        precondition(model.completion?.kind == .reserved && model.completion?.equipmentName == service.item.name)
        model.dismissCompletion()
        precondition(model.completion == nil)
        model.reservationEquipmentID = 56
        model.reservationQuery = "測試"
        precondition(model.filteredReservations.count == 1)
        model.cancel(model.reservations[0])
        try await settle(model)
        precondition(service.cancelledID == 901 && model.reservations.isEmpty)
        precondition(model.completion?.kind == .cancelled && model.reservationEquipmentID == nil)
        model.dismissCompletion()
        model.resetReservationFilters()
        service.failRefreshAfterMutation = true
        model.selectStart(480)
        model.prepareConfirmation()
        try await settle(model)
        model.submit()
        try await settle(model)
        precondition(model.completion?.kind == .reserved && model.completion?.refreshFailed == true,
                     "Confirmed success survives a follow-up refresh failure")
        service.failRefreshAfterMutation = false
        service.recordsError = nil
        model.dismissCompletion()
        model.refresh()
        try await settle(model)
        service.uncertain = true
        model.selectStart(480)
        model.prepareConfirmation()
        try await settle(model)
        model.submit()
        try await settle(model)
        precondition(model.needsVerification && model.reservationsUpdatedAt == nil)
        precondition(model.completion == nil, "An uncertain mutation must never show success")
        let attempts = service.mutationCount
        model.prepareConfirmation()
        model.submit()
        model.acknowledgeVerification()
        precondition(model.needsVerification && service.mutationCount == attempts)
        model.refresh()
        try await settle(model)
        model.acknowledgeVerification()
        precondition(!model.needsVerification && service.mutationCount == attempts)

        service.pauseSchedule = true
        model.refresh()
        for _ in 0..<100 where service.delayed == nil { await Task.yield() }
        account = "another"
        session = "two"
        model.stop()
        model.start()
        try await settle(model)
        service.delayed?.resume(returning: LibraryEquipmentSchedule(equipment: [], occupied: []))
        service.delayed = nil
        try await Task.sleep(for: .milliseconds(20))
        precondition(model.selectedEquipment?.id == 56, "Prior account request must be discarded")
        model.stop()
        precondition(model.groups.isEmpty && model.reservations.isEmpty && model.policy == nil && service.closed)
        precondition(model.completion == nil && !model.hasReservationFilters)
        print("PASS: Taipei dates, quiet re-sign-in after session expiry, duration/quota/busy boundaries, policy decoding, cancellation IDs, stale selection/account responses, fresh confirmation, double submit prevention, refresh cancellation during mutation, uncertain outcome reconciliation, cleanup")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="niu-equipment-check-") as directory:
    folder = Path(directory)
    checks = folder / "Checks.swift"
    checks.write_text("import WebKit\n" + protocol + fixture)
    binary = folder / "checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(folder / "ModuleCache"),
        "-parse-as-library", str(root / "Features/Library/LibraryEquipmentModels.swift"),
        str(root / "Features/Library/LibraryEquipmentViewModel.swift"),
        str(checks), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
