import SwiftUI

struct EventRegistrationView: View {
    @StateObject private var viewModel = EventRegistrationViewModel()
    @StateObject private var tab1ViewModel = EventRegistration_Tab1_ViewModel()
    @StateObject private var tab2ViewModel = EventRegistration_Tab2_ViewModel()
    
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Tab 切換
            Picker("", selection: $viewModel.selectedTab) {
                Text("可報名活動").tag(0)
                Text("已報名活動").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            // Tab 內容
            TabView(selection: $viewModel.selectedTab) {
                EventRegistration_Tab1_View(viewModel: tab1ViewModel)
                    .tag(0)
                
                EventRegistration_Tab2_View(viewModel: tab2ViewModel)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle("活動報名")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.light)
        .onAppear {
            // 頁面一開啟就嘗試預先登入，避免後續操作遇到 Session 過期
            tab1ViewModel.prewarmLoginIfNeeded()
            tab2ViewModel.prewarmLoginIfNeeded()
        }
    }
}
