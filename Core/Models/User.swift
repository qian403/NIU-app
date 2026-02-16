import Foundation

struct User: Identifiable, Codable, Equatable {
    let id: UUID
    let username: String
    let name: String
    var email: String?
    var avatarURL: String?
    var department: String?
    var grade: String?
    
    init(
        id: UUID = UUID(),
        username: String,
        name: String,
        email: String? = nil,
        avatarURL: String? = nil,
        department: String? = nil,
        grade: String? = nil
    ) {
        self.id = id
        self.username = username
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
        self.department = department
        self.grade = grade
    }
}
