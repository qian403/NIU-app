import SwiftUI

struct EventRegistration_Tab2_View: View {
    @ObservedObject var viewModel: EventRegistration_Tab2_ViewModel
    @State private var selectedEvent: EventData_Apply?
    @State private var editingEvent: EventData_Apply?
    @State private var pendingEdit: EventData_Apply?

    var body: some View {
        EventListScaffold(
            items: viewModel.filteredEvents,
            totalCount: viewModel.events.count,
            phase: viewModel.phase,
            updatedAt: viewModel.updatedAt,
            searchText: $viewModel.searchText,
            searchHint: "可搜尋活動編號、名稱、主辦單位、內容或報名狀態",
            emptyTitle: "目前沒有已報名的活動",
            emptySymbol: "calendar.badge.checkmark",
            reload: viewModel.reload,
            refresh: viewModel.refresh
        ) { event in
            Button { selectedEvent = event } label: { AppliedEventRow(event: event) }
                .buttonStyle(.plain)
                .accessibilityHint("顯示報名詳情")
        }
        // Present the edit form only after the detail sheet has fully closed.
        .sheet(item: $selectedEvent, onDismiss: {
            editingEvent = pendingEdit
            pendingEdit = nil
        }) { event in
            AppliedEventDetailView(
                event: event,
                onCancel: { eventID in
                    viewModel.cancelRegistration(eventID: eventID)
                },
                onModify: { event in
                    pendingEdit = event
                }
            )
        }
        .sheet(item: $editingEvent) { event in
            ModifyRegistrationView(event: event, onSubmit: { form in
                viewModel.modifyRegistration(eventID: event.eventSerialID, form: form)
            }, onCancel: { eventID in
                viewModel.cancelRegistration(eventID: eventID)
            })
        }
        .alert(viewModel.alert?.title ?? "", isPresented: Binding(
            get: { viewModel.alert != nil },
            set: { if !$0 { viewModel.dismissAlert() } }
        ), presenting: viewModel.alert) { _ in
            Button("好", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

extension EventData_Apply {
    /// The school shows its action button text here, e.g. 「修改資料 / 取消報名」 or 「活動已結束」.
    var hasEnded: Bool { event_state.contains("已結束") }
    var offersModification: Bool { !hasEnded && event_state.contains("修改") }
    var offersCancellation: Bool { !hasEnded && event_state.contains("取消") }

    var eventStateLabel: String {
        if hasEnded { return "活動已結束" }
        if offersModification || offersCancellation { return "可修改或取消" }
        return event_state
    }

    var eventStateColor: Color {
        if hasEnded { return .gray }
        if event_state.contains("進行中") { return .green }
        return .blue
    }

    var registrationStateColor: Color {
        state.contains("取消") ? .gray : state.contains("候補") ? .orange : .green
    }
}

// MARK: - 已報名活動列表項目
struct AppliedEventRow: View {
    let event: EventData_Apply

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            Text(event.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Spacing.xsmall) {
                if !event.state.isEmpty {
                    EventStatusBadge(text: event.state, color: event.registrationStateColor)
                }
                if !event.eventStateLabel.isEmpty {
                    EventStatusBadge(text: event.eventStateLabel, color: event.eventStateColor)
                }
            }
            EventInfoLine(icon: "number", text: "活動編號：\(event.eventSerialID)")
            EventInfoLine(icon: "building.2", text: event.department)
            EventInfoLine(icon: "calendar", text: event.eventTime.replacingOccurrences(of: "\n", with: " "))
            EventInfoLine(icon: "mappin.and.ellipse", text: event.eventLocation)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
