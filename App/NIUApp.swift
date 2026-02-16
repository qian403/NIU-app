import SwiftUI

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
        configureAppearance()
        printStartupInfo()
    }
    
    private func configureAppearance() {
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.backgroundColor = .white
        navBarAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.black,
            .font: UIFont.systemFont(ofSize: 18, weight: .medium)
        ]
        
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().tintColor = .black
        
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()
        tabBarAppearance.backgroundColor = .white
        
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        UITabBar.appearance().tintColor = .black
    }
    
    private func printStartupInfo() {
        #if DEBUG
        print("[NIU-App] 已啟動")
        #endif
    }
}
