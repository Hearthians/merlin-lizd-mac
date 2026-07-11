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
            Section("工作区") {
                Label("机器总览", systemImage: "rectangle.grid.2x2")
                    .tag(SidebarSelection.overview)
                    .onTapGesture { show(.overview) }
                Label("全部工作机", systemImage: "cpu")
                    .tag(SidebarSelection.allWorkers)
                    .onTapGesture { show(.allWorkers) }
                Label("本机终端", systemImage: "macbook")
                    .tag(SidebarSelection.local)
                    .onTapGesture { show(.local) }
                    .onTapGesture(count: 2) {
                        terminals.openLocal()
                    }
            }

            Section("开发机") {
                ForEach(filteredDevboxes) { machine in
                    DisclosureGroup(
                        isExpanded: expandedBinding(for: machine.devbox.sid)
                    ) {
                        ForEach(machine.workers) { worker in
                            SidebarWorkerLabel(worker: worker)
                                .tag(
                                    SidebarSelection.worker(
                                        devboxSID: machine.devbox.sid,
                                        workerID: worker.id
                                    )
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
                        }
                    } label: {
                        SidebarDevboxLabel(machine: machine)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                show(.devbox(machine.devbox.sid))
                            }
                            .onTapGesture(count: 2) {
                                openDevboxIfConnectable(machine)
                            }
                    }
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
            }
        }
        .listStyle(.sidebar)
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

private struct SidebarDevboxLabel: View {
    let machine: DevboxInventory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(machine.devbox.status.isRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.sshAlias ?? machine.devbox.name)
                    .lineLimit(1)
                if machine.sshAlias != nil {
                    Text(machine.devbox.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !machine.workers.isEmpty {
                Text("\(machine.workers.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SidebarWorkerLabel: View {
    let worker: WorkerInventoryRecord

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: worker.gpuCount > 0 ? "square.stack.3d.up.fill" : "cpu")
                .foregroundStyle(worker.gpuCount > 0 ? .green : .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(worker.gpuType ?? "CPU Worker")
                    .font(.callout)
                    .lineLimit(1)
                Text(worker.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
