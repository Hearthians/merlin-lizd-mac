import Foundation

public enum RemoteEditorService {
    /// `hostname` and `serverAddress` belong to the authenticated terminal
    /// connection, not an arbitrary destination supplied by the remote helper.
    public static func resolve(
        sshDestination: String,
        absolutePath: String,
        kind: RemoteEditorDestination.Kind,
        hostname: String,
        serverAddress: String,
        pinnedEndpoint: CodexNotificationSSHEndpoint? = nil
    ) async throws -> RemoteEditorDestination {
        try await resolve(sshDestination: sshDestination, absolutePath: absolutePath, kind: kind,
            hostname: hostname, serverAddress: serverAddress, pinnedEndpoint: pinnedEndpoint,
            runner: FoundationInventoryProcessRunner(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func resolve(
        sshDestination: String,
        absolutePath: String,
        kind: RemoteEditorDestination.Kind,
        hostname: String,
        serverAddress: String,
        pinnedEndpoint: CodexNotificationSSHEndpoint? = nil,
        runner: any InventoryProcessRunning,
        homeDirectory: URL
    ) async throws -> RemoteEditorDestination {
        let ordinary = try RemoteEditorDestination(sshDestination: sshDestination,
            absolutePath: absolutePath, kind: kind)
        let output = try await TimedInventoryProcessRunner(timeout: .seconds(5), underlying: runner)
            .run(CommandSpec(executable: "/usr/bin/ssh", arguments: ["-G", "-T", "--", sshDestination],
                environment: ["LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]))
        guard output.exitCode == 0, output.stdout.utf8.count <= 1_048_576 else {
            throw RemoteEditorError.invalidConfiguration
        }
        let properties = try SSHHostPropertiesReader.parse(output.stdout, destination: sshDestination)
        let endpoint: CodexNotificationSSHEndpoint
        if let pinnedEndpoint {
            guard pinnedEndpoint.isValid, pinnedEndpoint.destination == sshDestination,
                pinnedEndpoint.address == serverAddress,
                pinnedEndpoint.hostKeyAlias.lowercased() == properties.hostname.lowercased(),
                CodexNotificationSSHEndpoint.matches(loginHostname: hostname,
                    configuredHostname: properties.hostname)
            else { throw RemoteEditorError.unsupportedNode }
            endpoint = pinnedEndpoint
        } else if CodexNotificationSSHEndpoint.cluster(properties.hostname) != nil {
            guard CodexNotificationSSHEndpoint.matches(loginHostname: hostname,
                configuredHostname: properties.hostname) else { throw RemoteEditorError.unsupportedNode }
            endpoint = CodexNotificationSSHEndpoint(destination: sshDestination,
                address: serverAddress, hostKeyAlias: properties.hostname)
            guard endpoint.isValid else { throw RemoteEditorError.unsupportedNode }
        } else {
            return ordinary
        }
        try Task.checkCancellation()
        let alias = try RemoteEditorSSHConfiguration(homeDirectory: homeDirectory)
            .install(endpoint: endpoint, resolvedConfiguration: output.stdout)
        return try RemoteEditorDestination(sshDestination: alias, absolutePath: absolutePath, kind: kind)
    }
}
