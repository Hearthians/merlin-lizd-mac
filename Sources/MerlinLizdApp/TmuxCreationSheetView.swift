import MerlinLizdCore
import SwiftUI

struct TmuxCreationSheetView: View {
    let draft: TmuxCreationDraft
    let onCreate: (String, String) throws -> Void
    let onCancel: () -> Void

    @State private var sessionName: String
    @State private var workingDirectory = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    init(
        draft: TmuxCreationDraft,
        onCreate: @escaping (String, String) throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.onCreate = onCreate
        self.onCancel = onCancel
        _sessionName = State(initialValue: draft.suggestedSessionName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("创建 tmux 会话")
                    .font(.title2.bold())
                Text("目标：\(draft.title)")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("会话名称", text: $sessionName)
                    .focused($focusedField, equals: .sessionName)
                TextField(
                    "工作目录（可选）",
                    text: $workingDirectory,
                    prompt: Text("/path/to/project")
                )
                .focused($focusedField, equals: .workingDirectory)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 120)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    do {
                        try onCreate(sessionName, workingDirectory)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            focusedField = .sessionName
        }
    }

    private var isValid: Bool {
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TmuxSessionParser.isAttachable(name) else { return false }
        return workingDirectory.isEmpty
            || MerlinIdentifierValidator.isTmuxWorkingDirectory(workingDirectory)
    }

    private enum Field {
        case sessionName
        case workingDirectory
    }
}
