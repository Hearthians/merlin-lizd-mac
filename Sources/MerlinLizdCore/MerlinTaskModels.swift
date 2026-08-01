import Foundation

public enum MerlinTaskLifecycle: String, Codable, CaseIterable, Sendable {
    case active
    case failed
    case finished
}

public enum MerlinTaskStatus: String, Codable, Equatable, Sendable {
    case queued
    case started
    case running
    case failed
    case done
    case stopped
    case disabled
    case killed

    public var lifecycle: MerlinTaskLifecycle {
        switch self {
        case .queued, .started, .running:
            .active
        case .failed:
            .failed
        case .done, .stopped, .disabled, .killed:
            .finished
        }
    }
}

/// The deliberately small, persistable projection used by MerlinHub.
/// Raw job responses can contain credentials, environment variables, mounts,
/// and other operational details; none of those fields cross this boundary.
public struct MerlinTaskRun: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: MerlinTaskStatus
    public let lifecycle: MerlinTaskLifecycle
    public let createdAtMilliseconds: Int64
    public let startedAtMilliseconds: Int64?
    public let completedAtMilliseconds: Int64?
    public let totalRuntimeMilliseconds: Int64?

    public init(
        id: String,
        name: String,
        status: MerlinTaskStatus,
        createdAtMilliseconds: Int64,
        startedAtMilliseconds: Int64? = nil,
        completedAtMilliseconds: Int64? = nil,
        totalRuntimeMilliseconds: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        lifecycle = status.lifecycle
        self.createdAtMilliseconds = createdAtMilliseconds
        self.startedAtMilliseconds = startedAtMilliseconds
        self.completedAtMilliseconds = completedAtMilliseconds
        self.totalRuntimeMilliseconds = totalRuntimeMilliseconds
    }

    public func runtimeSeconds(at date: Date) -> TimeInterval? {
        if lifecycle == .active {
            guard let startedAtMilliseconds else { return nil }
            let nowMilliseconds = date.timeIntervalSince1970 * 1_000
            return max(
                0,
                nowMilliseconds - Double(startedAtMilliseconds)
            ) / 1_000
        }
        if let totalRuntimeMilliseconds {
            return Double(totalRuntimeMilliseconds) / 1_000
        }
        guard
            let startedAtMilliseconds,
            let completedAtMilliseconds
        else { return nil }
        return Double(max(
            0,
            completedAtMilliseconds - startedAtMilliseconds
        )) / 1_000
    }
}

public struct MerlinTaskSnapshot: Codable, Equatable, Sendable {
    public let runs: [MerlinTaskRun]
    public let refreshedAt: Date

    public init(runs: [MerlinTaskRun], refreshedAt: Date) {
        self.runs = runs
        self.refreshedAt = refreshedAt
    }

    public static func presenting(
        _ runs: [MerlinTaskRun],
        refreshedAt: Date,
        historyLimit: Int = 20
    ) -> MerlinTaskSnapshot {
        precondition(historyLimit >= 0)
        let sorted = runs.sorted { lhs, rhs in
            if lhs.createdAtMilliseconds != rhs.createdAtMilliseconds {
                return lhs.createdAtMilliseconds > rhs.createdAtMilliseconds
            }
            return lhs.id < rhs.id
        }
        let active = sorted.filter { $0.lifecycle == .active }
        let failed = sorted.filter { $0.lifecycle == .failed }
            .prefix(historyLimit)
        let finished = sorted.filter { $0.lifecycle == .finished }
            .prefix(historyLimit)
        return MerlinTaskSnapshot(
            runs: active + failed + finished,
            refreshedAt: refreshedAt
        )
    }

    public func runs(in lifecycle: MerlinTaskLifecycle) -> [MerlinTaskRun] {
        runs.filter { $0.lifecycle == lifecycle }
    }
}

public struct MerlinTaskPage: Equatable, Sendable {
    public let runs: [MerlinTaskRun]
    public let total: Int
    public let itemCount: Int

    public init(runs: [MerlinTaskRun], total: Int, itemCount: Int) {
        self.runs = runs
        self.total = total
        self.itemCount = itemCount
    }
}
