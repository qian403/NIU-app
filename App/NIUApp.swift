import SwiftUI
import BackgroundTasks

@main
struct NIUApp: App {
    
    init() {
        setupApp()
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
    
    private func setupApp() {
        registerSettingsBundleDefaults()
        registerBackgroundTasks()
        configureAppearance()
        printStartupInfo()
    }

    private func registerBackgroundTasks() {
        ClassLiveActivityBackgroundRefreshCoordinator.shared.register()
    }
    
    private func configureAppearance() {
        let navBarAppearance = UINavigationBarAppearance()
        // Keep navigation bar transparent so the top area blends with page background
        // and avoids a visible color band under the status bar.
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.backgroundEffect = nil
        navBarAppearance.backgroundColor = .clear
        navBarAppearance.shadowColor = .clear
        navBarAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 18, weight: .medium)
        ]
        
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
        UINavigationBar.appearance().tintColor = .label
        
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = .systemBackground
        
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        UITabBar.appearance().tintColor = .label
    }
    
    private func printStartupInfo() {
        #if DEBUG
        print("[NIU-App] 已啟動")
        #endif
    }

    private func registerSettingsBundleDefaults() {
        guard
            let settingsBundleURL = Bundle.main.url(forResource: "Settings", withExtension: "bundle"),
            let plistData = try? Data(contentsOf: settingsBundleURL.appendingPathComponent("Root.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
            let specifiers = plist["PreferenceSpecifiers"] as? [[String: Any]]
        else {
            return
        }

        var defaults: [String: Any] = [:]
        for specifier in specifiers {
            guard
                let key = specifier["Key"] as? String,
                let defaultValue = specifier["DefaultValue"]
            else { continue }
            defaults[key] = defaultValue
        }

        UserDefaults.standard.register(defaults: defaults)
    }
}
