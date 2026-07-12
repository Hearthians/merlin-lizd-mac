import Foundation

/// Metric roles used by the app when discovering a Merlin Grafana dashboard.
/// Panel identifiers are intentionally absent: dashboards may be revised while
/// retaining the same user-facing metric semantics.
public enum GrafanaMetricKind: String, CaseIterable, Hashable, Sendable {
    case gpuUtilization
    case gpuMemory
    case cpu
    case memory
    case temperature
}

public struct GrafanaPanelReference: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let dashboardUID: String?

    public init(id: Int, title: String, dashboardUID: String? = nil) {
        self.id = id
        self.title = title
        self.dashboardUID = dashboardUID
    }
}

/// A semantic projection of `merlin-cli grafana describe`. Callers request the
/// metric they need rather than depending on a dashboard-specific panel ID.
public struct GrafanaPanelCatalog: Equatable, Sendable {
    private let panels: [GrafanaMetricKind: GrafanaPanelReference]

    init(panels: [GrafanaMetricKind: GrafanaPanelReference]) {
        self.panels = panels
    }

    public func panel(for metric: GrafanaMetricKind) -> GrafanaPanelReference? {
        panels[metric]
    }

    public var availableMetrics: [GrafanaMetricKind] {
        GrafanaMetricKind.allCases.filter { panels[$0] != nil }
    }
}

public struct GrafanaMetricPoint: Equatable, Sendable {
    public let timestamp: Date
    public let value: Double

    public init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// A data-source-independent time series. Series with the same metric, legend,
/// and tags are merged; their points are sorted and duplicate timestamps use
/// the last finite observation returned by Grafana.
public struct GrafanaMetricSeries: Equatable, Sendable {
    public let metric: String
    public let legend: String
    public let tags: [String: String]
    /// Safe projection of the target's `multiFieldExpr` from the outer Merlin
    /// CLI payload (for example `usage`, `limit`, or `used`). Grafana starts
    /// `query.index` at zero for every independently executed target, so this
    /// field is the authoritative way to distinguish otherwise identical
    /// CPU and memory series returned by `grafana panel-data`.
    public let targetField: String?
    /// Grafana target index from the safe `query.index` projection. This keeps
    /// legacy/synthetic responses distinct without exposing the raw query.
    /// Real Merlin responses normally reset this value for every target; use
    /// `targetField` when it is present.
    public let queryIndex: Int?
    public let points: [GrafanaMetricPoint]

    public init(
        metric: String,
        legend: String,
        tags: [String: String],
        targetField: String? = nil,
        queryIndex: Int? = nil,
        points: [GrafanaMetricPoint]
    ) {
        self.metric = metric
        self.legend = legend
        self.tags = tags
        self.targetField = targetField
        self.queryIndex = queryIndex
        self.points = points
    }
}

public enum GrafanaMetricsParseError: Error, Equatable, Sendable {
    case invalidJSON
}

public enum GrafanaDescribeParser {
    public static func parse(_ output: String) throws -> GrafanaPanelCatalog {
        let root = try decodeJSON(output)
        guard case let .object(rootObject) = root else {
            return GrafanaPanelCatalog(panels: [:])
        }

        let dashboards = rootObject["dashboards"]?.arrayValue ?? []
        var candidates: [GrafanaMetricKind: PanelCandidate] = [:]

        for dashboard in dashboards {
            guard case let .object(dashboardObject) = dashboard else { continue }
            let dashboardUID = dashboardObject["dashboard_uid"]?.stringValue
            let rows = dashboardObject["dashboard_panels"]?.arrayValue ?? []
            for row in rows {
                collectPanels(
                    from: row,
                    dashboardUID: dashboardUID,
                    into: &candidates
                )
            }
        }

        return GrafanaPanelCatalog(panels: candidates.mapValues(\.panel))
    }

    private static func collectPanels(
        from value: JSONValue,
        dashboardUID: String?,
        into candidates: inout [GrafanaMetricKind: PanelCandidate]
    ) {
        switch value {
        case let .array(values):
            for value in values {
                collectPanels(
                    from: value,
                    dashboardUID: dashboardUID,
                    into: &candidates
                )
            }
        case let .object(object):
            if
                let id = object["id"]?.integerValue,
                let title = object["title"]?.stringValue
            {
                for metric in GrafanaMetricKind.allCases {
                    guard let score = matchScore(title: title, metric: metric) else {
                        continue
                    }
                    let panel = GrafanaPanelReference(
                        id: id,
                        title: title,
                        dashboardUID: dashboardUID
                    )
                    let candidate = PanelCandidate(panel: panel, score: score)
                    if shouldReplace(candidates[metric], with: candidate) {
                        candidates[metric] = candidate
                    }
                }
            }

            // Grafana rows and nested panels both use this field. Restrict
            // recursion to it so query targets cannot be mistaken for panels.
            if let nested = object["panels"] {
                collectPanels(
                    from: nested,
                    dashboardUID: dashboardUID,
                    into: &candidates
                )
            }
        default:
            break
        }
    }

    private static func shouldReplace(
        _ existing: PanelCandidate?,
        with candidate: PanelCandidate
    ) -> Bool {
        guard let existing else { return true }
        if candidate.score != existing.score {
            return candidate.score > existing.score
        }
        if candidate.panel.title != existing.panel.title {
            return candidate.panel.title < existing.panel.title
        }
        return candidate.panel.id < existing.panel.id
    }

    private static func matchScore(
        title: String,
        metric: GrafanaMetricKind
    ) -> Int? {
        let normalized = normalizedTitle(title)
        let words = Set(normalized.split(separator: " ").map(String.init))
        let containsGPU = words.contains("gpu")
        let containsMemory = words.contains("memory")
            || words.contains("mem")
            || normalized.contains("显存")
            || normalized.contains("内存")
            || words.contains("hbm")
        let containsBandwidth = words.contains("bandwidth")
            || normalized.contains("throughput")
            || normalized.contains("带宽")
        let containsFilewatch = normalized.contains("filewatch")
        let containsAda = words.contains("ada")

        switch metric {
        case .gpuUtilization:
            guard containsGPU, !containsMemory, !containsBandwidth else {
                return nil
            }
            let excluded = [
                "temperature", "temp", "power", "clock", "pcie", "nvlink",
                "tensor", "engine", "ecc",
            ]
            guard !excluded.contains(where: words.contains) else { return nil }
            if normalized.contains("dutycycle")
                || normalized.contains("duty cycle")
            {
                return 100
            }
            if normalized.contains("gpu utilization")
                || normalized.contains("gpu 利用率")
            {
                return 95
            }
            if normalized.contains("device util") {
                return containsAda ? 70 : 85
            }
            return words.contains("util") || words.contains("usage") ? 80 : nil

        case .gpuMemory:
            guard containsGPU, containsMemory, !containsBandwidth else {
                return nil
            }
            if normalized == "gpu memory" { return 100 }
            if normalized.contains("gpu memory usage")
                || normalized.contains("gpu 显存")
            {
                return 95
            }
            return containsAda ? 70 : 85

        case .cpu:
            guard words.contains("cpu") else { return nil }
            if normalized == "cpu cores" { return 100 }
            if normalized == "cpu" || normalized == "cpu usage" { return 95 }
            return containsFilewatch ? 60 : 80

        case .memory:
            guard containsMemory, !containsGPU, !containsAda else { return nil }
            if normalized == "memory" { return 100 }
            if normalized == "memory usage" { return 95 }
            return containsFilewatch ? 60 : 80

        case .temperature:
            guard containsGPU else { return nil }
            if normalized == "gpu temperature" { return 100 }
            if words.contains("temperature") || words.contains("temp")
                || normalized.contains("温度")
            {
                return 90
            }
            return nil
        }
    }

    private static func normalizedTitle(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || CharacterSet.letters.contains(scalar)
                    ? String(scalar)
                    : " "
            }
            .joined()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private struct PanelCandidate {
        let panel: GrafanaPanelReference
        let score: Int
    }
}

public enum GrafanaPanelDataParser {
    public static func parse(_ output: String) throws -> [GrafanaMetricSeries] {
        let total = try decodePanelDataResponse(output).total

        var accumulator = SeriesAccumulator()
        for item in total {
            guard let data = item.data else { continue }
            parseDataNode(
                data,
                inheritedTargetField: targetField(item.payload),
                inheritedQueryIndex: queryIndex(item.query),
                into: &accumulator
            )
        }
        return accumulator.finishedSeries()
    }

    private static func parseDataNode(
        _ value: JSONValue,
        inheritedTargetField: String?,
        inheritedQueryIndex: Int?,
        into accumulator: inout SeriesAccumulator
    ) {
        switch value {
        case let .array(series):
            for value in series {
                parseOpenTSDBSeries(
                    value,
                    inheritedTargetField: inheritedTargetField,
                    inheritedQueryIndex: inheritedQueryIndex,
                    into: &accumulator
                )
            }
        case let .object(object):
            // Lookup responses have `results` but no metric/dps and can be very
            // large. Ignore them before considering ClickHouse data.
            if object["results"] != nil { return }
            if object["metric"] != nil, object["dps"] != nil {
                parseOpenTSDBSeries(
                    value,
                    inheritedTargetField: inheritedTargetField,
                    inheritedQueryIndex: inheritedQueryIndex,
                    into: &accumulator
                )
                return
            }
            if object["meta"] != nil, object["data"] != nil {
                parseClickHouse(
                    object,
                    targetField: inheritedTargetField,
                    queryIndex: inheritedQueryIndex,
                    into: &accumulator
                )
            }
        default:
            break
        }
    }

    private static func parseOpenTSDBSeries(
        _ value: JSONValue,
        inheritedTargetField: String?,
        inheritedQueryIndex: Int?,
        into accumulator: inout SeriesAccumulator
    ) {
        guard
            case let .object(object) = value,
            let metric = object["metric"]?.stringValue,
            !metric.isEmpty,
            case let .object(dps)? = object["dps"]
        else { return }

        let tags = stringDictionary(object["tags"])
        let legend = object["legend"]?.stringValue
            ?? tags["legend"]
            ?? tags["alias"]
            ?? gpuLegend(tags)
            ?? metric
        let queryIndex = queryIndex(object["query"]) ?? inheritedQueryIndex

        for (rawTimestamp, rawValue) in dps {
            guard
                let timestamp = timestamp(from: .string(rawTimestamp)),
                let value = finiteDouble(rawValue)
            else { continue }
            accumulator.add(
                metric: metric,
                legend: legend,
                tags: tags,
                targetField: inheritedTargetField,
                queryIndex: queryIndex,
                timestamp: timestamp,
                value: value
            )
        }
    }

    private static func parseClickHouse(
        _ object: [String: JSONValue],
        targetField: String?,
        queryIndex: Int?,
        into accumulator: inout SeriesAccumulator
    ) {
        let columns = parseColumns(object["meta"])
        guard let rows = object["data"]?.arrayValue else { return }

        for rowValue in rows {
            let row: [String: JSONValue]
            switch rowValue {
            case let .object(objectRow):
                row = objectRow
            case let .array(values) where values.count == columns.count:
                row = Dictionary(uniqueKeysWithValues: zip(
                    columns.map(\.name),
                    values
                ))
            default:
                continue
            }

            guard
                let timestampColumn = timestampColumn(in: row, columns: columns),
                let timestamp = timestamp(from: row[timestampColumn])
            else { continue }

            let legendColumn = legendColumn(in: row)
            let explicitLegend = legendColumn.flatMap { row[$0]?.stringValue }
            let metricColumns = valueColumns(
                in: row,
                columns: columns,
                excluding: Set([timestampColumn, legendColumn].compactMap { $0 })
            )

            let tags = clickHouseTags(
                row: row,
                excluding: Set(
                    [timestampColumn, legendColumn].compactMap { $0 }
                        + metricColumns
                )
            )
            for metricColumn in metricColumns {
                guard let value = finiteDouble(row[metricColumn]) else { continue }
                accumulator.add(
                    metric: metricColumn,
                    legend: explicitLegend ?? metricColumn,
                    tags: tags,
                    targetField: targetField,
                    queryIndex: queryIndex,
                    timestamp: timestamp,
                    value: value
                )
            }
        }
    }

    private static func parseColumns(_ value: JSONValue?) -> [Column] {
        guard let values = value?.arrayValue else { return [] }
        return values.compactMap { value in
            guard
                case let .object(object) = value,
                let name = object["name"]?.stringValue
            else { return nil }
            return Column(name: name, type: object["type"]?.stringValue ?? "")
        }
    }

    private static func timestampColumn(
        in row: [String: JSONValue],
        columns: [Column]
    ) -> String? {
        let preferredNames = ["t", "time", "timestamp", "ts", "datetime"]
        for preferred in preferredNames {
            if let name = row.keys.first(where: {
                normalizedColumnName($0) == preferred
            }) {
                return name
            }
        }
        if let column = columns.first(where: {
            let type = $0.type.lowercased()
            return type.contains("datetime") || type.contains("timestamp")
        }), row[column.name] != nil {
            return column.name
        }
        return nil
    }

    private static func legendColumn(in row: [String: JSONValue]) -> String? {
        let preferredNames = ["legend", "series", "alias", "metric", "name"]
        return preferredNames.compactMap { preferred in
            row.keys.first {
                normalizedColumnName($0) == preferred
                    && row[$0]?.stringValue != nil
            }
        }.first
    }

    private static func valueColumns(
        in row: [String: JSONValue],
        columns: [Column],
        excluding excluded: Set<String>
    ) -> [String] {
        let orderedNames = columns.isEmpty
            ? row.keys.sorted()
            : columns.map(\.name).filter { row[$0] != nil }
        return orderedNames.filter { name in
            guard !excluded.contains(name), !isTagColumn(name) else { return false }
            return finiteDouble(row[name]) != nil
        }
    }

    private static func clickHouseTags(
        row: [String: JSONValue],
        excluding excluded: Set<String>
    ) -> [String: String] {
        var tags: [String: String] = [:]
        for (name, value) in row where !excluded.contains(name) {
            if let string = scalarString(value) {
                tags[name] = string
            }
        }
        return tags
    }

    private static func isTagColumn(_ name: String) -> Bool {
        let normalized = normalizedColumnName(name)
        let identifiers: Set<String> = [
            "id", "index", "gpuid", "gpuindex", "dockergpuid",
            "device", "deviceid", "deviceindex", "taskid", "taskindex",
            "trialid", "podid", "uuid", "gpuuuid",
        ]
        return identifiers.contains(normalized)
            || normalized.hasSuffix("uuid")
    }

    private static func normalizedColumnName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func stringDictionary(_ value: JSONValue?) -> [String: String] {
        guard case let .object(object)? = value else { return [:] }
        return object.reduce(into: [:]) { result, element in
            if let value = scalarString(element.value) {
                result[element.key] = value
            }
        }
    }

    private static func scalarString(_ value: JSONValue) -> String? {
        switch value {
        case let .string(value):
            value
        case let .number(value) where value.isFinite:
            if
                value.rounded() == value,
                value >= Double(Int64.min),
                value <= Double(Int64.max)
            {
                String(Int64(value))
            } else {
                String(value)
            }
        case let .bool(value):
            String(value)
        default:
            nil
        }
    }

    private static func gpuLegend(_ tags: [String: String]) -> String? {
        let gpuKeys = ["dockerGPUId", "gpu_id", "gpu", "device", "index"]
        for key in gpuKeys {
            if let value = tags[key] {
                return "GPU \(value)"
            }
        }
        return nil
    }

    private static func queryIndex(_ value: JSONValue?) -> Int? {
        guard case let .object(query)? = value else { return nil }
        if let index = query["index"]?.integerValue {
            return index >= 0 ? index : nil
        }
        if
            let raw = query["index"]?.stringValue,
            let index = Int(raw),
            index >= 0
        {
            return index
        }
        return nil
    }

    /// `merlin-cli grafana panel-data` returns each panel target as a separate
    /// item. Its public `data[].query.index` restarts at zero in each item, but
    /// the outer JSON-encoded payload retains the selected multi-field name.
    /// Keep only a short identifier so raw queries, pod names, and routing
    /// variables can never escape through the parsed model.
    private static func targetField(_ value: JSONValue?) -> String? {
        let payload: JSONValue
        switch value {
        case let .string(raw):
            guard let decoded = try? decodeJSON(raw) else { return nil }
            payload = decoded
        case let .object(object):
            payload = .object(object)
        default:
            return nil
        }
        guard
            case let .object(object) = payload,
            let queries = object["queries"]?.arrayValue
        else { return nil }

        let fields = Set(queries.compactMap { query -> String? in
            guard
                case let .object(queryObject) = query,
                let raw = queryObject["multiFieldExpr"]?.stringValue
            else { return nil }
            return safeTargetField(raw)
        })
        return fields.count == 1 ? fields.first : nil
    }

    private static func safeTargetField(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let isSafe = value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...122, 45, 46, 95:
                true
            default:
                false
            }
        }
        return isSafe ? value : nil
    }

    private static func timestamp(from value: JSONValue?) -> Date? {
        guard let value else { return nil }
        switch value {
        case let .number(raw):
            return dateFromUnixTimestamp(raw)
        case let .string(raw):
            if let numeric = Double(raw), numeric.isFinite {
                return dateFromUnixTimestamp(numeric)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        default:
            return nil
        }
    }

    private static func dateFromUnixTimestamp(_ raw: Double) -> Date? {
        guard raw.isFinite, raw >= 0 else { return nil }
        let seconds = raw >= 100_000_000_000 ? raw / 1_000 : raw
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func finiteDouble(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        let result: Double?
        switch value {
        case let .number(number):
            result = number
        case let .string(string):
            result = Double(string)
        default:
            result = nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    private struct Column {
        let name: String
        let type: String
    }
}

/// Narrow decoding projection for a `grafana panel-data` response. Lookup
/// entries can contain tens of thousands of `results`; detect that key and
/// skip its value instead of materializing the entire lookup tree as
/// `JSONValue` alongside the actual time series.
private struct PanelDataResponse: Decodable {
    let total: [Item]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent([Item].self, forKey: .total) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case total
    }

    struct Item: Decodable {
        let payload: JSONValue?
        let query: JSONValue?
        let data: JSONValue?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            payload = try container.decodeIfPresent(
                JSONValue.self,
                forKey: .payload
            )
            query = try container.decodeIfPresent(JSONValue.self, forKey: .query)
            switch try container.decodeIfPresent(
                ProjectedData.self,
                forKey: .data
            ) {
            case let .value(value):
                data = value
            case .ignored, nil:
                data = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case payload
            case query
            case data
        }
    }

    private enum ProjectedData: Decodable {
        case value(JSONValue)
        case ignored

        init(from decoder: Decoder) throws {
            if
                let container = try? decoder.container(
                    keyedBy: LookupCodingKeys.self
                ),
                container.contains(.results)
            {
                self = .ignored
                return
            }
            self = .value(try JSONValue(from: decoder))
        }

        private enum LookupCodingKeys: String, CodingKey {
            case results
        }
    }
}

private struct SeriesAccumulator {
    private struct Identity: Hashable {
        let metric: String
        let legend: String
        let tags: String
        let targetField: String?
        let queryIndex: Int?
    }

    private struct PendingSeries {
        let metric: String
        let legend: String
        let tags: [String: String]
        let targetField: String?
        let queryIndex: Int?
        var valuesByTimestamp: [Date: Double]
    }

    private var series: [Identity: PendingSeries] = [:]

    mutating func add(
        metric: String,
        legend: String,
        tags: [String: String],
        targetField: String?,
        queryIndex: Int?,
        timestamp: Date,
        value: Double
    ) {
        guard value.isFinite else { return }
        let tagSignature = tags.keys.sorted().map {
            "\($0)=\(tags[$0] ?? "")"
        }.joined(separator: "\u{1f}")
        let identity = Identity(
            metric: metric,
            legend: legend,
            tags: tagSignature,
            targetField: targetField,
            queryIndex: queryIndex
        )
        if series[identity] == nil {
            series[identity] = PendingSeries(
                metric: metric,
                legend: legend,
                tags: tags,
                targetField: targetField,
                queryIndex: queryIndex,
                valuesByTimestamp: [:]
            )
        }
        series[identity]?.valuesByTimestamp[timestamp] = value
    }

    func finishedSeries() -> [GrafanaMetricSeries] {
        series.values
            .filter { !$0.valuesByTimestamp.isEmpty }
            .map { pending in
                GrafanaMetricSeries(
                    metric: pending.metric,
                    legend: pending.legend,
                    tags: pending.tags,
                    targetField: pending.targetField,
                    queryIndex: pending.queryIndex,
                    points: pending.valuesByTimestamp
                        .map(GrafanaMetricPoint.init(timestamp:value:))
                        .sorted { $0.timestamp < $1.timestamp }
                )
            }
            .sorted { lhs, rhs in
                if lhs.metric != rhs.metric { return lhs.metric < rhs.metric }
                if lhs.targetField != rhs.targetField {
                    return (lhs.targetField ?? "~") < (rhs.targetField ?? "~")
                }
                if lhs.queryIndex != rhs.queryIndex {
                    return (lhs.queryIndex ?? Int.max) < (rhs.queryIndex ?? Int.max)
                }
                if lhs.legend != rhs.legend { return lhs.legend < rhs.legend }
                return tagSignature(lhs.tags) < tagSignature(rhs.tags)
            }
    }

    private func tagSignature(_ tags: [String: String]) -> String {
        tags.keys.sorted().map { "\($0)=\(tags[$0] ?? "")" }
            .joined(separator: "\u{1f}")
    }
}

private enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard
            case let .number(value) = self,
            value.isFinite,
            value.rounded() == value,
            value >= Double(Int.min),
            value <= Double(Int.max)
        else { return nil }
        return Int(value)
    }
}

private func decodeJSON(_ output: String) throws -> JSONValue {
    guard let data = output.data(using: .utf8) else {
        throw GrafanaMetricsParseError.invalidJSON
    }
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "Infinity",
        negativeInfinity: "-Infinity",
        nan: "NaN"
    )
    do {
        return try decoder.decode(JSONValue.self, from: data)
    } catch {
        throw GrafanaMetricsParseError.invalidJSON
    }
}

private func decodePanelDataResponse(
    _ output: String
) throws -> PanelDataResponse {
    guard let data = output.data(using: .utf8) else {
        throw GrafanaMetricsParseError.invalidJSON
    }
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "Infinity",
        negativeInfinity: "-Infinity",
        nan: "NaN"
    )
    do {
        return try decoder.decode(PanelDataResponse.self, from: data)
    } catch {
        throw GrafanaMetricsParseError.invalidJSON
    }
}
