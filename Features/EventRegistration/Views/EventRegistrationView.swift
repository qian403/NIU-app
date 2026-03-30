import SwiftUI

struct EventRegistrationView: View {
    @StateObject private var viewModel = EventRegistrationViewModel()
    @StateObject private var tab1ViewModel = EventRegistration_Tab1_ViewModel()
    @StateObject private var tab2ViewModel = EventRegistration_Tab2_ViewModel()
    
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            
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
        .onAppear {
            // 頁面一開啟先預熱 Tab1；Tab2 改為切換進去時再自行啟動，避免背景失敗狀態被帶到前景
            tab1ViewModel.prewarmLoginIfNeeded()
        }
    }
}
