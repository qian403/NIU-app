import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟隨系統"
        case .light: return "淺色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Theme {
    
    enum Colors {
        static let primary = Color.primary
        static let background = Color(.systemBackground)
        static let secondaryText = Color.secondary
        static let tertiaryText = Color.secondary.opacity(0.8)
        static let border = Color(.separator)
        static let lightBorder = Color(.separator).opacity(0.7)
    }
    
    enum Spacing {
        static let xsmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xlarge: CGFloat = 40
        static let xxlarge: CGFloat = 48
    }
    
    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xlarge: CGFloat = 26
    }
    
    enum Typography {
        static func title(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(Colors.primary)
        }
        
        static func heading(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Colors.primary)
        }
        
        static func body(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Colors.primary)
        }
        
        static func caption(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 14, weight: .light))
                .foregroundColor(Colors.secondaryText)
        }
        
        static func small(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 12, weight: .light))
                .foregroundColor(Colors.tertiaryText)
        }
    }
    
    enum Shadow {
        static let light = Color.primary.opacity(0.05)
        static let medium = Color.primary.opacity(0.1)
        static let heavy = Color.primary.opacity(0.2)
    }
}
