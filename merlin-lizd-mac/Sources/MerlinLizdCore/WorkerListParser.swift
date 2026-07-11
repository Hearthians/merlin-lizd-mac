import Foundation

public enum WorkerListParserError: Error, Equatable, Sendable {
    case missingHeader
    case malformedRow
}

public enum WorkerListParser {
    private static let expectedHeader = [
        "id", "cpu", "mem", "gpu", "gpuType", "podIP", "port", "createdAt", "webshell"
    ]

    public static func parse(_ output: String) throws -> [Worker] {
        let lines = output.split(whereSeparator: \Character.isNewline)
        guard let headerIndex = lines.firstIndex(where: isHeader) else {
            throw WorkerListParserError.missingHeader
        }
        let layout = columnStarts(in: lines[headerIndex])
        var workers: [Worker] = []
        for line in lines[lines.index(after: headerIndex)...] {
            if let worker = parseRow(line, columnStarts: layout) {
                workers.append(worker)
            } else if line.first(where: { !$0.isWhitespace })?.isNumber == true {
                throw WorkerListParserError.malformedRow
            }
        }
        return workers
    }

    private static func isHeader(_ line: Substring) -> Bool {
        let columns = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
        return columns == expectedHeader
    }

    private static func parseRow(_ line: Substring, columnStarts: [Int]) -> Worker? {
        let characters = Array(line)
        let values = columnStarts.indices.map { index -> String in
            let lowerBound = min(columnStarts[index], characters.count)
            let nextStart = index + 1 < columnStarts.count
                ? columnStarts[index + 1]
                : characters.count
            let upperBound = min(nextStart, characters.count)
            guard lowerBound < upperBound else { return "" }
            return String(characters[lowerBound..<upperBound])
                .trimmingCharacters(in: .whitespaces)
        }
        guard
            values.count == expectedHeader.count,
            let cpu = Int(values[1]),
            let memory = Int(values[2]),
            let gpuCount = Int(values[3]),
            let port = Int(values[6])
        else {
            return nil
        }

        let gpuType = values[4].isEmpty ? nil : values[4]
        let podIP = values[5].isEmpty ? nil : values[5]

        return Worker(
            id: values[0],
            cpuCores: cpu,
            memoryGiB: memory,
            gpuCount: gpuCount,
            gpuType: gpuType,
            podIP: podIP,
            port: port,
            createdAt: values[7],
            webshellURL: URL(string: values[8])
        )
    }

    private static func columnStarts(in header: Substring) -> [Int] {
        let text = String(header)
        var starts: [Int] = []
        var searchStart = text.startIndex

        for column in expectedHeader {
            guard let range = text.range(
                of: column,
                range: searchStart..<text.endIndex
            ) else {
                return []
            }
            starts.append(text.distance(from: text.startIndex, to: range.lowerBound))
            searchStart = range.upperBound
        }
        return starts
    }
}
