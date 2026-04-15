import SwiftUI

struct EventRegistration_Tab2_View: View {
    @ObservedObject var viewModel: EventRegistration_Tab2_ViewModel
    @State private var selectedEvent: EventData_Apply?
    
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 搜尋框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("搜尋活動名稱、主辦單位或狀態", text: $viewModel.searchText)
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
                        Image(systemName: viewModel.searchText.isEmpty ? "calendar.badge.checkmark" : "magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text(viewModel.searchText.isEmpty ? "目前沒有已報名的活動" : "找不到符合「\(viewModel.searchText)」的活動")
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
                                AppliedEventRow(event: event)
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
            AppliedEventDetailView(
                event: event,
                onCancel: { eventID in
                    viewModel.cancelRegistration(eventID: eventID)
                },
                onModify: { event in
                    viewModel.selectedEventForModify = event
                }
            )
        }
        .sheet(item: $viewModel.selectedEventForModify) { event in
            ModifyRegistrationView(event: event, onSubmit: { eventInfo in
                viewModel.modifyRegistration(eventInfo: eventInfo)
            }, onCancel: { eventID in
                viewModel.cancelRegistration(eventID: eventID)
            })
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

// MARK: - 已報名活動列表項目
struct AppliedEventRow: View {
    let event: EventData_Apply
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.name)
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(event.state)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                    
                    Text(event.event_state)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(eventStateColor.opacity(0.2))
                        .foregroundColor(eventStateColor)
                        .cornerRadius(4)
                }
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
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    private var eventStateColor: Color {
        switch event.event_state {
        case let state where state.contains("進行中"):
            return .green
        case let state where state.contains("已結束"):
            return .gray
        default:
            return .blue
        }
    }
}
