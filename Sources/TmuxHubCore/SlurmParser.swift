import Foundation

public enum SlurmParserError: Error, Equatable, LocalizedError, Sendable {
    case responseTooLarge
    case malformedRow(line: Int)
    case duplicateJobID(SlurmJobID)

    public var errorDescription: String? {
        switch self {
        case .responseTooLarge: "Slurm 返回的数据过大。"
        case let .malformedRow(line): "Slurm 返回了无法识别的第 \(line) 行。"
        case let .duplicateJobID(jobID): "Slurm 返回了重复的作业编号 \(jobID.rawValue)。"
        }
    }
}

public enum SlurmParser {
    private static let maximumResponseBytes = 8 * 1_024 * 1_024
    private static let fieldCount = 13

    public static func queue(_ output: String) throws -> [SlurmJobSnapshot] {
        guard output.utf8.count <= maximumResponseBytes else {
            throw SlurmParserError.responseTooLarge
        }
        var jobs: [SlurmJobSnapshot] = []
        var seen = Set<SlurmJobID>()
        for (offset, rawLine) in output.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let fields = line.split(
                separator: Character(SlurmCommands.fieldDelimiter),
                omittingEmptySubsequences: false
            ).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count == fieldCount,
                let jobID = SlurmJobID(rawValue: fields[0]),
                isSafeDisplayField(fields[1]),
                SlurmValidation.isSafeIdentifier(fields[2]),
                let nodeCount = Int(fields[6]), nodeCount >= 0
            else { throw SlurmParserError.malformedRow(line: offset + 1) }
            guard seen.insert(jobID).inserted else {
                throw SlurmParserError.duplicateJobID(jobID)
            }
            for index in [3, 4, 5, 7, 8, 9, 10, 11] {
                guard isSafeDisplayField(fields[index]) else {
                    throw SlurmParserError.malformedRow(line: offset + 1)
                }
            }
            guard isSafeDisplayField(fields[12]) else {
                throw SlurmParserError.malformedRow(line: offset + 1)
            }
            jobs.append(SlurmJobSnapshot(
                jobID: jobID,
                name: fields[1],
                owner: fields[2],
                state: SlurmJobState(schedulerValue: fields[3]),
                reasonOrNodeList: fields[4],
                partition: fields[5],
                nodeCount: nodeCount,
                elapsed: fields[7],
                timeLimit: fields[8],
                startTime: optionalValue(fields[9]),
                submitTime: optionalValue(fields[10]),
                nodeList: optionalValue(fields[11]),
                comment: fields[12]
            ))
        }
        return jobs
    }

    private static func optionalValue(_ value: String) -> String? {
        switch value.uppercased() {
        case "", "N/A", "NONE", "UNKNOWN", "(NULL)": nil
        default: value
        }
    }

    private static func isSafeDisplayField(_ value: String) -> Bool {
        value.utf8.count <= 16_384
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

}
