import Foundation

enum MerlinTaskMetricPanel: Int, CaseIterable, Hashable, Sendable {
    case memory = 3
    case gpu = 7
}

/// Converts Merlin's generic trial dashboard URL into the Arnold Role
/// dashboard URL used for task telemetry. A canonical variable set avoids
/// carrying generic-dashboard variables (including raw `%` wildcards) into
/// the Role dashboard.
enum MerlinTaskGrafanaURLBuilder {
    private static let roleDashboardPath =
        "/d/JiidrBwGzrole/arnold-shi-li-jian-kong-kan-ban-roleji-bie"
    private static let sampleWindow: TimeInterval = 15 * 60

    static func rolePanelURL(
        from rawURL: String,
        role: String,
        panel: MerlinTaskMetricPanel,
        startingAtMilliseconds: Int64? = nil,
        endingAt: Date = Date()
    ) -> URL? {
        guard
            let components = components(from: rawURL),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "grafana.byted.org"
        else { return nil }
        let sourceItems = components.queryItems ?? []
        guard
            let cluster = exactValue("var-cluster", in: sourceItems),
            let dataCenter = exactValue("var-dc", in: sourceItems),
            let trialID = nonemptyValue(
                "var-target_arnold_trial_id",
                in: sourceItems
            )
        else { return nil }

        return buildRolePanelURL(
            cluster: cluster,
            dataCenter: dataCenter,
            trialIDs: [trialID],
            jobPSM: nonemptyValue("var-job_psm", in: sourceItems),
            role: role,
            panel: panel,
            startingAtMilliseconds: startingAtMilliseconds,
            endingAt: endingAt
        )
    }

    static func rolePanelURL(
        cluster: String,
        dataCenter: String,
        trialIDs: [String],
        role: String,
        panel: MerlinTaskMetricPanel,
        startingAtMilliseconds: Int64? = nil,
        endingAt: Date = Date()
    ) -> URL? {
        buildRolePanelURL(
            cluster: cluster,
            dataCenter: dataCenter,
            trialIDs: trialIDs,
            jobPSM: nil,
            role: role,
            panel: panel,
            startingAtMilliseconds: startingAtMilliseconds,
            endingAt: endingAt
        )
    }

    private static func buildRolePanelURL(
        cluster: String,
        dataCenter: String,
        trialIDs: [String],
        jobPSM: String?,
        role: String,
        panel: MerlinTaskMetricPanel,
        startingAtMilliseconds: Int64?,
        endingAt: Date
    ) -> URL? {
        let cluster = cluster.trimmingCharacters(in: .whitespacesAndNewlines)
        let dataCenter = dataCenter.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let trialIDs = trialIDs.reduce(into: [String]()) { values, rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !values.contains(value) {
                values.append(value)
            }
        }
        guard
            !cluster.isEmpty,
            cluster.caseInsensitiveCompare("All") != .orderedSame,
            !dataCenter.isEmpty,
            dataCenter.caseInsensitiveCompare("All") != .orderedSame,
            !role.isEmpty,
            !trialIDs.isEmpty
        else { return nil }

        let endMilliseconds = Int64(
            endingAt.timeIntervalSince1970 * 1_000
        )
        guard endMilliseconds > 0 else { return nil }
        let fallbackStart = endMilliseconds - Int64(sampleWindow * 1_000)
        let startMilliseconds = if
            let startingAtMilliseconds,
            startingAtMilliseconds > 0,
            startingAtMilliseconds < endMilliseconds
        {
            startingAtMilliseconds
        } else {
            fallbackStart
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "grafana.byted.org"
        components.path = roleDashboardPath
        var queryItems = [
            URLQueryItem(name: "orgId", value: "1"),
            URLQueryItem(name: "var-cluster", value: cluster),
            URLQueryItem(name: "var-dc", value: dataCenter),
            URLQueryItem(
                name: "var-target_arnold_trial_id",
                value: trialIDs.joined(separator: "|")
            ),
            URLQueryItem(name: "var-target_arnold_role", value: role),
            URLQueryItem(name: "var-task_family", value: "arnold"),
            URLQueryItem(
                name: "var-metricsBytedIsGroupByRegion__",
                value: "true"
            ),
            URLQueryItem(
                name: "var-metricsBytedVRegion__",
                value: "China-North"
            ),
            URLQueryItem(name: "var-hostnum", value: "All"),
            URLQueryItem(name: "var-eth_name", value: "All"),
            URLQueryItem(name: "var-hdfs_task_family", value: "arnold"),
            URLQueryItem(name: "var-hdfs_tenant", value: "default"),
            URLQueryItem(name: "var-hdfs_datasource", value: "bytetsd"),
            URLQueryItem(name: "from", value: String(startMilliseconds)),
            URLQueryItem(name: "to", value: String(endMilliseconds)),
            URLQueryItem(name: "viewPanel", value: String(panel.rawValue)),
        ]
        if let jobPSM, !jobPSM.isEmpty {
            queryItems.insert(
                URLQueryItem(name: "var-job_psm", value: jobPSM),
                at: 3
            )
        }

        components.queryItems = queryItems
        return components.url
    }

    private static func components(from rawURL: String) -> URLComponents? {
        if let components = URLComponents(string: rawURL) {
            return components
        }
        let escaped = rawURL.replacingOccurrences(
            of: "%(?![0-9A-Fa-f]{2})",
            with: "%25",
            options: .regularExpression
        )
        return URLComponents(string: escaped)
    }

    private static func exactValue(
        _ name: String,
        in items: [URLQueryItem]
    ) -> String? {
        guard let value = nonemptyValue(name, in: items) else { return nil }
        return value.caseInsensitiveCompare("All") == .orderedSame
            ? nil
            : value
    }

    private static func nonemptyValue(
        _ name: String,
        in items: [URLQueryItem]
    ) -> String? {
        let value = items.last { $0.name == name }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

}
