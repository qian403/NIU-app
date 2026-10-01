import SwiftUI

// MARK: - Formatting

/// 設備預約畫面共用的文字格式；日期時間一律依圖書館系統的 Asia/Taipei 曆法。
enum LibraryEquipmentText {
    static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func hours(minutes: Int) -> String {
        hours(Double(minutes) / 60)
    }

    static func dateTime(_ date: Date) -> String {
        LibraryEquipmentDate.format(date, pattern: "yyyy/MM/dd HH:mm")
    }

    /// 「星期三」→「週三」。
    static func shortWeekday(_ date: Date) -> String {
        "週" + String(LibraryEquipmentDate.weekday(date).suffix(1))
    }

    static func relativeDay(_ date: Date, now: Date = Date()) -> String? {
        let today = LibraryEquipmentDate.day(now)
        let day = LibraryEquipmentDate.day(date)
        switch LibraryEquipmentDate.calendar.dateComponents([.day], from: today, to: day).day {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "後天"
        default: return nil
        }
    }

    /// 例如「今天 · 10/1（週四）」。
    static func dayTitle(_ date: Date) -> String {
        let base = "\(LibraryEquipmentDate.format(date, pattern: "M/d"))（\(shortWeekday(date))）"
        guard let relative = relativeDay(date) else { return base }
        return "\(relative) · \(base)"
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        let endPattern = LibraryEquipmentDate.day(start) == LibraryEquipmentDate.day(end) ? "HH:mm" : "MM/dd HH:mm"
        return "\(LibraryEquipmentDate.format(start, pattern: "HH:mm"))–\(LibraryEquipmentDate.format(end, pattern: endPattern))"
    }
}

// MARK: - Section card

/// 帶步驟編號的區塊卡片；右側可放置輔助控制項（例如日期選擇器）。
struct LibraryEquipmentCard<Content: View, Accessory: View>: View {
    let step: Int?
    let title: String
    let subtitle: String?
    let content: Content
    let accessory: Accessory

    init(step: Int? = nil, title: String, subtitle: String? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.step = step
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Spacing.small) {
                    heading
                    Spacer(minLength: Theme.Spacing.xsmall)
                    accessory
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                    heading
                    accessory
                }
            }
            content
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xsmall) {
            if let step {
                Text("\(step)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.accentColor, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headingAccessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    private var headingAccessibilityLabel: String {
        var parts: [String] = []
        if let step { parts.append("步驟 \(step)") }
        parts.append(title)
        if let subtitle { parts.append(subtitle) }
        return parts.joined(separator: "，")
    }
}

extension LibraryEquipmentCard where Accessory == EmptyView {
    init(step: Int? = nil, title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(step: step, title: title, subtitle: subtitle, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Selection chip

/// 可選取的選項按鈕；選取狀態同時以勾號、外框與顏色表達。
struct LibraryEquipmentChip: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isSelected ? Theme.Colors.accentSoft : Theme.Colors.tertiaryFill, in: shape)
            .overlay { shape.strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
    }
}

// MARK: - Status banner

enum LibraryEquipmentBannerStyle {
    case success, warning, error

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return Theme.Colors.success
        case .warning: return Theme.Colors.warning
        case .error: return Theme.Colors.error
        }
    }

    var accessibilityName: String {
        switch self {
        case .success: return "完成"
        case .warning: return "注意"
        case .error: return "錯誤"
        }
    }
}

/// 成功、提醒與錯誤訊息；圖示帶無障礙名稱，不只靠顏色區分。
struct LibraryEquipmentBanner<Actions: View>: View {
    let style: LibraryEquipmentBannerStyle
    let message: String
    let actions: Actions

    init(_ style: LibraryEquipmentBannerStyle, message: String, @ViewBuilder actions: () -> Actions) {
        self.style = style
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
                .accessibilityLabel(style.accessibilityName)
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.CornerRadius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension LibraryEquipmentBanner where Actions == EmptyView {
    init(_ style: LibraryEquipmentBannerStyle, message: String) {
        self.init(style, message: message) { EmptyView() }
    }
}
