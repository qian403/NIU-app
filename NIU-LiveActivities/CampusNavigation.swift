import AppIntents
import Combine
import Foundation

/// Shared by the app and extension; these links contain no student credentials.
enum CampusDestination: String, Hashable {
    case classSchedule = "class-schedule"
    case academicCalendar = "academic-calendar"
    case attendance
    case library

    var url: URL { URL(string: "niuapp://\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "niuapp",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let host = url.host?.lowercased() else { return nil }
        self.init(rawValue: host)
    }
}

@MainActor
final class CampusRouter: ObservableObject {
    static let shared = CampusRouter()

    struct Request: Identifiable {
        let id = UUID()
        let destination: CampusDestination
    }

    @Published var pendingRequest: Request?

    func open(_ destination: CampusDestination) {
        pendingRequest = Request(destination: destination)
    }
}

enum CampusQuickAction: String, AppEnum {
    case attendance
    case library

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "校園快捷功能" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.attendance: "快速點名", .library: "圖書館 QR Code"]
    }

    var destination: CampusDestination { self == .attendance ? .attendance : .library }
    var title: String { self == .attendance ? "快速點名" : "圖書館 QR Code" }
    var symbol: String { self == .attendance ? "qrcode.viewfinder" : "qrcode" }
    var subtitle: String { self == .attendance ? "開啟相機掃描點名" : "開啟圖書館通行碼" }
}

/// Target membership must include the app so the foreground intent uses its router.
struct OpenCampusIntent: OpenIntent {
    static var title: LocalizedStringResource { "開啟校園功能" }
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "功能") var target: CampusQuickAction

    init() {}
    init(_ target: CampusQuickAction) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        CampusRouter.shared.open(target.destination)
        return .result()
    }
}
