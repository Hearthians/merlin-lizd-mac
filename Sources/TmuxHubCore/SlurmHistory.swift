import Foundation

public enum SlurmHistoryRange: Int, CaseIterable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90
}

/// A job allocation from Slurm accounting, including jobs launched outside TmuxHub.
public struct SlurmJobHistoryRecord: Hashable, Identifiable, Sendable {
    public var id: String {
        [snapshot.jobID.rawValue, snapshot.submitTime ?? "", snapshot.startTime ?? ""]
            .joined(separator: "\u{001F}")
    }

    public let snapshot: SlurmJobSnapshot
    public let endTime: String?
    public let exitCode: String
    public let allocatedResources: String

    public var isFinished: Bool {
        if snapshot.state.isTerminal { return true }
        // Preserve terminal states introduced by Slurm (e.g. BOOT_FAIL or
        // DEADLINE) when accounting supplies their actual end time.
        if case .unknown = snapshot.state { return endTime != nil }
        return false
    }

    public var sortTime: String {
        endTime ?? snapshot.startTime ?? snapshot.submitTime ?? ""
    }
}

public enum SlurmHistoryParser {
    public static func parse(_ output: String) throws -> [SlurmJobHistoryRecord] {
        guard output.utf8.count <= 8 * 1_024 * 1_024 else {
            throw SlurmParserError.responseTooLarge
        }
        var records: [String: SlurmJobHistoryRecord] = [:]
        for (offset, line) in output.split(separator: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let fields = line.split(
                separator: Character(SlurmCommands.fieldDelimiter),
                omittingEmptySubsequences: false
            ).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count == 15 else {
                throw SlurmParserError.malformedRow(line: offset + 1)
            }
            // --allocations excludes these, but defensively ignore step rows
            // rather than presenting .batch/.extern as separate old jobs.
            if fields[0].contains(".") { continue }
            guard let jobID = SlurmJobID(rawValue: fields[0]),
                SlurmValidation.isSafeIdentifier(fields[2]),
                let nodeCount = Int(fields[5]), nodeCount >= 0,
                fields.allSatisfy({ field in
                    !field.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                })
            else { throw SlurmParserError.malformedRow(line: offset + 1) }

            // sacct can append the cancelling UID and a truncation suffix.
            let stateToken = fields[3].split(separator: " ").first.map(String.init) ?? ""
            let state = SlurmJobState(schedulerValue: stateToken.trimmingCharacters(in: CharacterSet(charactersIn: "+")))
            let snapshot = SlurmJobSnapshot(
                jobID: jobID, name: fields[1], owner: fields[2], state: state,
                reasonOrNodeList: fields[11], partition: fields[4],
                nodeCount: nodeCount, elapsed: fields[6], timeLimit: fields[7],
                startTime: optionalValue(fields[9]), submitTime: optionalValue(fields[8]),
                nodeList: optionalValue(fields[11]), comment: fields[14]
            )
            let record = SlurmJobHistoryRecord(
                snapshot: snapshot, endTime: optionalValue(fields[10]),
                exitCode: fields[12], allocatedResources: fields[13]
            )
            if let existing = records[record.id], existing.sortTime > record.sortTime { continue }
            records[record.id] = record
        }
        return records.values.sorted {
            if $0.sortTime != $1.sortTime { return $0.sortTime > $1.sortTime }
            return $0.id > $1.id
        }
    }

    private static func optionalValue(_ value: String) -> String? {
        ["", "Unknown", "N/A", "None", "(null)"].contains(value) ? nil : value
    }
}
