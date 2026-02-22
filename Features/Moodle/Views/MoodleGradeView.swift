import SwiftUI

struct MoodleGradeView: View {
    let items: [MoodleGradeItem]
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    GradeItemRow(item: item)
                }
            }
        }
    }
}

private struct GradeItemRow: View {
    let item: MoodleGradeItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Item name
            HStack(spacing: 6) {
                if let module = item.itemmodule {
                    Image(systemName: iconFor(module))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Text(cleanTitle)
                    .font(.system(size: 14, weight: item.isCategory ? .semibold : .regular))
                    .foregroundColor(.primary)
            }
            
            // Grade details in a grid
            HStack(spacing: 0) {
                gradeColumn(label: "成績", value: cleanGradeText)
                gradeColumn(label: "範圍", value: rangeText)
                gradeColumn(label: "百分比", value: item.percentageformatted?.htmlDecoded ?? "-")
                gradeColumn(label: "權重", value: item.weightformatted?.htmlDecoded ?? "-")
                gradeColumn(label: "貢獻", value: item.contributiontocoursetotal?.htmlDecoded ?? "-")
            }
            
            // Feedback
            if let feedback = item.cleanFeedback, !feedback.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(feedback)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(item.isCategory ? Color.primary.opacity(0.04) : Color(.systemBackground))
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var cleanTitle: String {
        (item.itemname ?? (item.itemtype == "course" ? "課程總分" : "分類")).htmlDecoded
    }

    private var cleanGradeText: String {
        let raw = item.gradeformatted?.htmlDecoded ?? "-"
        let cleaned = raw.replacingOccurrences(
            of: "<[^\\n]*",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "-" : cleaned
    }

    private var rangeText: String {
        if let range = item.rangeformatted?.htmlDecoded, !range.isEmpty {
            return range
        }
        guard let min = item.grademin, let max = item.grademax else { return "-" }
        return "\(formatGrade(min))–\(formatGrade(max))"
    }

    private func formatGrade(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func gradeColumn(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconFor(_ module: String) -> String {
        switch module {
        case "assign": return "doc.text"
        case "quiz": return "questionmark.circle"
        case "forum": return "bubble.left"
        default: return "square"
        }
    }
}
