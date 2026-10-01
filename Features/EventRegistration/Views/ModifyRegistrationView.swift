import SwiftUI

struct ModifyRegistrationView: View {
    let event: EventData_Apply
    let onSubmit: (EventRegistrationForm) -> Void
    let onCancel: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: EventRegistrationFormViewModel
    @State private var confirmingCancellation = false
    @State private var confirmingDiscard = false

    init(event: EventData_Apply, onSubmit: @escaping (EventRegistrationForm) -> Void,
         onCancel: @escaping (String) -> Void) {
        self.event = event
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: EventRegistrationFormViewModel(eventID: event.eventSerialID))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("活動資訊") {
                    LabeledContent("活動名稱", value: event.name)
                    LabeledContent("主辦單位", value: event.department)
                }

                switch viewModel.phase {
                case .loading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在載入報名資料…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                case .failed(let message):
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("無法載入報名資料", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text(message)
                                .foregroundStyle(.secondary)
                            Button("重試", action: viewModel.load)
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                case .loaded:
                    editableSections
                }
            }
            .navigationTitle("修改報名資訊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") {
                        if viewModel.hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        onSubmit(viewModel.form)
                        dismiss()
                    }
                    .disabled(!viewModel.isValid || !viewModel.hasChanges)
                }
            }
            .interactiveDismissDisabled(viewModel.hasChanges)
            .confirmationDialog("放棄尚未儲存的修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放棄修改", role: .destructive) { dismiss() }
                Button("繼續編輯", role: .cancel) {}
            }
            .confirmationDialog("確定要取消報名？", isPresented: $confirmingCancellation, titleVisibility: .visible) {
                Button("取消報名", role: .destructive) {
                    onCancel(event.eventSerialID)
                    dismiss()
                }
                Button("保留報名", role: .cancel) {}
            } message: {
                Text("「\(event.name)」取消後可能無法再報名。")
            }
            .onAppear(perform: viewModel.load)
            .onDisappear(perform: viewModel.cancel)
        }
    }

    @ViewBuilder
    private var editableSections: some View {
        Section("基本資料") {
            LabeledContent("身分", value: viewModel.form.role.isEmpty ? "—" : viewModel.form.role)
            LabeledContent("班級", value: viewModel.form.classes.isEmpty ? "—" : viewModel.form.classes)
            LabeledContent("學號", value: viewModel.form.studentID.isEmpty ? "—" : viewModel.form.studentID)
            LabeledContent("姓名", value: viewModel.form.name.isEmpty ? "—" : viewModel.form.name)
        }

        Section {
            TextField("電話", text: $viewModel.form.tel)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            TextField("電子郵件", text: $viewModel.form.mail)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("聯絡資訊")
        } footer: {
            if !viewModel.isValid {
                Text("請填寫電話與有效的電子郵件。")
            }
        }

        Section("飲食習慣") {
            Picker("飲食習慣", selection: $viewModel.form.food) {
                Text("不用餐").tag("3")
                Text("葷食").tag("1")
                Text("素食").tag("2")
            }
            .pickerStyle(.segmented)
        }

        Section("活動認證") {
            Picker("活動認證", selection: $viewModel.form.proof) {
                Text("不需要").tag("1")
                Text("參加證明").tag("2")
                Text("公務人員學習時數").tag("3")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Section("備註（選填）") {
            TextField("備註", text: $viewModel.form.memo, axis: .vertical)
                .lineLimit(3...8)
        }

        Section {
            Button("取消報名", role: .destructive) {
                confirmingCancellation = true
            }
            .frame(maxWidth: .infinity)
        }
    }
}
