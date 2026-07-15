import MerlinLizdCore
import SwiftUI

struct CodexOperationView: View {
    let operation: CodexOperationRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(operation.events.enumerated()), id: \.offset) {
                    _, event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.timestamp, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(describe(event.kind))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if event != operation.events.last { Divider() }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text(operation.title)
                    .lineLimit(1)
                Spacer()
                if let timestamp = operation.timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func describe(_ kind: TerminalJournalEventKind) -> String {
        switch kind {
        case let .request(operation, purpose):
            CodexBoundedText.string(
                "Request: \(operation)\nPurpose: \(purpose)"
            )
        case let .screen(screen):
            CodexBoundedText.string(
                "Screen revision \(screen.revision), \(screen.columns)×\(screen.rows), "
                + "cursor \(screen.cursor.row):\(screen.cursor.column)\n"
                + screen.text
            )
        case let .risk(agent, deterministic, effective):
            "Risk: agent=\(risk(agent)), deterministic=\(risk(deterministic)), "
                + "effective=\(risk(effective))"
        case let .approval(requestID, scope, outcome):
            "Approval \(requestID.uuidString): \(approval(outcome))\n"
                + "endpoint=\(scope.endpointID.rawValue.uuidString), "
                + "revision=\(scope.screenRevision), digest=\(scope.payloadDigest)"
        case let .endpoint(endpointID):
            "Endpoint: \(endpointID.rawValue.uuidString)"
        case let .emittedBatch(batch):
            CodexBoundedText.string(
                "Emitted input at revision \(batch.expectedRevision):\n"
                + CodexTerminalPayloadFormatter.batch(batch)
            )
        case let .result(result):
            describe(result)
        case let .temporaryPane(event):
            describe(event)
        }
    }

    private func risk(_ risk: TerminalRisk) -> String {
        switch risk {
        case .observation: "observation"
        case .routine: "routine"
        case .high: "high"
        }
    }

    private func approval(_ outcome: TerminalJournalApprovalOutcome) -> String {
        switch outcome {
        case .approvedOnce: "allowed once"
        case .denied: "denied"
        case .expired: "expired"
        case .cancelled: "cancelled"
        }
    }

    private func describe(_ result: TerminalJournalResult) -> String {
        switch result {
        case let .success(receipt):
            if let receipt {
                return "Succeeded: \(receipt.byteCount) bytes at revision "
                    + "\(receipt.acceptedRevision)"
            }
            return "Succeeded"
        case let .failure(reason):
            return CodexBoundedText.string("Failed: \(reason)")
        case .auditUnavailable:
            return "Failed closed: audit unavailable"
        }
    }

    private func describe(_ event: TerminalJournalTemporaryPaneEvent) -> String {
        switch event {
        case let .created(leaseID, pane):
            return "Temporary pane created: lease=\(leaseID.uuidString), "
                + paneDescription(pane)
        case let .closed(leaseID, pane, restoration):
            return "Temporary pane closed: lease=\(leaseID.uuidString), "
                + "\(paneDescription(pane)), restore=\(restorationDescription(restoration))"
        case let .retained(leaseID, pane, reason):
            return "Temporary pane retained: lease=\(leaseID.uuidString), "
                + "\(paneDescription(pane)), reason=\(reason.rawValue)"
        case let .indeterminate(leaseID, pane, reason):
            return "Temporary pane close indeterminate: lease=\(leaseID.uuidString), "
                + "\(paneDescription(pane)), mutation=\(reason.mutationFailure.rawValue), "
                + "reconciliation=\(reason.reconciliationFailure.rawValue)"
        }
    }

    private func paneDescription(_ pane: TerminalJournalPaneProvenance) -> String {
        "window=\(pane.windowID ?? "unknown"), pane=\(pane.paneID)"
    }

    private func restorationDescription(_ outcome: TmuxOriginRestoreOutcome) -> String {
        switch outcome {
        case .restored: "restored"
        case let .failed(reason): "failed(\(reason.rawValue))"
        }
    }
}
