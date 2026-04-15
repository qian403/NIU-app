import Foundation

/// 行事曆資料來源配置
struct CalendarDataSourceConfig {
    static func currentAcademicYearROC(from date: Date = Date()) -> Int {
        let calendar = Calendar.current
        let gregorianYear = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let rocYear = gregorianYear - 1911
        return month >= 8 ? rocYear : rocYear - 1
    }

    static func remoteAcademicCalendarURLString(for academicYearROC: Int = currentAcademicYearROC()) -> String {
        "https://tools.chien.dev/data/niu/academic-calendar/\(academicYearROC).json"
    }
    
    // MARK: - 資料來源類型
    
    enum DataSource {
        case github(owner: String, repo: String, branch: String, path: String)
        case customURL(String)
        case firebase(path: String)
        case local(filename: String)
        
        var urlString: String? {
            switch self {
            case .github(let owner, let repo, let branch, let path):
                return "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)"
            case .customURL(let url):
                return url
            case .firebase, .local:
                return nil
            }
        }
    }
    
    // MARK: - 預設配置
    
    /// 主要資料來源（優先）
    #if DEBUG
    static let primary: DataSource = .customURL(remoteAcademicCalendarURLString())
    #else
    static let primary: DataSource = .customURL(remoteAcademicCalendarURLString())
    #endif
    
    /// 備用資料來源（當主要來源失敗時）
    #if DEBUG
    static let fallbacks: [DataSource] = [
        .local(filename: "academic_calendar"),
        .firebase(path: "學年度行事曆"),
    ]
    #else
    static let fallbacks: [DataSource] = [
        .local(filename: "academic_calendar"),
        .firebase(path: "學年度行事曆")
    ]
    #endif
    
    // MARK: - 其他可用的公共資料源
    
    /// jsDelivr CDN（國內訪問較快）
    static let jsdelivr: DataSource = .customURL(
        remoteAcademicCalendarURLString()
    )
    
    /// Gitee（中國鏡像，備用）
    static let gitee: DataSource = .github(
        owner: "qian403",
        repo: "NIU-app",
        branch: "main",
        path: "Resources/academic_calendar.json"
    )
    
    // MARK: - Helper Methods
    
    /// 取得所有資料來源（按優先順序）
    static func getAllSources() -> [DataSource] {
        return [primary] + fallbacks
    }
}

// MARK: - ViewModel Extension

extension AcademicCalendarViewModel {
    
    /// 使用配置的資料來源載入
    func loadFromConfiguredSources() {
        loadFromSource(CalendarDataSourceConfig.primary)
    }
    
    /// 從指定資料來源載入
    func loadFromSource(_ source: CalendarDataSourceConfig.DataSource, fallbackIndex: Int = 0) {
        switch source {
        case .github, .customURL:
            if let urlString = source.urlString {
                loadFromURL(urlString, onFailure: {
                    self.tryNextFallback(fallbackIndex)
                })
            } else {
                tryNextFallback(fallbackIndex)
            }
            
        case .firebase(let path):
            loadFromFirebase(path: path, onFailure: {
                self.tryNextFallback(fallbackIndex)
            })
            
        case .local(let filename):
            loadFromLocalFile(filename: filename)
        }
    }
    
    private func tryNextFallback(_ currentIndex: Int) {
        let fallbacks = CalendarDataSourceConfig.fallbacks
        if currentIndex < fallbacks.count {
            print("[Calendar] 嘗試備用資料源 #\(currentIndex + 1)")
            loadFromSource(fallbacks[currentIndex], fallbackIndex: currentIndex + 1)
        } else {
            print("[Calendar] 所有資料源均失敗")
            errorMessage = "無法載入行事曆資料，請檢查網路連線"
        }
    }
    
    // MARK: - Enhanced Loading Methods
    
    private func loadFromURL(_ urlString: String, onFailure: @escaping () -> Void) {
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: urlString) else {
            onFailure()
            return
        }
        
        print("[Calendar] 從 URL 載入: \(urlString)")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    print("[Calendar] URL 載入失敗: \(error.localizedDescription)")
                    onFailure()
                    return
                }
                
                guard let data = data else {
                    print("[Calendar] 無資料")
                    onFailure()
                    return
                }
                
                print("[Calendar] URL 載入成功")
                self.parseCalendarData(data)
            }
        }.resume()
    }
    
    private func loadFromFirebase(path: String, onFailure: @escaping () -> Void) {
        isLoading = true
        errorMessage = nil
        
        print("[Calendar] Firebase 暫不支援，使用備用資料源")
        // TODO: 實現 Firebase 載入功能
        // 需要先建立 FirebaseDatabaseManager 或使用 Firebase SDK
        onFailure()
    }
}
