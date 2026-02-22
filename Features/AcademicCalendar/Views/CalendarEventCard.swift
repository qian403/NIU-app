import SwiftUI

struct CalendarEventCard: View {
    let event: CalendarEvent
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.medium) {
                // 左側日期
                dateIndicator
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Colors.primary)
                        .lineLimit(2)
                    
                    if let description = event.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(Theme.Colors.secondaryText)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(eventTypeColor)
                            .frame(width: 7, height: 7)
                        Text(event.inferredType.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(eventTypeColor)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1),
                alignment: .bottom
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Components
    
    private var dateIndicator: some View {
        VStack(spacing: 2) {
            if let date = event.start {
                Text(weekdayString(from: date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Colors.tertiaryText)
                Text(dayString(from: date))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(Theme.Colors.primary)
                Text(monthString(from: date))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(eventTypeColor)
            }
        }
        .frame(width: 52)
    }
    
    // MARK: - Helper Properties
    
    private var eventTypeColor: Color {
        switch event.inferredType {
        case .registration: return .blue
        case .exam: return .red
        case .holiday: return .green
        case .important: return .orange
        case .semester: return .purple
        case .activity: return .cyan
        case .deadline: return .pink
        }
    }
    
    // MARK: - Helper Methods
    
    private func monthString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月"
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter.string(from: date)
    }
    
    private func weekdayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter.string(from: date)
    }

    private func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd"
        return formatter.string(from: date)
    }
}

// MARK: - Event Detail Sheet

struct CalendarEventDetailSheet: View {
    let event: CalendarEvent
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    // 日期區塊
                    dateSection
                    
                    Divider()
                    
                    // 事件資訊
                    eventInfoSection
                    
                    Divider()
                    
                    // 描述
                    if let description = event.description, !description.isEmpty {
                        descriptionSection(description)
                    }
                }
                .padding()
            }
            .navigationTitle("活動詳情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var dateSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label("日期", systemImage: "calendar")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Colors.tertiaryText)
            
            HStack {
                if let start = event.start {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("開始")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Theme.Colors.tertiaryText)
                        Text(fullDateString(from: start))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.Colors.primary)
                    }
                    
                    if event.isMultiDay, let end = event.end {
                        Image(systemName: "arrow.right")
                            .foregroundColor(Theme.Colors.tertiaryText)
                            .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("結束")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(Theme.Colors.tertiaryText)
                            Text(fullDateString(from: end))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Theme.Colors.primary)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
        }
    }
    
    private var eventInfoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(event.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.Colors.primary)
            
            HStack(spacing: 8) {
                Image(systemName: event.inferredType.icon)
                    .font(.system(size: 14))
                Text(event.inferredType.rawValue)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(eventTypeColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(eventTypeColor.opacity(0.15))
            )
        }
    }
    
    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label("說明", systemImage: "doc.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Colors.tertiaryText)
            
            Text(description)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Theme.Colors.primary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }
    
    private var eventTypeColor: Color {
        switch event.inferredType {
        case .registration: return .blue
        case .exam: return .red
        case .holiday: return .green
        case .important: return .orange
        case .semester: return .purple
        case .activity: return .cyan
        case .deadline: return .pink
        }
    }
    
    private func fullDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年MM月dd日"
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter.string(from: date)
    }
}

// MARK: - Preview Data

#Preview {
    VStack(spacing: 16) {
        CalendarEventCard(
            event: CalendarEvent(
                id: "1",
                title: "開學日",
                description: "114學年度第1學期開始上課",
                startDate: "2024-09-09",
                endDate: nil,
                type: .semester
            ),
            onTap: {}
        )
        
        CalendarEventCard(
            event: CalendarEvent(
                id: "2",
                title: "期中考試",
                description: "期中考試週",
                startDate: "2024-11-04",
                endDate: "2024-11-08",
                type: .exam
            ),
            onTap: {}
        )
        
        CalendarEventCard(
            event: CalendarEvent(
                id: "3",
                title: "元旦連假",
                description: nil,
                startDate: "2025-01-01",
                endDate: "2025-01-01",
                type: .holiday
            ),
            onTap: {}
        )
    }
    .padding()
}
