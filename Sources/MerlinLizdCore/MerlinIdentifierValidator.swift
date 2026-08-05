import Foundation

/// One trust boundary for identifiers that may become local argv or part of a
/// deliberately constrained remote command. Callers still pass plain strings,
/// but every command-producing path shares these exact rules.
public enum MerlinIdentifierValidator {
    public static let merlinSSHProxyPort = 22_222

    public static func isSSHAlias(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#)
    }

    public static func isWorkerSSHProxyDestination(
        _ value: String,
        workerID: String
    ) -> Bool {
        guard isWorkerID(workerID) else { return false }
        let escapedWorkerID = NSRegularExpression.escapedPattern(for: workerID)
        return matches(
            value,
            pattern: #"^"# + escapedWorkerID
                + #"\.[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.worker@"#
                + #"merlin-ssh-proxy-[A-Za-z0-9-]{1,63}\.byted\.org$"#
        )
    }

    public static func isDevboxSSHProxyDestination(
        _ value: String,
        devboxSID: String
    ) -> Bool {
        let prefix = "dbx_"
        guard devboxSID.hasPrefix(prefix) else { return false }
        let numericID = String(devboxSID.dropFirst(prefix.count))
        guard isWorkerID(numericID) else { return false }
        let escapedID = NSRegularExpression.escapedPattern(for: numericID)
        return matches(
            value,
            pattern: #"^"# + escapedID
                + #"\.[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.ws@"#
                + #"merlin-ssh-proxy-[A-Za-z0-9-]{1,63}\.byted\.org$"#
        )
    }

    public static func isTaskSSHProxyDestination(
        _ value: String,
        runID: String,
        instanceID: String
    ) -> Bool {
        guard
            isJobRunID(runID),
            isTaskInstanceID(instanceID)
        else {
            return false
        }
        let escapedRunID = NSRegularExpression.escapedPattern(for: runID)
        let escapedInstanceID = NSRegularExpression.escapedPattern(
            for: instanceID
        )
        return matches(
            value,
            pattern: #"^"# + escapedRunID + #"\."# + escapedInstanceID
                + #"\.job\.[A-Za-z0-9][A-Za-z0-9._-]{0,127}@"#
                + #"merlin-ssh-proxy-[A-Za-z0-9-]{1,63}\.byted\.org$"#
        )
    }

    public static func sshPort(forConnectionTarget value: String) -> Int? {
        guard matches(
            value,
            pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}@"#
                + #"merlin-ssh-proxy-[A-Za-z0-9-]{1,63}\.byted\.org$"#
        ) else {
            return nil
        }
        return merlinSSHProxyPort
    }

    public static func isSSHConnectionTarget(_ value: String) -> Bool {
        isSSHAlias(value)
            || matches(
                value,
                pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}@"#
                    + #"[A-Za-z0-9][A-Za-z0-9.-]{0,252}$"#
            )
    }

    public static func isDevboxSID(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#)
    }

    public static func isWorkerID(_ value: String) -> Bool {
        matches(value, pattern: #"^[0-9]+$"#)
    }

    public static func isJobRunID(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#)
    }

    public static func isMerlinUsername(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#)
    }

    public static func isTaskInstanceID(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$"#)
    }

    public static func isTmuxSessionName(_ value: String) -> Bool {
        matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#)
    }

    public static func isTmuxWorkingDirectory(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.unicodeScalars.count <= 1_024
            && !value.unicodeScalars.contains(where: {
                CharacterSet.newlines.contains($0) || $0.value == 0
            })
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return false
        }
        return range == value.startIndex..<value.endIndex
    }
}
