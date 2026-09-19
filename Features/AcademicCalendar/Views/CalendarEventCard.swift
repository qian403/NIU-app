import SwiftUI

extension CalendarEventType {
    var tint: Color {
        switch self {
        case .registration: return .blue
        case .exam: return .red
        case .holiday: return .green
        case .important: return .orange
        case .semester: return .purple
        case .activity: return .teal
        case .deadline: return .pink
        case .academic: return .indigo
        }
    }
}

struct CalendarEventCard: View {
    let event: CalendarEvent
    var context: String? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(event.type.tint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    Label(context.map { "\(event.type.rawValue) · \($0)" } ?? event.type.rawValue, systemImage: event.type.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(event.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dateLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let note = event.description, !note.isEmpty, note != event.title {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看事件詳情與校方原文")
    }

    private var dateLabel: String {
        guard let start = event.start else { return event.dateString }
        let first = CampusCalendarDate.format(start, "M/d（E）")
        guard event.isMultiDay, let end = event.end else { return first }
        return "\(first) – \(CampusCalendarDate.format(end, "M/d（E）"))"
    }
}

struct CalendarEventDetailSheet: View {
    let event: CalendarEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(event.type.rawValue, systemImage: event.type.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(event.type.tint)
                        Text(event.displayTitle)
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    dateSection
                    if let description = event.description, !description.isEmpty {
                        textSection("說明", text: description)
                    }
                    if let sourceText = event.sourceText, !sourceText.isEmpty {
                        textSection("校方原文", text: sourceText)
                    }
                    if let url = event.sourceURL {
                        Link(destination: url) {
                            HStack {
                                Label("查看校方行事曆 PDF", systemImage: "doc.text")
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(16)
                            .frame(minHeight: 44)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .tint(.primary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("事件詳情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .background(Theme.Colors.background)
        }
        .presentationDragIndicator(.visible)
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("日期", systemImage: "calendar")
                .font(.subheadline).foregroundStyle(.secondary)
            if let start = event.start {
                Text(CampusCalendarDate.format(start, "yyyy年M月d日 EEEE"))
                    .font(.headline)
                if event.isMultiDay, let end = event.end {
                    Text("至 \(CampusCalendarDate.format(end, "yyyy年M月d日 EEEE"))")
                        .font(.headline)
                    Text("含開始與結束當天")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func textSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(text).font(.body).textSelection(.enabled)
        }
    }
}

#Preview {
    CalendarEventDetailSheet(event: CalendarEvent(
        id: "preview", title: "第二學期期末考試", description: "請依各課程公告的考試時間應試。",
        startDate: "2027-06-21", endDate: "2027-06-27", type: .exam
    ))
}
