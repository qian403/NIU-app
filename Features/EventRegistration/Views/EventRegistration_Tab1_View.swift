import SwiftUI

struct EventRegistration_Tab1_View: View {
    @ObservedObject var viewModel: EventRegistration_Tab1_ViewModel
    @State private var selectedEvent: EventData?
    
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 搜尋框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("搜尋活動名稱、主辦單位或內容", text: $viewModel.searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                    
                    if !viewModel.searchText.isEmpty {
                        Button(action: {
                            viewModel.searchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                if viewModel.filteredEvents.isEmpty && !viewModel.isOverlayVisible {
                    VStack(spacing: 16) {
                        Image(systemName: viewModel.searchText.isEmpty ? "calendar.badge.exclamationmark" : "magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text(viewModel.searchText.isEmpty ? "目前沒有可報名的活動" : "找不到符合「\(viewModel.searchText)」的活動")
                            .font(.headline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.filteredEvents) { event in
                                EventRow(event: event)
                                    .padding(.horizontal)
                                    .onTapGesture {
                                        selectedEvent = event
                                    }
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            
            // 載入遮罩
            if viewModel.isOverlayVisible {
                Color.primary.opacity(0.3)
                    .ignoresSafeArea()
                
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    
                    Text(viewModel.overlayText)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.9))
                )
            }
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailView(event: event) { eventID in
                viewModel.registerEvent(eventID: eventID)
            }
        }
        .overlay(
            Group {
                if viewModel.showToast {
                    ToastView(message: viewModel.toastMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    viewModel.showToast = false
                                }
                            }
                        }
                }
            }
            .animation(.spring(), value: viewModel.showToast)
            , alignment: .top
        )
        .refreshable {
            await viewModel.manualRefresh()
        }
        .onAppear {
            viewModel.onViewAppear()
        }
    }
}

// MARK: - 活動列表項目
struct EventRow: View {
    let event: EventData
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.name)
                    .font(.headline)
                Spacer()
                Text(event.event_state)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateColor.opacity(0.2))
                    .foregroundColor(stateColor)
                    .cornerRadius(4)
            }
            
            HStack {
                Image(systemName: "building.2")
                    .foregroundColor(.secondary)
                Text(event.department)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                Text(event.eventTime.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundColor(.secondary)
                Text(event.eventLocation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Image(systemName: "person.3")
                    .foregroundColor(.secondary)
                Text(event.eventPeople.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private var stateColor: Color {
        switch event.event_state {
        case let state where state.contains("報名中"):
            return .green
        case let state where state.contains("已額滿"):
            return .red
        case let state where state.contains("即將開始"):
            return .orange
        default:
            return .gray
        }
    }
}
