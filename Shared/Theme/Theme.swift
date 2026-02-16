import SwiftUI

enum Theme {
    
    enum Colors {
        static let primary = Color.black
        static let background = Color.white
        static let secondaryText = Color.black.opacity(0.6)
        static let tertiaryText = Color.black.opacity(0.4)
        static let border = Color.black.opacity(0.2)
        static let lightBorder = Color.black.opacity(0.1)
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
        static let light = Color.black.opacity(0.05)
        static let medium = Color.black.opacity(0.1)
        static let heavy = Color.black.opacity(0.2)
    }
}
