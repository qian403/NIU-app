#if DEBUG
import Foundation

/// Offline-only entry point for preview/review hosts. No Keychain, WebKit or school requests.
@MainActor enum EventBatchPreviewFixtures {
    static func event(_ id: String, name: String = "合成活動", state: String = "報名中",
                      dates: String = "", people: String = "限額 80人\n已報名 42人") -> EventData {
        EventData(name: name, department: "合成測試單位", event_state: state, eventSerialID: id,
                  eventTime: "2026/10/20 13:00 ~ 15:00", eventLocation: "測試教室", eventRegisterTime: dates,
                  eventDetail: "純離線測試資料", contactInfoName: "", contactInfoTel: "", contactInfoMail: "",
                  Related_links: "", Multi_factor_authentication: "", eventPeople: people, Remark: "")
    }
    static var events: [EventData] {
        [event("91001", name: "設計工作坊（成功）"), event("91002", name: "攝影講座（校方拒絕）"),
         event("91003", name: "創意寫作（結果不明）"), event("91004", name: "已報名活動"),
         event("91005", name: "截止活動", state: "報名截止"),
         event("91006", name: "額滿活動", people: "限額 30人\n已報名 30人"),
         event("91007", name: "未開放活動", state: "尚未開放")]
    }
    static func applied(_ event: EventData) -> EventData_Apply {
        EventData_Apply(name: event.name, department: event.department, state: "已報名", event_state: event.event_state,
                        eventSerialID: event.id, eventTime: event.eventTime, eventLocation: event.eventLocation,
                        eventRegisterTime: event.eventRegisterTime, eventDetail: "", contactInfoName: "", contactInfoTel: "",
                        contactInfoMail: "", Related_links: "", Multi_factor_authentication: "", Remark: "")
    }
    final class Service: EventRegistrationServing {
        func availableEvents() async throws -> [EventData] { events }
        func appliedEvents() async throws -> [EventData_Apply] { [applied(event("91004"))] }
        func register(eventID: String) async throws -> EventActionOutcome {
            try await Task.sleep(for: .milliseconds(400))
            switch eventID {
            case "91002": return .rejected("合成回應：校方資格不符，未完成報名。")
            case "91003": return .uncertain("合成回應：送出後連線中斷，請查看已報名活動，勿立即重送。")
            default: return .confirmed("合成回應：校方清單已確認報名。")
            }
        }
        func cancelRegistration(eventID: String) async throws -> EventActionOutcome { throw EventRegistrationError.invalidResponse }
        func registrationForm(eventID: String) async throws -> EventRegistrationForm { throw EventRegistrationError.invalidResponse }
        func modifyRegistration(eventID: String, form: EventRegistrationForm) async throws -> EventActionOutcome { throw EventRegistrationError.invalidResponse }
    }
}
#endif
