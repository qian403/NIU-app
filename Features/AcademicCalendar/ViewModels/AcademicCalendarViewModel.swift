import Foundation
import Combine

class AcademicCalendarViewModel: ObservableObject {
    
    @Published var calendarData: AcademicCalendarData?
    @Published var currentSemester: String = ""
    @Published var selectedMonth: Int?
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // 當前學期的行事曆
    var currentCalendar: SemesterCalendar? {
        calendarData?.calendar(for: currentSemester)
    }
    
    // 當前月份的事件
    var eventsForSelectedMonth: [CalendarEvent] {
        guard let month = selectedMonth,
              let calendar = currentCalendar else {
            return []
        }
        return calendar.eventsByMonth[month] ?? []
    }
    
    // 所有事件（按日期排序）
    var allEvents: [CalendarEvent] {
        currentCalendar?.events.sorted { 
            ($0.start ?? Date()) < ($1.start ?? Date())
        } ?? []
    }
    
    // 即將到來的事件（未來30天內）
    var upcomingEvents: [CalendarEvent] {
        let now = Date()
        let thirtyDaysLater = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        
        return allEvents.filter { event in
            if let startDate = event.start {
                return startDate >= now && startDate <= thirtyDaysLater
            }
            return false
        }
    }
    
    init() {
        // 設置預設學期為當前學期
        // 學年度從8月1日開始，所以需要特別處理
        let now = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        
        // 轉換為民國年
        let rocYear = currentYear - 1911
        
        // 判斷學期：8月到隔年1月是第1學期，2月到7月是第2學期
        let (academicYear, semester) = if currentMonth >= 8 {
            // 8月之後是新學年度第1學期
            (rocYear, 1)
        } else if currentMonth >= 2 {
            // 2-7月是上一學年度第2學期
            (rocYear - 1, 2)
        } else {
            // 1月還是上一學年度第1學期
            (rocYear - 1, 1)
        }
        
        currentSemester = "\(academicYear)-\(semester)"
        print("[Calendar] 當前學期: \(currentSemester) (\(currentYear)年\(currentMonth)月)")
    }
    
    // MARK: - Data Loading
    
    /// 從遠端 URL 載入 JSON 資料（例如 GitHub Raw URL）
    func loadFromURL(_ urlString: String) {
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: urlString) else {
            errorMessage = "無效的 URL"
            isLoading = false
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    self.errorMessage = "載入失敗: \(error.localizedDescription)"
                    self.isLoading = false
                    // 失敗時嘗試本地檔案
                    self.loadFromLocalFile()
                    return
                }
                
                guard let data = data else {
                    self.errorMessage = "無資料"
                    self.isLoading = false
                    self.loadFromLocalFile()
                    return
                }
                
                self.parseCalendarData(data)
            }
        }.resume()
    }
    
    /// 從 Firebase 載入 JSON 資料
    func loadFromFirebase() {
        // TODO: 實現 Firebase 載入功能
        // 暫時使用預設 URL 載入（GitHub Raw URL）
        print("[Calendar] Firebase 尚未實作，改用 GitHub URL 載入")
        loadFromDefaultURL()
    }
    
    /// 從預設 URL 載入（優先使用 Firebase）
    func loadFromDefaultURL() {
        // Firebase Realtime Database URL - 直接讀取 114 學年度資料
        let firebaseURL = "https://niu-life-a889d-default-rtdb.asia-southeast1.firebasedatabase.app/%E5%AD%B8%E5%B9%B4%E5%BA%A6%E8%A1%8C%E4%BA%8B%E6%9B%86/114.json"
        loadFromFirebaseURL(firebaseURL)
    }
    
    /// 從 Firebase URL 載入
    private func loadFromFirebaseURL(_ urlString: String) {
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: urlString) else {
            errorMessage = "無效的 URL"
            isLoading = false
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    self.errorMessage = "載入失敗: \(error.localizedDescription)"
                    self.isLoading = false
                    print("[Calendar] Firebase 載入失敗，嘗試本地資料")
                    self.loadFromLocalFile()
                    return
                }
                
                guard let data = data else {
                    self.errorMessage = "無資料"
                    self.isLoading = false
                    self.loadFromLocalFile()
                    return
                }
                
                // 嘗試解析 Firebase 格式
                self.parseFirebaseData(data)
            }
        }.resume()
    }
    
    /// 解析 Firebase 資料格式
    private func parseFirebaseData(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            
            // Firebase 返回的是 { "semesters": [...] } 格式
            let wrapper = try decoder.decode(FirebaseCalendarWrapper.self, from: data)
            
            // 轉換為 AcademicCalendarData
            let calendars = wrapper.semesters.map { local in
                SemesterCalendar(
                    semester: local.name,
                    academicYear: String(local.year),
                    semesterNumber: local.semester,
                    title: "國立宜蘭大學\(local.year)學年度第\(local.semester)學期行事曆",
                    events: local.events
                )
            }
            
            // 手動建立 AcademicCalendarData
            self.calendarData = AcademicCalendarData(calendars: calendars, lastUpdated: nil)
            
            // 如果當前學期不存在，使用最新的學期
            if self.calendarData?.calendar(for: self.currentSemester) == nil,
               let latestSemester = self.calendarData?.availableSemesters.first {
                self.currentSemester = latestSemester
            }
            
            // 設置預設選中的月份為當前月份
            if self.selectedMonth == nil {
                self.selectedMonth = Calendar.current.component(.month, from: Date())
            }
            
            self.isLoading = false
            print("[Calendar] 從 Firebase 載入成功: \(calendars.count) 個學期")
        } catch {
            self.errorMessage = "解析行事曆資料失敗: \(error.localizedDescription)"
            self.isLoading = false
            print("[Calendar] Firebase 資料解析失敗: \(error)，嘗試本地資料")
            self.loadFromLocalFile()
        }
    }
    
    /// 從本地 JSON 檔案載入（用於測試或離線使用）
    func loadFromLocalFile(filename: String = "academic_calendar") {
        isLoading = true
        errorMessage = nil
        
        let fm = FileManager.default
        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(filename).json")
        
        if let docsURL, let data = try? Data(contentsOf: docsURL) {
            parseCalendarData(data)
            return
        }
        
        guard let bundleURL = Bundle.main.url(forResource: filename, withExtension: "json"),
              let data = try? Data(contentsOf: bundleURL) else {
            errorMessage = "找不到本地行事曆檔案"
            isLoading = false
            return
        }
        
        parseCalendarData(data)
    }
    
    /// 解析 JSON 資料
    func parseCalendarData(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            calendarData = try decoder.decode(AcademicCalendarData.self, from: data)
            
            // 如果當前學期不存在，使用最新的學期
            if calendarData?.calendar(for: currentSemester) == nil,
               let latestSemester = calendarData?.availableSemesters.first {
                currentSemester = latestSemester
            }
            
            // 設置預設選中的月份為當前月份
            if selectedMonth == nil {
                selectedMonth = Calendar.current.component(.month, from: Date())
            }
            
            isLoading = false
        } catch {
            errorMessage = "解析行事曆資料失敗: \(error.localizedDescription)"
            isLoading = false
            print("Calendar parsing error: \(error)")
        }
    }
    
    // MARK: - Actions
    
    /// 切換學期
    func switchSemester(to semester: String) {
        currentSemester = semester
        selectedMonth = nil  // 重置月份選擇
    }
    
    /// 選擇月份
    func selectMonth(_ month: Int) {
        selectedMonth = month
    }
    
    /// 搜尋事件
    func searchEvents(query: String) -> [CalendarEvent] {
        guard !query.isEmpty else { return allEvents }
        
        let lowercasedQuery = query.lowercased()
        return allEvents.filter { event in
            event.title.lowercased().contains(lowercasedQuery) ||
            (event.description?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }
    
    /// 根據事件類型篩選
    func filterEvents(by type: CalendarEventType) -> [CalendarEvent] {
        allEvents.filter { $0.type == type }
    }
}
