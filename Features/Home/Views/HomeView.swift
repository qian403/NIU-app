import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.white.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    headerSection
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.top, Theme.Spacing.medium)
                    
                    welcomeSection
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.top, Theme.Spacing.small)
                    
                    featureCards
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.top, Theme.Spacing.large)
                    
                    Spacer()
                }
            }
            .navigationBarHidden(true)
        }
    }
    
    private var headerSection: some View {
        HStack {
            Circle()
                .strokeBorder(Color.black, lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(appState.currentUser?.name.prefix(1).uppercased() ?? "U")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)
                )
            
            Spacer()
            
            Button(action: {
                appState.logout()
            }) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.black)
            }
        }
    }
    
    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome back,")
                .font(.system(size: 24, weight: .thin))
                .foregroundColor(.black.opacity(0.6))
            
            Text(appState.currentUser?.name ?? "User")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(.black)
                .padding(.bottom, 4)
            
            // 學生資訊 - 緊湊排列
            if let user = appState.currentUser {
                VStack(alignment: .leading, spacing: 2) {
                    if let department = user.department {
                        HStack(spacing: 6) {
                            Image(systemName: "building.2")
                                .font(.system(size: 12))
                                .foregroundColor(.black.opacity(0.5))
                            Text(department)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.black.opacity(0.7))
                        }
                    }
                    
                    HStack(spacing: 12) {
                        if let grade = user.grade {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 12))
                                    .foregroundColor(.black.opacity(0.5))
                                Text(grade)
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.black.opacity(0.7))
                            }
                        }
                        
                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .font(.system(size: 12))
                                .foregroundColor(.black.opacity(0.5))
                            Text(user.username)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.black.opacity(0.7))
                        }
                    }
                }
            }
            
            if let loginTime = UserDefaults.standard.object(forKey: "app.user.loginTime") as? Date {
                Text("Last login: \(loginTime, style: .relative)")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.black.opacity(0.4))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var featureCards: some View {
        VStack(spacing: Theme.Spacing.medium) {
            MinimalCard(
                icon: "square.grid.2x2",
                title: "Dashboard",
                subtitle: "Overview & Analytics"
            )
            
            MinimalCard(
                icon: "chart.bar",
                title: "Statistics",
                subtitle: "Data & Reports"
            )
            
            MinimalCard(
                icon: "gear",
                title: "Settings",
                subtitle: "Preferences & Account"
            )
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
