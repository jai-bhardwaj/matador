import SwiftUI

struct AddJobSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var queueName: String = ""
    @State private var jobName: String = ""
    @State private var dataJSON: String = "{\n  \n}"
    @State private var priority: Int = 0
    @State private var delaySeconds: Int = 0
    @State private var attempts: Int = 1
    @State private var jsonError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Job")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Form {
                Section("Target") {
                    Picker("Queue", selection: $queueName) {
                        ForEach(state.queues) { q in
                            Text(q.name).tag(q.name)
                        }
                    }
                    TextField("Job name", text: $jobName)
                        .help("BullMQ Worker matches by name. Use the same string your worker registered.")
                }
                Section("Payload") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("data (JSON)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $dataJSON)
                            .font(Theme.monoSmall)
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(jsonError == nil ? Color.primary.opacity(0.08) : Color.red.opacity(0.5), lineWidth: 1)
                            )
                        if let err = jsonError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Options") {
                    HStack {
                        Text("Priority")
                        Spacer()
                        TextField("0", value: $priority, format: .number.grouping(.never))
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Delay (seconds)")
                        Spacer()
                        TextField("0", value: $delaySeconds, format: .number.grouping(.never))
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Attempts")
                        Spacer()
                        TextField("1", value: $attempts, format: .number.grouping(.never))
                            .frame(width: 80)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") {
                    state.showAddJobSheet = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Job") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(queueName.isEmpty || jobName.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            if queueName.isEmpty, let q = state.selectedQueue?.name ?? state.queues.first?.name {
                queueName = q
            }
        }
    }

    private func submit() {
        // Validate JSON
        let trimmed = dataJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let toValidate = trimmed.isEmpty ? "{}" : trimmed
        guard let data = toValidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            jsonError = "Invalid JSON"
            return
        }
        jsonError = nil

        Task {
            await state.addJob(
                queueName: queueName,
                name: jobName,
                data: toValidate,
                priority: priority,
                delayMs: Int64(delaySeconds) * 1000,
                attempts: max(1, attempts)
            )
            state.showAddJobSheet = false
            dismiss()
        }
    }
}
