import Foundation
import ImageIO
import Vision

struct MerlinTaskMetricScreenshotText: Equatable, Sendable {
    let text: String
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var centerY: Double { minY + height / 2 }
}

struct MerlinTaskMetricLegendValues: Equatable, Sendable {
    let current: Double
    let average: Double?
}

protocol MerlinTaskMetricScreenshotReading: Sendable {
    /// GPU values are percentages; memory values are bytes.
    func readings(
        for panel: MerlinTaskMetricPanel,
        imageData: Data
    ) async -> [String: MerlinTaskMetricLegendValues]
}

extension MerlinTaskMetricScreenshotReading {
    func reading(
        for panel: MerlinTaskMetricPanel,
        imageData: Data
    ) async -> MerlinTaskMetricLegendValues? {
        await readings(for: panel, imageData: imageData).values.first
    }
}

/// Reads current and average values from Grafana's fixed panel legend. One
/// screenshot may contain several task trials. Recognition is local to the
/// Mac; panel images and recognized labels are never persisted.
struct VisionMerlinTaskMetricScreenshotReader:
    MerlinTaskMetricScreenshotReading
{
    func readings(
        for panel: MerlinTaskMetricPanel,
        imageData: Data
    ) async -> [String: MerlinTaskMetricLegendValues] {
        let task: Task<
            [String: MerlinTaskMetricLegendValues], Never
        > = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return [:] }
            guard
                let source = CGImageSourceCreateWithData(
                    imageData as CFData,
                    nil
                ),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return [:] }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.003
            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                return [:]
            }
            guard !Task.isCancelled else { return [:] }
            let observations = (request.results ?? []).compactMap {
                observation -> MerlinTaskMetricScreenshotText? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let bounds = observation.boundingBox
                return MerlinTaskMetricScreenshotText(
                    text: candidate.string,
                    minX: bounds.minX,
                    minY: bounds.minY,
                    width: bounds.width,
                    height: bounds.height
                )
            }
            return MerlinTaskScreenshotLegendParser.readings(
                for: panel,
                observations: observations
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

enum MerlinTaskScreenshotLegendParser {
    static func value(
        for panel: MerlinTaskMetricPanel,
        observations: [MerlinTaskMetricScreenshotText]
    ) -> Double? {
        values(for: panel, observations: observations)?.current
    }

    static func values(
        for panel: MerlinTaskMetricPanel,
        observations: [MerlinTaskMetricScreenshotText]
    ) -> MerlinTaskMetricLegendValues? {
        readings(for: panel, observations: observations).values.first
    }

    static func readings(
        for panel: MerlinTaskMetricPanel,
        observations: [MerlinTaskMetricScreenshotText]
    ) -> [String: MerlinTaskMetricLegendValues] {
        let marker = switch panel {
        case .gpu: "gpu_util"
        case .memory: "mem_usage"
        }
        let labels = observations.filter {
            normalized($0.text).contains(marker)
        }
        var readings: [String: MerlinTaskMetricLegendValues] = [:]
        for label in labels.sorted(by: { $0.width > $1.width }) {
            let candidates = observations.compactMap {
                observation -> (Double, Double)? in
                guard
                    observation.minX > 0.75,
                    sameRow(label, observation),
                    let value = parsedValue(
                        observation.text,
                        panel: panel
                    )
                else { return nil }
                return (observation.minX, value)
            }
            let ordered = candidates.sorted { $0.0 < $1.0 }
            if let current = ordered.last {
                let reading = MerlinTaskMetricLegendValues(
                    current: current.1,
                    average: ordered.dropLast().last?.1
                )
                readings[trialID(in: label.text) ?? label.text] = reading
            }
        }
        if !readings.isEmpty {
            return readings
        }

        // The GPU panel has only one legend row. This still avoids confusing
        // the left-side Y-axis labels with the current value.
        guard panel == .gpu else { return [:] }
        let current = observations.compactMap {
            observation -> (Double, Double)? in
            guard
                observation.minX > 0.9,
                observation.minY < 0.1,
                let value = percentage(in: observation.text)
            else { return nil }
            return (observation.minX, value)
        }.max(by: { $0.0 < $1.0 })?.1
        guard let current else { return [:] }
        return [
            "unlabeled": MerlinTaskMetricLegendValues(
                current: current,
                average: nil
            ),
        ]
    }

    private static func trialID(in text: String) -> String? {
        let value = text.lowercased()
        for marker in ["trial-", "trialrun-"] {
            guard let range = value.range(of: marker) else { continue }
            let digits = value[range.upperBound...].prefix(while: \.isNumber)
            if !digits.isEmpty {
                return String(digits)
            }
        }
        return nil
    }

    private static func sameRow(
        _ lhs: MerlinTaskMetricScreenshotText,
        _ rhs: MerlinTaskMetricScreenshotText
    ) -> Bool {
        let tolerance = max(0.012, max(lhs.height, rhs.height) * 0.8)
        return abs(lhs.centerY - rhs.centerY) <= tolerance
    }

    private static func parsedValue(
        _ text: String,
        panel: MerlinTaskMetricPanel
    ) -> Double? {
        switch panel {
        case .gpu:
            percentage(in: text)
        case .memory:
            bytes(in: text)
        }
    }

    private static func percentage(in text: String) -> Double? {
        guard let percent = text.firstIndex(of: "%") else { return nil }
        return lastNumber(in: String(text[..<percent]))
    }

    private static func bytes(in text: String) -> Double? {
        let value = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).uppercased()
        let units: [(String, Double)] = [
            ("TIB", 1_099_511_627_776),
            ("GIB", 1_073_741_824),
            ("MIB", 1_048_576),
            ("KIB", 1_024),
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("KB", 1_000),
            ("B", 1),
        ]
        guard let unit = units.first(where: { value.contains($0.0) }) else {
            return nil
        }
        guard let number = lastNumber(in: value) else { return nil }
        let bytes = number * unit.1
        guard bytes.isFinite, bytes >= 0, bytes <= Double(UInt64.max) else {
            return nil
        }
        return bytes
    }

    private static func lastNumber(in text: String) -> Double? {
        var numbers: [String] = []
        var current = ""
        for character in text {
            if character.isNumber || character == "." || character == "," {
                current.append(character == "," ? "." : character)
            } else if !current.isEmpty {
                numbers.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            numbers.append(current)
        }
        return numbers.reversed().compactMap(Double.init).first
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: "_")
    }
}
