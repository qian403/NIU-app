import AppIntents
import SwiftUI
import WidgetKit

struct AttendanceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.chienniuapp.control.attendance") {
            ControlWidgetButton(action: OpenCampusIntent(.attendance)) {
                Label("快速點名", systemImage: "qrcode.viewfinder")
            }
        }
        .displayName("快速點名")
        .description("開啟 NIU App，相機掃描 M 園區點名 QR Code。")
    }
}

struct LibraryCodeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.chienniuapp.control.library") {
            ControlWidgetButton(action: OpenCampusIntent(.library)) {
                Label("圖書館 QR Code", systemImage: "qrcode")
            }
        }
        .displayName("圖書館 QR Code")
        .description("開啟 NIU App 顯示圖書館通行碼。")
    }
}
