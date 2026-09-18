import SwiftUI

// MARK: - Card Component

struct NIUCard<Content: View>: View {
    let content: Content

    init(
        cornerRadius: CGFloat = Theme.CornerRadius.large,
        shadow: ShadowStyle = Theme.Shadow.small,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    private let cornerRadius: CGFloat
    private let shadow: ShadowStyle

    var body: some View {
        content
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .cardShadow(shadow)
    }
}

// MARK: - Glass Card Component

struct NIUGlassCard<Content: View>: View {
    let content: Content

    init(
        cornerRadius: CGFloat = Theme.CornerRadius.large,
        material: Material = .regularMaterial,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.material = material
    }

    private let cornerRadius: CGFloat
    private let material: Material

    var body: some View {
        content
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(material)
            )
    }
}

// MARK: - Primary Button

struct NIUButton: View {
    let title: String
    let icon: String?
    let isLoading: Bool
    let action: () -> Void

    @State private var isPressed = false

    init(
        _ title: String,
        icon: String? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.small) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.85)
                } else {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                    }
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
            )
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(Theme.Animation.fast, value: isPressed)
        }
        .buttonStyle(PressableButtonStyle(isPressed: $isPressed))
    }
}

// MARK: - Secondary Button

struct NIUSecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    @State private var isPressed = false

    init(
        _ title: String,
        icon: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xsmall) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(Theme.Animation.fast, value: isPressed)
        }
        .buttonStyle(PressableButtonStyle(isPressed: $isPressed))
    }
}

// MARK: - Icon Button

struct NIUIconButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    init(
        _ icon: String,
        size: CGFloat = 44,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                )
        }
    }
}

// MARK: - Pressable Button Style

struct PressableButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

// MARK: - Modern Text Field

struct NIUTextField: View {
    let placeholder: String
    let icon: String?
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default

    @FocusState private var isFocused: Bool
    @State private var isPasswordVisible = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(isFocused ? Color.accentColor : Color(.tertiaryLabel))
                    .frame(width: 20)
            }

            if isSecure && !isPasswordVisible {
                SecureField(placeholder, text: $text)
                    .textContentType(.password)
                    .focused($isFocused)
            } else {
                TextField(placeholder, text: $text)
                    .textContentType(isSecure ? .password : .username)
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .focused($isFocused)
            }

            if isSecure {
                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .animation(Theme.Animation.fast, value: isFocused)
    }
}

/// Shared status for academic records saved on this device.
struct AcademicRefreshFooter: View {
    let lastUpdated: Date?
    let isRefreshing: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在更新資料…")
                }
            } else {
                Label("下拉即可更新", systemImage: "arrow.down")
            }
            if let lastUpdated {
                Text("上次更新：\(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                Text("資料已儲存在此裝置")
            }
            if let errorMessage {
                Text("更新失敗，目前保留上次資料。\n\(errorMessage)")
                    .foregroundStyle(.orange)
                Button("重新整理", action: onRetry)
                    .disabled(isRefreshing)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Chip Component

struct NIUChip: View {
    let text: String
    let icon: String?
    let style: ChipStyle

    enum ChipStyle {
        case filled
        case outlined
        case accent
    }

    init(_ text: String, icon: String? = nil, style: ChipStyle = .outlined) {
        self.text = text
        self.icon = icon
        self.style = style
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: style == .outlined ? 0.5 : 0)
        )
    }

    private var foregroundColor: Color {
        switch style {
        case .filled: return .white
        case .outlined: return Color(.secondaryLabel)
        case .accent: return .white
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .filled: return Color(.systemGray)
        case .outlined: return Color.clear
        case .accent: return Color.accentColor
        }
    }

    private var borderColor: Color {
        switch style {
        case .outlined: return Color(.separator)
        default: return Color.clear
        }
    }
}

// MARK: - Avatar Component

struct NIUAvatar: View {
    let name: String
    let size: AvatarSize

    enum AvatarSize {
        case small, medium, large

        var dimension: CGFloat {
            switch self {
            case .small: return 32
            case .medium: return 48
            case .large: return 64
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .small: return 12
            case .medium: return 18
            case .large: return 24
            }
        }
    }

    init(_ name: String, size: AvatarSize = .medium) {
        self.name = name
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: size.dimension, height: size.dimension)

            Text(initials)
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        let components = name.components(separatedBy: " ")
        let firstInitial = components.first?.first.map(String.init) ?? ""
        let lastInitial = components.count > 1 ? components.last?.first.map(String.init) ?? "" : ""
        return (firstInitial + lastInitial).uppercased()
    }

    private var avatarGradient: LinearGradient {
        let colors: [Color] = [
            Color.accentColor,
            Color.accentColor.opacity(0.7)
        ]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Section Header

struct NIUSectionHeader: View {
    let title: String
    let icon: String?
    let action: (() -> Void)?

    init(
        _ title: String,
        icon: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        HStack {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(.label))

            Spacer()

            if let action = action {
                Button("See All", action: action)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

// MARK: - Status Badge

struct NIUStatusBadge: View {
    let status: StatusType

    enum StatusType {
        case success(String)
        case warning(String)
        case error(String)
        case info(String)

        var color: Color {
            switch self {
            case .success: return Color(.systemGreen)
            case .warning: return Color(.systemOrange)
            case .error: return Color(.systemRed)
            case .info: return Color(.systemBlue)
            }
        }

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var text: String {
            switch self {
            case .success(let msg), .warning(let msg), .error(let msg), .info(let msg):
                return msg
            }
        }
    }

    init(_ status: StatusType) {
        self.status = status
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 12, weight: .medium))
            Text(status.text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(status.color.opacity(0.12))
        )
    }
}

// MARK: - Empty State

struct NIUEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let action: (() -> Void)?
    let actionTitle: String?

    init(
        icon: String,
        title: String,
        message: String,
        action: (() -> Void)? = nil,
        actionTitle: String? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
        self.actionTitle = actionTitle
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(Color(.tertiaryLabel))

            VStack(spacing: Theme.Spacing.xsmall) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(.label))

                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
            }

            if let action = action, let actionTitle = actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .padding(.top, Theme.Spacing.small)
            }
        }
        .padding(Theme.Spacing.xlarge)
    }
}

// MARK: - Loading State

struct NIULoadingState: View {
    let message: String

    init(_ message: String = "載入中...") {
        self.message = message
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            ProgressView()
                .scaleEffect(1.2)

            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
        }
    }
}

// MARK: - Quick Actions Grid

struct NIUQuickAction: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
}

struct NIUQuickActionsGrid: View {
    let actions: [NIUQuickAction]

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.medium),
        GridItem(.flexible(), spacing: Theme.Spacing.medium)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.medium) {
            ForEach(actions) { action in
                QuickActionCell(action: action)
            }
        }
    }
}

private struct QuickActionCell: View {
    let action: NIUQuickAction

    var body: some View {
        Button(action: action.action) {
            VStack(spacing: Theme.Spacing.small) {
                ZStack {
                    Circle()
                        .fill(action.color.opacity(0.12))
                        .frame(width: 52, height: 52)

                    Image(systemName: action.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(action.color)
                }

                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}
