import Foundation

/// 課表「當前第幾週」的判定結果。App 與 Widget 共用，無 UI、無儲存、不含個資。
nonisolated struct AcademicWeekInfo: Equatable, Sendable {
    /// 民國學年度。
    let academicYear: Int
    /// 學期（1 或 2）。
    let semester: Int
    /// 週別：teaching／preparation／winter／summer。
    let kind: String
    /// 教學／寒假／暑假的週次；預備週為 nil。
    let number: Int?
    /// 校方原文標籤，例如「八」「暑六」「寒一」「預備週」。
    let label: String

    /// 週數顯示片段：教學週用「第 N 週」，其餘（暑假、寒假、預備週）用校方原文 label，
    /// 避免把「暑六」這類標籤顯示成會誤解的「第 6 週」。
    var weekText: String {
        if kind == "teaching", let number { return "第 \(number) 週" }
        return label
    }
}

/// 以校方逐週表（calendar-data 的 `weeks[]`）判定日期落在哪一週。
/// 直接查逐週表，而非用開學日除以 7，才能正確處理寒暑假與預備週。
nonisolated enum AcademicWeekResolver {
    /// 找出 `date`（以 Asia/Taipei 當日判定）落在 `document.weeks` 的哪一筆。
    /// 無資料（document 為 nil）或日期不在該年度逐週表範圍內時回傳 nil，交由呼叫端留白。
    static func week(for date: Date, in document: CampusCalendarDocument?) -> AcademicWeekInfo? {
        guard let document else { return nil }
        let key = CampusCalendarDate.dayKey(date)
        guard let week = document.weeks.first(where: { $0.startDate <= key && key <= $0.endDate }) else { return nil }
        return AcademicWeekInfo(academicYear: document.academicYear, semester: week.semester,
                                kind: week.kind, number: week.number, label: week.label)
    }
}
