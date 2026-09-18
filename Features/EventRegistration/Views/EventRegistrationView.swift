import SwiftUI

struct EventRegistrationView: View {
    @StateObject private var viewModel = EventRegistrationViewModel()
    @StateObject private var tab1ViewModel = EventRegistration_Tab1_ViewModel()
    @StateObject private var tab2ViewModel = EventRegistration_Tab2_ViewModel()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Custom tab bar
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        TabButton(
                            title: "可報名活動",
                            isSelected: viewModel.selectedTab == 0
                        ) {
                            withAnimation(Theme.Animation.fast) {
                                viewModel.selectedTab = 0
                            }
                        }

                        TabButton(
                            title: "已報名活動",
                            isSelected: viewModel.selectedTab == 1
                        ) {
                            withAnimation(Theme.Animation.fast) {
                                viewModel.selectedTab = 1
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.top, Theme.Spacing.small)

                    Divider()
                }
                .background(Color(.systemBackground))

                // Tab content
                TabView(selection: $viewModel.selectedTab) {
                    EventRegistration_Tab1_View(viewModel: tab1ViewModel)
                        .tag(0)

                    EventRegistration_Tab2_View(viewModel: tab2ViewModel)
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("活動報名")
                    .font(.system(size: 17, weight: .semibold))
            }
        }
        .onAppear {
            tab1ViewModel.prewarmLoginIfNeeded()
            if viewModel.selectedTab == 1 { tab2ViewModel.prewarmLoginIfNeeded() }
        }
        .onDisappear {
            tab1ViewModel.cancelLoading()
            tab2ViewModel.cancelLoading()
        }
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color(.secondaryLabel))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.small)
        }
        .buttonStyle(.plain)
    }
}
