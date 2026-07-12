import MerlinLizdCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var terminals: TerminalTabsModel

    @State private var searchText = ""
    @State private var expandedDevboxes: Set<String> = []

    private var filteredDevboxes: [DevboxInventory] {
        guard !searchText.isEmpty else { return model.devboxes }
        return model.devboxes.compactMap { machine in
            let machineMatches = [machine.sshAlias, machine.devbox.name, machine.devbox.sid]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
            let workers = machine.workers.filter {
                $0.id.localizedCaseInsensitiveContains(searchText)
                    || ($0.gpuType?.localizedCaseInsensitiveContains(searchText) == true)
            }
            if machineMatches {
                return machine
            }
            guard !workers.isEmpty else { return nil }
            return DevboxInventory(
                devbox: machine.devbox,
                sshAlias: machine.sshAlias,
                workers: workers,
                workerStatus: machine.workerStatus
            )
        }
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                SidebarWorkspaceRow(
                    title: "机器总览",
                    symbol: "rectangle.grid.2x2.fill",
                    tint: .blue,
                    selected: model.selection == .overview
                )
                    .tag(SidebarSelection.overview)
                    .onTapGesture { show(.overview) }
                    .sidebarListRow()
                SidebarWorkspaceRow(
                    title: "全部工作机",
                    symbol: "cpu.fill",
                    tint: .purple,
                    selected: model.selection == .allWorkers
                )
                    .tag(SidebarSelection.allWorkers)
                    .onTapGesture { show(.allWorkers) }
                    .sidebarListRow()
                SidebarWorkspaceRow(
                    title: "本机终端",
                    symbol: "terminal.fill",
                    tint: .cyan,
                    selected: model.selection == .local
                )
                    .tag(SidebarSelection.local)
                    .onTapGesture { show(.local) }
                    .onTapGesture(count: 2) {
                        terminals.openLocal()
                    }
                    .sidebarListRow()
            } header: {
                SidebarSectionHeader(title: "工作区", symbol: "square.grid.2x2")
            }

            Section {
                ForEach(filteredDevboxes) { machine in
                    DisclosureGroup(
                        isExpanded: expandedBinding(for: machine.devbox.sid)
                    ) {
                        ForEach(machine.workers) { worker in
                            let workerSelection = SidebarSelection.worker(
                                devboxSID: machine.devbox.sid,
                                workerID: worker.id
                            )
                            SidebarWorkerLabel(
                                worker: worker,
                                selected: model.selection == workerSelection
                            )
                                .tag(
                                    workerSelection
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    show(
                                        .worker(
                                            devboxSID: machine.devbox.sid,
                                            workerID: worker.id
                                        )
                                    )
                                }
                                .onTapGesture(count: 2) {
                                    openWorkerIfConnectable(worker, on: machine)
                                }
                                .sidebarListRow(
                                    leading: 2,
                                    trailing: 6
                                )
                        }
                    } label: {
                        SidebarDevboxLabel(
                            machine: machine,
                            selected: model.selection == .devbox(machine.devbox.sid)
                        )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                show(.devbox(machine.devbox.sid))
                            }
                            .onTapGesture(count: 2) {
                                openDevboxIfConnectable(machine)
                            }
                    }
                    .sidebarListRow(leading: 4, trailing: 6)
                    .contextMenu {
                        Button("查看详情") {
                            show(.devbox(machine.devbox.sid))
                        }
                        if machine.devbox.status.isRunning {
                            Button("打开终端") {
                                terminals.openDevbox(machine)
                            }
                            .disabled(machine.sshAlias == nil)
                        }
                    }
                }
            } header: {
                SidebarSectionHeader(title: "开发机", symbol: "server.rack")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(sidebarBackground)
        .tint(.cyan)
        .navigationTitle("Merlin Lizd")
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索机器或 GPU")
        .onKeyPress(.return) {
            openSelectedTerminal() ? .handled : .ignored
        }
        .onChange(of: model.snapshot?.refreshedAt) {
            for machine in model.devboxes where machine.devbox.status.isRunning {
                expandedDevboxes.insert(machine.devbox.sid)
            }
        }
    }

    private var sidebarBackground: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.055),
                Color.clear,
                Color.black.opacity(0.025),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(.ultraThinMaterial)
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding(
            get: { model.selection },
            set: { newSelection in
                if model.selection != newSelection {
                    show(newSelection)
                }
            }
        )
    }

    private func show(_ selection: SidebarSelection) {
        model.selection = selection
        terminals.selectedTabID = nil
    }

    @discardableResult
    private func openSelectedTerminal() -> Bool {
        switch model.selection {
        case .local:
            terminals.openLocal()
            return true
        case let .devbox(sid):
            guard let machine = model.devbox(sid: sid) else { return false }
            return openDevboxIfConnectable(machine)
        case let .worker(devboxSID, workerID):
            guard let (machine, worker) = model.worker(
                devboxSID: devboxSID,
                workerID: workerID
            ) else {
                return false
            }
            return openWorkerIfConnectable(worker, on: machine)
        case .overview, .allWorkers:
            return false
        }
    }

    @discardableResult
    private func openDevboxIfConnectable(_ machine: DevboxInventory) -> Bool {
        guard machine.devbox.status.isRunning, machine.sshAlias != nil else { return false }
        terminals.openDevbox(machine)
        return true
    }

    @discardableResult
    private func openWorkerIfConnectable(
        _ worker: WorkerInventoryRecord,
        on machine: DevboxInventory
    ) -> Bool {
        guard machine.devbox.status.isRunning, machine.sshAlias != nil else { return false }
        terminals.openWorker(worker, on: machine)
        return true
    }

    private func expandedBinding(for sid: String) -> Binding<Bool> {
        Binding(
            get: { expandedDevboxes.contains(sid) || !searchText.isEmpty },
            set: { isExpanded in
                if isExpanded {
                    expandedDevboxes.insert(sid)
                } else {
                    expandedDevboxes.remove(sid)
                }
            }
        )
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .tracking(0.45)
            .padding(.leading, 3)
            .padding(.top, 5)
    }
}

private struct SidebarWorkspaceRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
            Text(title)
                .font(.callout.weight(selected ? .semibold : .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(selectionBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if selected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                }
        }
    }
}

private struct SidebarDevboxLabel: View {
    let machine: DevboxInventory
    let selected: Bool

    private var title: String {
        machine.sshAlias ?? machine.devbox.name
    }

    private var subtitle: String {
        title == machine.devbox.name
            ? lifecycleLabel
            : machine.devbox.name
    }

    private var lifecycleLabel: String {
        if machine.devbox.status.isRunning { return "运行中" }
        if machine.devbox.status.isStopped { return "已停止" }
        return machine.devbox.status.rawValue
    }

    private var tint: Color {
        machine.devbox.status.isRunning ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "server.rack")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                    Text(title)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(workerCount)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(machine.workers.isEmpty ? .tertiary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.7), in: Capsule())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(selectionBackground)
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }

    private var workerCount: String {
        if machine.workerStatus == .notQueried, machine.devbox.status.isRunning {
            return "…"
        }
        return "\(machine.workers.count)"
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if selected {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                }
        }
    }
}

private struct SidebarWorkerLabel: View {
    let worker: WorkerInventoryRecord
    let selected: Bool

    private var tint: Color {
        worker.gpuCount > 0 ? .green : .blue
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: worker.gpuCount > 0 ? "square.stack.3d.up.fill" : "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(worker.gpuType ?? (worker.gpuCount > 0 ? "GPU Worker" : "CPU Worker"))
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Text(worker.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            Circle()
                .fill(readinessColor)
                .frame(width: 6, height: 6)
                .help(readinessLabel)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selectionBackground)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var readinessColor: Color {
        switch worker.readiness {
        case .ready: .green
        case .probing: .orange
        case .notReady: .orange
        case .unreachable: .red
        case .listed: .secondary
        }
    }

    private var readinessLabel: String {
        switch worker.readiness {
        case .ready: "就绪"
        case .probing: "探测中"
        case .notReady: "未就绪"
        case .unreachable: "不可达"
        case .listed: "待探测"
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if selected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                }
        }
    }
}

private extension View {
    func sidebarListRow(
        leading: CGFloat = 8,
        trailing: CGFloat = 8
    ) -> some View {
        listRowInsets(EdgeInsets(
            top: 1,
            leading: leading,
            bottom: 1,
            trailing: trailing
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
