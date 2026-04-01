import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatPlanCardView: View {
    private let minTaskListHeight: CGFloat = 260
    private let maxTaskListHeight: CGFloat = 520

    let plan: ChatExecutionPlan
    let isBusy: Bool
    let onApprove: () -> Void
    let onClear: () -> Void
    let onRerun: () -> Void
    let onTracePlan: () -> Void
    let onTraceTask: (ChatTask) -> Void

    private var runningTaskID: UUID? {
        plan.tasks.first(where: { $0.status == .running })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Execution Plan")
                        .font(.headline)
                    Text(plan.summary)
                        .font(.subheadline)
                    Text("Status: \(statusTitle(plan.status))")
                        .font(.caption)
                        .foregroundColor(statusColor(plan.status))
                }

                Spacer()

                if plan.status == .awaitingApproval {
                    Button("Approve") {
                        onApprove()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }

                if shouldShowPlanTrace(plan.status) {
                    Button("Plan Trace") {
                        onTracePlan()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Re-run Prompt") {
                    onRerun()
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                Button(plan.status == .awaitingApproval ? "Dismiss" : "Clear") {
                    onClear()
                }
                .buttonStyle(.bordered)
            }

            ScrollViewReader { taskProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(plan.tasks.enumerated()), id: \.element.id) { index, task in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(index + 1). \(task.title)")
                                        .font(.subheadline)
                                        .bold()
                                    Spacer()
                                    Text(statusTitle(task.status))
                                        .font(.caption)
                                        .foregroundColor(statusColor(task.status))
                                }

                                Text(task.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Text("Agent: \(task.agentName) | Tool: \(task.toolName)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                if task.inputTokenCount != nil || task.outputTokenCount != nil {
                                    Text("Tokens: in \(task.inputTokenCount ?? 0) | out \(task.outputTokenCount ?? 0)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                if shouldShowTaskTrace(task.status) {
                                    HStack {
                                        Button("Trace") {
                                            onTraceTask(task)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Spacer()
                                    }
                                }

                                if let resultSummary = task.resultSummary, !resultSummary.isEmpty {
                                    Text(resultSummary)
                                        .font(.caption)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                            .id(task.id)
                        }
                    }
                }
                .onChange(of: runningTaskID) { taskID in
                    guard let taskID else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        taskProxy.scrollTo(taskID, anchor: .center)
                    }
                }
            }
            .frame(minHeight: minTaskListHeight, maxHeight: maxTaskListHeight)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.08))
        )
    }

    private func statusTitle(_ status: ChatPlanStatus) -> String {
        switch status {
        case .draft:
            return "Draft"
        case .awaitingApproval:
            return "Awaiting Approval"
        case .approved:
            return "Approved"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    private func statusTitle(_ status: ChatTaskStatus) -> String {
        switch status {
        case .pending:
            return "Pending"
        case .approved:
            return "Approved"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .skipped:
            return "Skipped"
        }
    }

    private func statusColor(_ status: ChatPlanStatus) -> Color {
        switch status {
        case .draft, .awaitingApproval, .approved:
            return .orange
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed, .cancelled:
            return .red
        }
    }

    private func statusColor(_ status: ChatTaskStatus) -> Color {
        switch status {
        case .pending, .approved:
            return .orange
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .secondary
        }
    }

    private func shouldShowPlanTrace(_ status: ChatPlanStatus) -> Bool {
        switch status {
        case .running, .completed, .failed, .cancelled:
            return true
        case .draft, .awaitingApproval, .approved:
            return false
        }
    }

    private func shouldShowTaskTrace(_ status: ChatTaskStatus) -> Bool {
        switch status {
        case .running, .completed, .failed, .skipped:
            return true
        case .pending, .approved:
            return false
        }
    }
}
