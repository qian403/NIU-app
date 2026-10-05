import SwiftUI
import BackgroundTasks
import FirebaseCore
import FirebaseAnalytics

@main
struct NIUApp: App {
    @UIApplicationDelegateAdaptor(NIUAppDelegate.self) private var appDelegate

    fileprivate static var isRunningUIFixture: Bool {
        #if DEBUG
        return ClassScheduleUIFixture.requested || MoodleUIFixtureRoot.isEnabled || EventFavoritesUIFixture.requested ||
            ProcessInfo.processInfo.arguments.contains("-NIUMailUIFixture") ||
            NativeMailUIFixtureScreen.launchScreen() != nil
        #else
        return false
        #endif
    }
    
    init() {
        if Self.isRunningUIFixture {
            Analytics.setAnalyticsCollectionEnabled(false)
            configureAppearance()
            return
        }
        setupApp()
    }
    
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ClassScheduleUIFixture.requested {
                ClassScheduleUIFixtureRoot()
            } else if MoodleUIFixtureRoot.isEnabled {
                MoodleUIFixtureRoot()
            } else if EventFavoritesUIFixture.requested {
                if EventFavoritesUIFixture.scenario == "batch" {
                    EventBatchRegistrationView(events: EventBatchPreviewFixtures.events, service: EventBatchPreviewFixtures.Service())
                } else if EventFavoritesUIFixture.scenario == "reminders" {
                    EventReminderSettingsPreview()
                } else if EventFavoritesUIFixture.scenario == "reminders-denied" {
                    EventReminderSettingsPreview(status: "系統通知尚未允許，未安排活動提醒；請至 iOS 設定開啟通知。")
                } else if EventFavoritesUIFixture.scenario == "integrated" {
                    EventIntegratedUIFixtureRoot()
                } else {
                    EventFavoritesUIFixtureRoot()
                }
            } else if ProcessInfo.processInfo.arguments.contains("-NIUMailUIFixture") || NativeMailUIFixtureScreen.launchScreen() != nil {
                NativeMailUIFixtureRoot()
            } else {
                RootView()
            }
            #else
            RootView()
            #endif
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
        
        // iOS 26 separates scrolled content with its own scroll-edge effect. Earlier systems
        // need a material once content scrolls under the bar; at the top it stays transparent.
        let scrolledAppearance: UINavigationBarAppearance
        if #available(iOS 26.0, *) {
            scrolledAppearance = navBarAppearance
        } else {
            scrolledAppearance = navBarAppearance.copy()
            scrolledAppearance.configureWithDefaultBackground()
            scrolledAppearance.shadowColor = .clear
            scrolledAppearance.titleTextAttributes = navBarAppearance.titleTextAttributes
        }

        UINavigationBar.appearance().standardAppearance = scrolledAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = scrolledAppearance
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

final class NIUAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Also disable any Analytics preference persisted by a previous normal launch.
        guard !NIUApp.isRunningUIFixture else {
            Analytics.setAnalyticsCollectionEnabled(false)
            return true
        }
        FirebaseApp.configure()
        Analytics.setConsent([
            .analyticsStorage: .granted,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied
        ])
        Analytics.setAnalyticsCollectionEnabled(true)
        return true
    }
}
