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

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "小工具內容"
    }

    static var caseDisplayRepresentations: [WidgetContentType: DisplayRepresentation] {
        [
            .classSchedule: "課表",
            .academicCalendar: "行事曆"
        ]
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "NIU 小工具設定" }
    static var description: IntentDescription { "選擇顯示課表或學年行事曆" }

    @Parameter(title: "顯示內容", default: .classSchedule)
    var contentType: WidgetContentType
}
