import Foundation

// MARK: - 可報名活動資料模型
struct EventData: Identifiable, Codable {
    var id: String { eventSerialID }
    let name: String
    let department: String
    let event_state: String
    let eventSerialID: String
    let eventTime: String
    let eventLocation: String
    let eventRegisterTime: String
    let eventDetail: String
    let contactInfoName: String
    let contactInfoTel: String
    let contactInfoMail: String
    let Related_links: String
    let Multi_factor_authentication: String
    let eventPeople: String
    let Remark: String
}

// MARK: - 已報名活動資料模型
struct EventData_Apply: Identifiable, Codable {
    var id: String { eventSerialID }
    let name: String
    let department: String
    let state: String
    let event_state: String
    let eventSerialID: String
    let eventTime: String
    let eventLocation: String
    let eventRegisterTime: String
    let eventDetail: String
    let contactInfoName: String
    let contactInfoTel: String
    let contactInfoMail: String
    let Related_links: String
    let Multi_factor_authentication: String
    let Remark: String
}

// MARK: - 報名資訊
struct EventInfo: Codable {
    var RequestVerificationToken: String
    var SignId: String
    var role: String
    var classes: String
    var schnum: String
    var name: String
    var Tel: String
    var Mail: String
    var selectedFood: String
    var selectedProof: String
    var Remark: String
}
