//
//  AppIntent.swift
//  NIU-LiveActivities
//
//  Created by CHIEN on 2026/4/4.
//

import WidgetKit
import AppIntents

enum WidgetContentType: String, AppEnum {
    case classSchedule
    case academicCalendar
    case weeklyTimetable

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "小工具內容"
    }

    static var caseDisplayRepresentations: [WidgetContentType: DisplayRepresentation] {
        [
            .classSchedule: "當日課表",
            .academicCalendar: "行事曆",
            .weeklyTimetable: "完整課表"
        ]
    }
}

enum CompactWidgetContentType: String, AppEnum {
    case classSchedule
    case academicCalendar

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "小工具內容"
    }

    static var caseDisplayRepresentations: [CompactWidgetContentType: DisplayRepresentation] {
        [
            .classSchedule: "當日課表",
            .academicCalendar: "行事曆"
        ]
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "NIU 小工具設定" }
    static var description: IntentDescription { "選擇顯示當日課表、學年行事曆或完整課表" }

    @Parameter(title: "顯示內容", default: .classSchedule)
    var contentType: WidgetContentType
}

struct CompactConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "NIU 小工具設定" }
    static var description: IntentDescription { "選擇顯示當日課表或學年行事曆" }

    @Parameter(title: "顯示內容", default: .classSchedule)
    var contentType: CompactWidgetContentType
}

extension CompactWidgetContentType {
    var widgetContentType: WidgetContentType {
        switch self {
        case .classSchedule:
            return .classSchedule
        case .academicCalendar:
            return .academicCalendar
        }
    }
}
