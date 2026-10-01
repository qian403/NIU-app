import SwiftUI

struct EventRegistrationView: View {
    @StateObject private var viewModel = EventRegistrationViewModel()
    @StateObject private var tab1ViewModel: EventRegistration_Tab1_ViewModel
    @StateObject private var tab2ViewModel: EventRegistration_Tab2_ViewModel

    init(service: (any EventRegistrationServing)? = nil) {
        _tab1ViewModel = StateObject(wrappedValue: EventRegistration_Tab1_ViewModel(service: service))
        _tab2ViewModel = StateObject(wrappedValue: EventRegistration_Tab2_ViewModel(service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("活動分類", selection: $viewModel.selectedTab) {
                Text("可報名活動").tag(0)
                Text("已報名活動").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.xsmall)

            TabView(selection: $viewModel.selectedTab.animation(Theme.Animation.fast)) {
                EventRegistration_Tab1_View(viewModel: tab1ViewModel) {
                    withAnimation(Theme.Animation.fast) { viewModel.selectedTab = 1 }
                }
                .tag(0)

                EventRegistration_Tab2_View(viewModel: tab2ViewModel)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay {
            if let activity = tab1ViewModel.activity ?? tab2ViewModel.activity {
                EventActivityOverlay(text: activity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("活動報名")
                    .font(.headline)
            }
        }
        .onAppear {
            // The client runs these one after another, so both tabs share one sign-in.
            tab1ViewModel.loadIfNeeded()
            tab2ViewModel.loadIfNeeded()
        }
        .onDisappear {
            tab1ViewModel.cancelLoading()
            tab2ViewModel.cancelLoading()
        }
    }
}

/// Blocks input while a request that changes the school's records is running.
struct EventActivityOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.small) {
                ProgressView()
                    .controlSize(.large)
                Text(text)
                    .font(.headline)
                Text("請勿離開此頁面")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}
