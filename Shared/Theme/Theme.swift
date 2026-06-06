import SwiftUI

// MARK: - Appearance Mode

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

// MARK: - Design System

enum Theme {

    // MARK: Colors
    enum Colors {
        // Semantic
        static let primary = Color.primary
        static let background = Color(.systemBackground)
        static let secondaryBackground = Color(.secondarySystemBackground)
        static let tertiaryBackground = Color(.tertiarySystemBackground)
        static let groupedBackground = Color(.systemGroupedBackground)

        // Text
        static let label = Color(.label)
        static let secondaryLabel = Color(.secondaryLabel)
        static let tertiaryLabel = Color(.tertiaryLabel)
        static let quaternaryLabel = Color(.quaternaryLabel)

        // Separator
        static let separator = Color(.separator)
        static let opaqueSeparator = Color(.opaqueSeparator)

        // Fills
        static let fill = Color(.systemFill)
        static let secondaryFill = Color(.secondarySystemFill)
        static let tertiaryFill = Color(.tertiarySystemFill)
        static let quaternaryFill = Color(.quaternarySystemFill)

        // Accent
        static let accent = Color.accentColor
        static let accentSoft = Color.accentColor.opacity(0.12)
        static let accentMedium = Color.accentColor.opacity(0.25)

        // Status
        static let success = Color(.systemGreen)
        static let warning = Color(.systemOrange)
        static let error = Color(.systemRed)
        static let info = Color(.systemBlue)

        // Legacy aliases
        static let secondaryText = Color(.secondaryLabel)
        static let tertiaryText = Color(.tertiaryLabel)
        static let border = Color(.separator)
        static let lightBorder = Color(.separator).opacity(0.7)
    }

    // MARK: Spacing
    enum Spacing {
        static let xxsmall: CGFloat = 4
        static let xsmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xlarge: CGFloat = 32
        static let xxlarge: CGFloat = 48
    }

    // MARK: Corner Radius
    enum CornerRadius {
        static let xsmall: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 18
        static let xlarge: CGFloat = 24
        static let xxlarge: CGFloat = 32
        static let pill: CGFloat = 999
    }

    // MARK: Typography
    enum Typography {
        // Display
        static func largeTitle(_ text: String) -> some View {
            Text(text)
                .font(.largeTitle.bold())
                .foregroundStyle(Colors.label)
        }

        static func title(_ text: String) -> some View {
            Text(text)
                .font(.title.bold())
                .foregroundStyle(Colors.label)
        }

        static func title2(_ text: String) -> some View {
            Text(text)
                .font(.title2.semibold())
                .foregroundStyle(Colors.label)
        }

        static func title3(_ text: String) -> some View {
            Text(text)
                .font(.title3.semibold())
                .foregroundStyle(Colors.label)
        }

        // Body
        static func heading(_ text: String) -> some View {
            Text(text)
                .font(.headline)
                .foregroundStyle(Colors.label)
        }

        static func body(_ text: String) -> some View {
            Text(text)
                .font(.body)
                .foregroundStyle(Colors.label)
        }

        static func callout(_ text: String) -> some View {
            Text(text)
                .font(.callout)
                .foregroundStyle(Colors.label)
        }

        static func subheadline(_ text: String) -> some View {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Colors.secondaryLabel)
        }

        // Small
        static func caption(_ text: String) -> some View {
            Text(text)
                .font(.caption)
                .foregroundStyle(Colors.secondaryLabel)
        }

        static func caption2(_ text: String) -> some View {
            Text(text)
                .font(.caption2)
                .foregroundStyle(Colors.tertiaryLabel)
        }

        // Legacy
        static func small(_ text: String) -> some View {
            Text(text)
                .font(.caption2)
                .foregroundStyle(Colors.tertiaryLabel)
        }
    }

    // MARK: Shadow
    enum Shadow {
        static let xsmall = ShadowStyle(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        static let small = ShadowStyle(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        static let medium = ShadowStyle(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        static let large = ShadowStyle(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
        static let xlarge = ShadowStyle(color: .black.opacity(0.16), radius: 40, x: 0, y: 16)

        // Legacy
        static let light = Color.primary.opacity(0.05)
        static let heavy = Color.primary.opacity(0.2)
    }

    // MARK: Animation
    enum Animation {
        static let fast = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.8)
        static let standard = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.8)
        static let slow = SwiftUI.Animation.spring(response: 0.5, dampingFraction: 0.85)
        static let bounce = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.65)
        static let easeOut = SwiftUI.Animation.easeOut(duration: 0.25)
        static let easeInOut = SwiftUI.Animation.easeInOut(duration: 0.3)
    }
}

// MARK: - Shadow Style

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - View Extensions

extension View {
    func cardShadow(_ style: ShadowStyle = Theme.Shadow.small) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    func glassBackground(
        cornerRadius: CGFloat = Theme.CornerRadius.large,
        material: Material = .regularMaterial
    ) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(material)
        )
    }

    func cardBackground(
        cornerRadius: CGFloat = Theme.CornerRadius.large,
        shadow: ShadowStyle = Theme.Shadow.small
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .cardShadow(shadow)
    }

    func subtleBorder(
        cornerRadius: CGFloat = Theme.CornerRadius.large,
        opacity: Double = 0.08
    ) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(opacity), lineWidth: 0.5)
        )
    }
}

// MARK: - Font Extensions

extension Font {
    func semibold() -> Font {
        self.weight(.semibold)
    }
}
