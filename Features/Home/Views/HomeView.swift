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
        .task {
            await appState.refreshProfileIfNeeded()
        }
    }
    
    private var headerSection: some View {
        HStack {
            NavigationLink(destination: SettingsView()) {
                Circle()
                    .strokeBorder(Color.black, lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(appState.currentUser?.name.prefix(1).uppercased() ?? "U")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            
            Spacer()
            
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.black)
            }
            .buttonStyle(PlainButtonStyle())
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
                            Text(normalizedDepartment(from: department))
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
	            // M 園區
	            NavigationLink(destination: MoodleView()) {
	                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "graduationcap")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.black)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("M 園區")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)

                        Text("Moodle 課程、公告與作業")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.black.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.black.opacity(0.3))
	                }
	                .padding(Theme.Spacing.medium)
	                .background(
	                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
	                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
	                )
	            }
	            .buttonStyle(PlainButtonStyle())

	            // 我的課表
	            NavigationLink(destination: ClassScheduleView()) {
	                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.black)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("我的課表")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)

                        Text("查看每週課程安排")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.black.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.black.opacity(0.3))
	                }
	                .padding(Theme.Spacing.medium)
	                .background(
	                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
	                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
	                )
	            }
	            .buttonStyle(PlainButtonStyle())

	            // 學年度行事曆
	            NavigationLink(destination: AcademicCalendarView()) {
	                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "calendar")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.black)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("學年度行事曆")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)
                        
                        Text("查看學期重要日程")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.black.opacity(0.5))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.black.opacity(0.3))
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                )
	            }
	            .buttonStyle(PlainButtonStyle())
	            
	            // 活動報名
            NavigationLink(destination: EventRegistrationView()) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.black)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("活動報名")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)
                        
                        Text("查看與報名校園活動")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.black.opacity(0.5))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.black.opacity(0.3))
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())

            // 成績查詢
            NavigationLink(destination: GradeHistoryView()) {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "doc.text.below.ecg")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.black)
                        .frame(width: 50, height: 50)
                        .background(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("成績查詢")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.black)

                        Text("期中、期末與歷年成績")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.black.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.black.opacity(0.3))
                }
                .padding(Theme.Spacing.medium)
                .background(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func normalizedDepartment(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["系所年級：", "系所年級:", "系所：", "系所:"]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            let value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? trimmed : value
        }
        return trimmed
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
