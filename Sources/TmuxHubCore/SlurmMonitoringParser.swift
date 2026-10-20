import Foundation

public enum SlurmMonitoringParserError: Error, Equatable, Sendable {
    case responseTooLarge
    case malformedRow(section: String, line: Int)
    case duplicateIdentifier(String)
}

public enum SlurmMonitoringParser {
    private static let maximumResponseBytes = 8 * 1_024 * 1_024

    public static func queues(
        nodes nodeOutput: String,
        partitions partitionOutput: String,
        queue queueOutput: String?,
        sampledAt: Date
    ) throws -> [SlurmQueueSnapshot] {
        let nodes = try nodeSnapshots(nodeOutput)
        let partitions = try records(partitionOutput, section: "partitions")
        let counts = try queueOutput.map(jobCounts)
        var seen = Set<String>()
        return try partitions.map { fields in
            guard let name = fields["PartitionName"], SlurmValidation.isSafeIdentifier(name),
                let state = fields["State"], safeField(state)
            else { throw SlurmMonitoringParserError.malformedRow(section: "partitions", line: 1) }
            guard seen.insert(name).inserted else {
                throw SlurmMonitoringParserError.duplicateIdentifier(name)
            }
            let members = nodes.filter { $0.partitions.contains(name) }.sorted { $0.name < $1.name }
            let totalGPU = sum(members.map(\.totalGPU))
            let allocatedGPU = sum(members.map(\.allocatedGPU))
            let totalNPU = sum(members.map(\.totalNPU))
            let allocatedNPU = sum(members.map(\.allocatedNPU))
            let partitionIsUp = state.uppercased() == "UP"
            let countsKnown = members.allSatisfy { $0.unallocatedGPU != nil }
            let four = countsKnown ? members.filter {
                partitionIsUp && $0.isSchedulable && ($0.unallocatedGPU ?? 0) >= 4
            }.count : nil
            let eight = countsKnown ? members.filter {
                partitionIsUp && $0.isSchedulable && ($0.unallocatedGPU ?? 0) >= 8
            }.count : nil
            let count = counts?[name]
            return SlurmQueueSnapshot(
                partition: name, state: state,
                totalGPU: totalGPU, allocatedGPU: allocatedGPU,
                unallocatedGPU: difference(totalGPU, allocatedGPU),
                totalCPU: sum(members.map(\.totalCPU)),
                allocatedCPU: sum(members.map(\.allocatedCPU)),
                totalMemoryMiB: sum(members.map(\.totalMemoryMiB)),
                allocatedMemoryMiB: sum(members.map(\.allocatedMemoryMiB)),
                nodeCount: members.count,
                unavailableNodeCount: members.filter { !partitionIsUp || !$0.isSchedulable }.count,
                schedulableFourGPUNodeCount: four,
                schedulableEightGPUNodeCount: eight,
                runningJobCount: counts == nil ? nil : (count?.running ?? 0),
                pendingJobCount: counts == nil ? nil : (count?.pending ?? 0),
                nodes: members, sampledAt: sampledAt,
                totalNPU: totalNPU, allocatedNPU: allocatedNPU,
                unallocatedNPU: difference(totalNPU, allocatedNPU)
            )
        }.sorted { $0.partition < $1.partition }
    }

    public static func allocations(_ output: String) throws -> [SlurmJobID: SlurmJobAllocation] {
        var result: [SlurmJobID: SlurmJobAllocation] = [:]
        for (index, fields) in try records(output, section: "allocations").enumerated() {
            guard let rawID = fields["JobId"], let jobID = SlurmJobID(rawValue: rawID),
                let rawOwner = fields["UserId"],
                let owner = rawOwner.split(separator: "(").first.map(String.init),
                SlurmValidation.isSafeIdentifier(owner), let rawState = fields["JobState"]
            else { throw SlurmMonitoringParserError.malformedRow(section: "allocations", line: index + 1) }
            guard result[jobID] == nil else {
                throw SlurmMonitoringParserError.duplicateIdentifier(rawID)
            }
            let state = SlurmJobState(schedulerValue: rawState)
            let hasAllocation = state == .running || state == .completing || state == .suspended || state.isTerminal
            let tres = hasAllocation ? fields["AllocTRES"].map(tresFields) : nil
            result[jobID] = SlurmJobAllocation(
                jobID: jobID, owner: owner, state: state,
                nodeList: optional(fields["NodeList"]),
                allocatedGPU: tres.flatMap { $0.isEmpty ? 0 : gpuCount($0) },
                allocatedCPU: integer(tres?["cpu"]) ?? (hasAllocation ? integer(fields["NumCPUs"]) : nil),
                allocatedMemoryMiB: memoryMiB(tres?["mem"]),
                elapsedSeconds: duration(fields["RunTime"]),
                allocatedResources: hasAllocation ? fields["AllocTRES"] : nil,
                allocatedNPU: tres.flatMap { $0.isEmpty ? 0 : acceleratorCount($0, resource: "npu") }
            )
        }
        return result
    }

    /// Parses sstat's fixed pipe-delimited fields. Slurm's RSS fields are
    /// sampled high-water values, so they are deliberately exposed as peaks.
    public static func statistics(
        _ output: String,
        allocations: [SlurmJobID: SlurmJobAllocation]
    ) throws -> [SlurmJobID: SlurmJobStatistics] {
        struct Accumulator {
            var cpuSeconds: Double = 0
            var hasCPU = false
            var missingCPU = false
            var maximumMemoryMiB: Double?
        }
        var totals: [SlurmJobID: Accumulator] = [:]
        var seen = Set<String>()
        for (index, line) in try lines(output).enumerated() {
            var fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            if fields.count == 9, fields.last == "" { fields.removeLast() }
            guard fields.count == 8, fields.allSatisfy(safeField),
                let firstPart = fields[0].split(separator: ".").first,
                let jobID = SlurmJobID(rawValue: String(firstPart))
            else { throw SlurmMonitoringParserError.malformedRow(section: "statistics", line: index + 1) }
            guard seen.insert(fields[0]).inserted else {
                throw SlurmMonitoringParserError.duplicateIdentifier(fields[0])
            }
            guard allocations[jobID] != nil else { continue }
            var total = totals[jobID] ?? Accumulator()
            if let tasks = integer(fields[1]), tasks > 0, let cpu = duration(fields[2]) {
                total.cpuSeconds += cpu * Double(tasks)
                total.hasCPU = true
            } else {
                total.missingCPU = true
            }
            if let memory = memoryMiBValue(fields[4]) {
                total.maximumMemoryMiB = max(total.maximumMemoryMiB ?? 0, memory)
            }
            totals[jobID] = total
        }
        return totals.mapValues { total in
            SlurmJobStatistics(
                averageCPUPercent: nil,
                peakTaskMemoryMiB: total.maximumMemoryMiB,
                cpuTimeSeconds: total.hasCPU && !total.missingCPU ? total.cpuSeconds : nil,
                source: "sstat"
            )
        }.reduce(into: [:]) { result, item in
            let (jobID, stats) = item
            let allocation = allocations[jobID]
            let percent: Double?
            if let cpuSeconds = stats.cpuTimeSeconds,
                let elapsed = allocation?.elapsedSeconds, elapsed > 0,
                let cpus = allocation?.allocatedCPU, cpus > 0 {
                percent = cpuSeconds / elapsed / Double(cpus) * 100
            } else { percent = nil }
            result[jobID] = SlurmJobStatistics(
                averageCPUPercent: percent, peakTaskMemoryMiB: stats.peakTaskMemoryMiB,
                cpuTimeSeconds: stats.cpuTimeSeconds, source: stats.source
            )
        }
    }

    /// Expected nvidia-smi fields: index,uuid,name,utilization.gpu,memory.used,memory.total.
    /// Unsupported device metrics remain nil, even when other device metrics exist.
    public static func gpuUsage(_ output: String) throws -> [SlurmGPUUtilization] {
        var seen = Set<String>()
        return try lines(output).enumerated().map { index, line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard [6, 9].contains(fields.count), fields.allSatisfy(safeField) else {
                throw SlurmMonitoringParserError.malformedRow(section: "gpu", line: index + 1)
            }
            let offset = fields.count == 9 ? 1 : 0
            let nodeName = offset == 1 ? fields[0] : nil
            guard nodeName.map(validGPUNodeName) ?? true,
                let gpuIndex = integer(fields[offset]), fields[offset + 1].hasPrefix("GPU-"),
                fields[offset + 1].utf8.count <= 128, !fields[offset + 2].isEmpty
            else { throw SlurmMonitoringParserError.malformedRow(section: "gpu", line: index + 1) }
            let percent = number(fields[offset + 3]).flatMap { $0 <= 100 ? $0 : nil }
            let device = SlurmGPUUtilization(
                index: gpuIndex, uuid: fields[offset + 1], name: fields[offset + 2],
                utilizationPercent: percent, memoryUsedMiB: number(fields[offset + 4]),
                memoryTotalMiB: number(fields[offset + 5]), nodeName: nodeName,
                powerDrawWatts: offset == 1 ? number(fields[7]) : nil,
                powerLimitWatts: offset == 1 ? number(fields[8]) : nil
            )
            guard seen.insert(device.id).inserted else {
                throw SlurmMonitoringParserError.duplicateIdentifier(device.id)
            }
            return device
        }.sorted {
            if $0.nodeName != $1.nodeName { return ($0.nodeName ?? "") < ($1.nodeName ?? "") }
            return $0.index < $1.index
        }
    }

    private static func validGPUNodeName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"#, options: .regularExpression) != nil
    }

    private static func nodeSnapshots(_ output: String) throws -> [SlurmNodeSnapshot] {
        var seen = Set<String>()
        return try records(output, section: "nodes").enumerated().map { index, fields in
            guard let name = fields["NodeName"], SlurmValidation.isSafeIdentifier(name),
                let state = fields["State"]
            else { throw SlurmMonitoringParserError.malformedRow(section: "nodes", line: index + 1) }
            guard seen.insert(name).inserted else {
                throw SlurmMonitoringParserError.duplicateIdentifier(name)
            }
            // Slurm omits Partitions entirely for nodes outside any partition,
            // including decommissioned or drained nodes. They contribute to no
            // partition totals and must not invalidate the remaining snapshot.
            let partitions = optional(fields["Partitions"])?
                .split(separator: ",").map(String.init) ?? []
            let configured = fields["CfgTRES"].map(tresFields)
            let allocated = fields["AllocTRES"].map(tresFields)
            let excludedStates = ["DOWN", "DRAIN", "FAIL", "MAINT", "REBOOT", "POWER", "UNKNOWN", "FUTURE", "INVAL", "NO_RESPOND", "NOT_RESPOND"]
            let upperState = state.uppercased()
            return SlurmNodeSnapshot(
                name: name, partitions: partitions, state: state,
                totalGPU: nodeAcceleratorCount(configured, gres: fields["Gres"], resource: "gpu"),
                // An explicit empty AllocTRES means no resources are allocated.
                // A missing key remains unknown rather than an observed zero.
                allocatedGPU: allocated.flatMap { $0.isEmpty ? 0 : gpuCount($0) },
                totalCPU: integer(fields["CPUTot"]) ?? integer(configured?["cpu"]),
                allocatedCPU: integer(fields["CPUAlloc"]) ?? integer(allocated?["cpu"]),
                totalMemoryMiB: integer64(fields["RealMemory"]) ?? memoryMiB(configured?["mem"]),
                allocatedMemoryMiB: integer64(fields["AllocMem"]) ?? memoryMiB(allocated?["mem"]),
                isSchedulable: !excludedStates.contains { upperState.contains($0) },
                totalNPU: nodeAcceleratorCount(configured, gres: fields["Gres"], resource: "npu"),
                allocatedNPU: allocated.flatMap { $0.isEmpty ? 0 : acceleratorCount($0, resource: "npu") }
            )
        }
    }

    private static func jobCounts(_ output: String) throws -> [String: (running: Int, pending: Int)] {
        var counts: [String: (running: Int, pending: Int)] = [:]
        for (index, line) in try lines(output).enumerated() {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, fields.allSatisfy(safeField), !fields[0].isEmpty else {
                throw SlurmMonitoringParserError.malformedRow(section: "queue", line: index + 1)
            }
            for rawPartition in fields[0].split(separator: ",") {
                let partition = String(rawPartition).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                var count = counts[partition] ?? (running: 0, pending: 0)
                switch SlurmJobState(schedulerValue: fields[1]) {
                case .running, .completing: count.running += 1
                case .pending: count.pending += 1
                default: break
                }
                counts[partition] = count
            }
        }
        return counts
    }

    private static func records(_ output: String, section: String) throws -> [[String: String]] {
        let pattern = try NSRegularExpression(pattern: #"(?:^|\s)([A-Za-z][A-Za-z0-9_:/]*)="#)
        return try lines(output).enumerated().map { index, line in
            let string = line as NSString
            let matches = pattern.matches(in: line, range: NSRange(location: 0, length: string.length))
            guard !matches.isEmpty else {
                throw SlurmMonitoringParserError.malformedRow(section: section, line: index + 1)
            }
            var values: [String: String] = [:]
            for (offset, match) in matches.enumerated() {
                let key = string.substring(with: match.range(at: 1))
                let start = match.range.location + match.range.length
                let end = offset + 1 < matches.count ? matches[offset + 1].range.location : string.length
                let value = string.substring(with: NSRange(location: start, length: end - start))
                    .trimmingCharacters(in: .whitespaces)
                guard values[key] == nil, safeField(value) else {
                    throw SlurmMonitoringParserError.malformedRow(section: section, line: index + 1)
                }
                values[key] = value
            }
            return values
        }
    }

    private static func lines(_ output: String) throws -> [String] {
        guard output.utf8.count <= maximumResponseBytes else {
            throw SlurmMonitoringParserError.responseTooLarge
        }
        return output.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private static func tresFields(_ value: String) -> [String: String] {
        value.split(separator: ",").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
    }

    private static func gpuCount(_ tres: [String: String]) -> Int? {
        acceleratorCount(tres, resource: "gpu")
    }

    private static func acceleratorCount(_ tres: [String: String], resource: String) -> Int? {
        if let generic = tres["gres/\(resource)"] { return integer(generic) }
        let typed = tres.filter { $0.key.hasPrefix("gres/\(resource):") }
        if !typed.isEmpty { return sum(typed.values.map(integer)) }
        // A complete allocation without this resource reports an observed zero,
        // including NPU-only jobs which must never be sampled as NVIDIA GPUs.
        let knownResource = tres.keys.contains {
            $0 == "gres/gpu" || $0.hasPrefix("gres/gpu:")
                || $0 == "gres/npu" || $0.hasPrefix("gres/npu:")
        }
        return tres["cpu"] != nil || tres["mem"] != nil || knownResource ? 0 : nil
    }

    private static func nodeAcceleratorCount(
        _ configured: [String: String]?, gres: String?, resource: String
    ) -> Int? {
        if let configured, configured.keys.contains(where: {
            $0 == "gres/\(resource)" || $0.hasPrefix("gres/\(resource):")
        }) {
            return acceleratorCount(configured, resource: resource)
        }
        // Some clusters expose devices only through Gres rather than CfgTRES.
        // Ignore socket affinity suffixes such as npu:16(S:0-1).
        if let gres {
            let entries = gres.split(separator: ",").map {
                String($0.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces)
            }.filter { $0 == resource || $0.hasPrefix(resource + ":") }
            if !entries.isEmpty {
                let parts = entries.map { $0.split(separator: ":", omittingEmptySubsequences: false) }
                guard parts.allSatisfy({ (2...3).contains($0.count) }) else { return nil }
                let generic = parts.filter { $0.count == 2 }
                if generic.count == 1 { return integer(String(generic[0][1])) }
                guard generic.isEmpty else { return nil }
                return sum(parts.map { integer(String($0[2])) })
            }
        }
        if let configured { return acceleratorCount(configured, resource: resource) }
        return gres?.lowercased() == "(null)" ? 0 : nil
    }

    private static func integer(_ value: String?) -> Int? {
        guard let value, let number = Int(value), number >= 0 else { return nil }
        return number
    }

    private static func integer64(_ value: String?) -> Int64? {
        guard let value, let number = Int64(value), number >= 0 else { return nil }
        return number
    }

    private static func number(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func optional(_ value: String?) -> String? {
        guard let value, !["", "N/A", "NONE", "UNKNOWN", "(NULL)"].contains(value.uppercased()) else { return nil }
        return value
    }

    private static func memoryMiB(_ value: String?) -> Int64? {
        guard let memory = memoryMiBValue(value), memory < Double(Int64.max) else { return nil }
        return Int64(memory.rounded(.up))
    }

    private static func memoryMiBValue(_ value: String?) -> Double? {
        guard let value = optional(value) else { return nil }
        let numeric = value.prefix { $0.isNumber || $0 == "." }
        guard let amount = number(String(numeric)) else { return nil }
        let suffix = value.dropFirst(numeric.count).uppercased()
        let multiplier: Double
        switch suffix {
        case "", "M", "MB", "MIB": multiplier = 1
        case "K", "KB", "KIB": multiplier = 1 / 1_024
        case "G", "GB", "GIB": multiplier = 1_024
        case "T", "TB", "TIB": multiplier = 1_024 * 1_024
        case "B": multiplier = 1 / (1_024 * 1_024)
        default: return nil
        }
        let result = amount * multiplier
        return result.isFinite ? result : nil
    }

    private static func duration(_ value: String?) -> TimeInterval? {
        guard let value = optional(value) else { return nil }
        let dayParts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard dayParts.count <= 2 else { return nil }
        let days: Double
        if dayParts.count == 2 {
            guard let parsedDays = number(String(dayParts[0])) else { return nil }
            days = parsedDays
        } else { days = 0 }
        let fields = dayParts.last!.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        var result = 0.0
        for field in fields {
            guard let component = number(String(field)) else { return nil }
            result = result * 60 + component
        }
        return days * 86_400 + result
    }

    private static func safeField(_ value: String) -> Bool {
        value.utf8.count <= 16_384 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func sum<T: FixedWidthInteger>(_ values: [T?]) -> T? {
        var result: T = 0
        for value in values {
            guard let value else { return nil }
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }

    private static func difference(_ total: Int?, _ allocated: Int?) -> Int? {
        guard let total, let allocated else { return nil }
        return max(0, total - allocated)
    }
}
