import AppIntents
import SwiftUI
import WidgetKit

struct CampusQuickAccessConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "校園快捷設定" }
    static var description: IntentDescription { "選擇點一下要開啟的功能。" }

    @Parameter(title: "開啟功能", default: .attendance)
    var action: CampusQuickAction
}

struct CampusQuickAccessEntry: TimelineEntry {
    let date: Date
    let action: CampusQuickAction
}

struct CampusQuickAccessProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CampusQuickAccessEntry {
        .init(date: .now, action: .attendance)
    }

    func snapshot(for configuration: CampusQuickAccessConfiguration, in context: Context) async -> CampusQuickAccessEntry {
        .init(date: .now, action: configuration.action)
    }

    func timeline(for configuration: CampusQuickAccessConfiguration, in context: Context) async -> Timeline<CampusQuickAccessEntry> {
        Timeline(entries: [await snapshot(for: configuration, in: context)], policy: .never)
    }
}

struct CampusQuickAccessView: View {
    let entry: CampusQuickAccessEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: entry.action.symbol)
                        .font(.title2)
                }
                .accessibilityLabel(entry.action.title)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 4) {
                    Label(entry.action.title, systemImage: entry.action.symbol)
                        .font(.headline)
                    Text(entry.action.subtitle)
                        .font(.caption)
                }
            case .accessoryInline:
                Label(entry.action.title, systemImage: entry.action.symbol)
            case .systemMedium:
                HStack(spacing: 12) {
                    actionLink(.attendance)
                    actionLink(.library)
                }
            default:
                actionTile(entry.action)
            }
        }
        .widgetURL(entry.action.destination.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func actionLink(_ action: CampusQuickAction) -> some View {
        Link(destination: action.destination.url) { actionTile(action) }
            .buttonStyle(.plain)
    }

    private func actionTile(_ action: CampusQuickAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(action == .attendance ? Color.blue : Color.green)
                .widgetAccentable()
            Spacer(minLength: 0)
            Text(action.title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(action.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(4)
        .accessibilityElement(children: .combine)
    }
}

struct CampusQuickAccessWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NIU_CampusQuickAccess", intent: CampusQuickAccessConfiguration.self,
                               provider: CampusQuickAccessProvider()) { entry in
            CampusQuickAccessView(entry: entry)
        }
        .configurationDisplayName("NIU 校園快捷")
        .description("快速開啟點名或圖書館 QR Code。中型同時顯示兩個入口；小型與鎖定畫面可選擇功能。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .systemMedium) {
    CampusQuickAccessWidget()
} timeline: {
    CampusQuickAccessEntry(date: .now, action: .attendance)
}
