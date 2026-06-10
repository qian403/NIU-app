import Foundation

// MARK: - Graduation Data

struct GraduationData: Codable {
    let diverseHours: [String]   // 8 numbers: [服務已修, 服務應修, 多元已修, 多元應修, 專業已修, 專業應修, 綜合已修, 綜合應修]
    let englishAbility: String
    let physicalFitness: String
    let creditRequired: [String] // 2 values: [應修學分總數, 已修學分]
    let creditCourse: String
}

// MARK: - Cached Graduation Data

/// Cache envelope around the scraped `GraduationData`. `GraduationData` itself
/// is decoded directly from the scraper's JSON, so the fetch timestamp lives
/// here rather than on the payload.
struct CachedGraduationData: Codable {
    let data: GraduationData
    let fetchedAt: Date

    /// Returns true if the cache is still within the 7-day TTL
    var isCacheValid: Bool {
        Date().timeIntervalSince(fetchedAt) < 7 * 24 * 3600
    }
}

// MARK: - Diverse Hours Category

enum DiverseHoursCategory: String, CaseIterable {
    case service = "服務"
    case diverse = "多元"
    case major = "專業"
    case complex = "綜合"

    var localizedKey: String {
        switch self {
        case .service: return "Diverse_Hours_Services"
        case .diverse: return "Diverse_Hours_Diverse"
        case .major: return "Diverse_Hours_Major"
        case .complex: return "Diverse_Hours_Complex"
        }
    }
}
