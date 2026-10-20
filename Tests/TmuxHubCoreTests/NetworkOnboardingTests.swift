import Foundation
import Testing
@testable import TmuxHubCore

struct NetworkOnboardingTests {
    @Test("Windows, WSL, and different users have independent membership identities")
    func environmentIdentityIsolation() {
        let host = NetworkMeshHost(name: "Cube", endpoints: [
            endpoint("wsl-campus", address: "10.0.0.1", environmentID: "wsl", username: "alice"),
            endpoint("wsl-zt", address: "10.61.0.1", environmentID: "wsl", username: "alice", kind: .zeroTier),
            endpoint("wsl-bob", address: "10.0.0.1", environmentID: "wsl", username: "bob"),
            endpoint("windows", address: "10.0.0.1", environmentID: "windows", username: "alice", platform: .windows),
        ], isMember: true)
        let environments = NetworkOnboardingEnvironment.environments(for: host)
        #expect(environments.count == 3)
        #expect(Set(environments.map(\.id)).count == 3)
        #expect(environments.first { $0.username == "alice" && $0.platform == .posix }?.endpoints.count == 2)
    }

    @Test("Windows setup uses PowerShell and administrator authorized_keys ACL")
    func windowsCommands() throws {
        let endpoint = endpoint("windows", address: "10.0.0.1", platform: .windows)
        let script = try NetworkMembershipCommands.authorizationScript(sourceID: String(repeating: "a", count: 24), targetID: String(repeating: "b", count: 24), publicKey: Self.publicKey(1), platform: .windows, revoke: false)
        let command = try NetworkMembershipCommands.managementCommand(endpoint: endpoint, script: script, meshIdentity: true)
        let decoded = MembershipFixtureRunner.decodedScript(command)
        #expect(decoded.contains("administrators_authorized_keys"))
        #expect(decoded.contains("icacls.exe"))
        #expect(decoded.contains("S-1-5-32-544"))
        #expect(command.arguments.last?.contains("powershell.exe") == true)
        #expect(command.arguments.last?.contains("sh -c") == false)
        #expect(command.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(command.arguments.contains(NetworkMembershipCommands.managementIdentityFile))
        #expect(!command.arguments.contains("ForwardAgent=yes"))
    }

    @Test("Each directed environment verifies its preferred SSH route with a fresh execution marker")
    func completeMeshVerifiesPreferredDirectedRoutes() async throws {
        let a = NetworkMeshHost(name: "A", endpoints: [endpoint("a", address: "10.0.0.1")], isMember: true)
        let b = NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2"), endpoint("b-zt", address: "10.61.0.2", kind: .zeroTier)], isMember: true)
        let runner = MembershipFixtureRunner()
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let result = await service.reconcile(hosts: [a, b], journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        #expect(result.journal.pendingTasks.isEmpty)
        #expect(result.journal.publicKeys.count == 2)
        let commands = await runner.commands()
        let probes = commands.filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB PROBE") }
        #expect(probes.count == 2)
        #expect(probes.allSatisfy { !MembershipFixtureRunner.decodedScript($0).contains("10.61.0.2") })
        #expect(probes.allSatisfy { MembershipFixtureRunner.decodedScript($0).contains("'-b'") })
        #expect(probes.allSatisfy { MembershipFixtureRunner.decodedScript($0).contains("StrictHostKeyChecking=yes") })
        #expect(probes.allSatisfy { MembershipFixtureRunner.decodedScript($0).contains("tmuxhub_mesh_known_hosts") })
        #expect(!commands.contains { $0.executable.contains("ssh-keyscan") || $0.arguments.contains("StrictHostKeyChecking=no") })
    }

    @Test("SSH exit zero and a banner alone never mean verified connectivity")
    func missingMarkerRemainsPending() async {
        let runner = MembershipFixtureRunner(returnsMarkers: false)
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [endpoint("a", address: "10.0.0.1")], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2")], isMember: true),
        ]
        let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(!result.isComplete)
        #expect(result.journal.pendingTasks.count == 2)
        #expect(result.journal.pendingTasks.allSatisfy { $0.lastError?.contains("验证标记") == true })
    }

    @Test("Offline configuration survives JSON persistence and completes on retry")
    func offlineJoinAndRetry() async throws {
        let runner = MembershipFixtureRunner(offline: ["b"])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [endpoint("a", address: "10.0.0.1")], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2")], isMember: true),
        ]
        let first = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(!first.isComplete)
        #expect(!first.journal.pendingTasks.isEmpty)
        let data = try JSONEncoder().encode(first.journal)
        let restored = try JSONDecoder().decode(NetworkMembershipJournal.self, from: data)
        #expect(restored == first.journal)
        await runner.setOffline([])
        let retry = await service.reconcile(hosts: hosts, journal: restored)
        #expect(retry.isComplete)
        #expect(retry.journal.pendingTasks.isEmpty)
    }

    @Test("An offline departing host does not block online peers revoking its access")
    func offlineRevocationIsTwoSided() async throws {
        let runner = MembershipFixtureRunner()
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let a = NetworkMeshHost(name: "A", endpoints: [endpoint("a", address: "10.0.0.1")], isMember: true)
        var b = NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2")], isMember: true)
        let initial = await service.reconcile(hosts: [a, b], journal: NetworkMembershipJournal())
        #expect(initial.isComplete)
        b.isMember = false
        await runner.setOffline(["b"])
        let revoked = await service.reconcile(hosts: [a, b], journal: initial.journal)
        let outgoing = try #require(revoked.journal.pendingTasks.first { $0.sourceHostID == b.id && $0.targetHostID == a.id })
        #expect(outgoing.kind == .revoke)
        #expect(outgoing.authorizationApplied)
        #expect(!outgoing.configurationApplied)
        let incoming = try #require(revoked.journal.pendingTasks.first { $0.sourceHostID == a.id && $0.targetHostID == b.id })
        #expect(!incoming.authorizationApplied)
        #expect(incoming.configurationApplied)
        #expect(revoked.journal.environments.contains { $0.hostID == b.id })
        await runner.setOffline([])
        let complete = await service.reconcile(hosts: [a, b], journal: revoked.journal)
        #expect(complete.isComplete)
        #expect(!complete.journal.environments.contains { $0.hostID == b.id })
        let removalCommands = await runner.commands().filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB REVOKE") }
        #expect(!removalCommands.isEmpty)
        #expect(removalCommands.allSatisfy { !MembershipFixtureRunner.decodedScript($0).contains("tmuxhub-manager:") })
        #expect(removalCommands.allSatisfy { !MembershipFixtureRunner.decodedScript($0).contains("pkill") })
    }

    @Test("Fingerprint errors stop campus-to-ZeroTier management fallback")
    func fingerprintFailureDoesNotFallback() async {
        let runner = MembershipFixtureRunner(failures: ["a-campus": "REMOTE HOST IDENTIFICATION HAS CHANGED!"])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [endpoint("a-campus", address: "10.0.0.1"), endpoint("a-zt", address: "10.61.0.1", kind: .zeroTier)], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2")], isMember: true),
        ]
        let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(!result.isComplete)
        let destinations = await runner.commands().compactMap(MembershipFixtureRunner.destination)
        #expect(!destinations.contains("a-zt"))
    }

    @Test("A member losing all discovered interfaces is not implicitly withdrawn")
    func missingInterfacesKeepMembership() async {
        let runner = MembershipFixtureRunner()
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        var a = NetworkMeshHost(name: "A", endpoints: [endpoint("a", address: "10.0.0.1")], isMember: true)
        let b = NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2")], isMember: true)
        let initial = await service.reconcile(hosts: [a, b], journal: NetworkMembershipJournal())
        a.endpoints = []
        let transient = await service.reconcile(hosts: [a, b], journal: initial.journal)
        #expect(transient.journal.environments.contains { $0.hostID == a.id })
        #expect(!transient.journal.pendingTasks.contains { $0.kind == .revoke })
    }

    @Test("IPv4 and IPv6 paths are verified only within compatible address families")
    func compatibleFamiliesOnly() async {
        let runner = MembershipFixtureRunner()
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [endpoint("a4", address: "10.0.0.1"), endpoint("a6", address: "2001:db8::1")], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b4", address: "10.0.0.2"), endpoint("b6", address: "2001:db8::2")], isMember: true),
        ]
        let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        let probes = await runner.commands().filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB PROBE") }
        #expect(probes.count == 2)
        #expect(probes.allSatisfy {
            let script = MembershipFixtureRunner.decodedScript($0)
            return (script.contains("'-4'") && !script.contains("2001:db8:"))
                || (script.contains("'-6'") && !script.contains("10.0."))
        })
    }

    @Test("Multiple administrator accounts on one Windows OS remain explicitly pending")
    func sharedAdministratorScopeIsNotUserIsolation() async {
        let runner = MembershipFixtureRunner(windowsScopes: [
            "win-a": "TMUXHUB_WINDOWS_ADMIN:11111111-2222-3333-4444-555555555555:S-1-5-21-1001",
            "win-b": "TMUXHUB_WINDOWS_ADMIN:11111111-2222-3333-4444-555555555555:S-1-5-21-1002",
        ])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "Windows", endpoints: [
                endpoint("win-a", address: "10.0.0.1", username: "alice", platform: .windows),
                endpoint("win-b", address: "10.0.0.1", username: "bob", platform: .windows),
            ], isMember: true),
            NetworkMeshHost(name: "Linux", endpoints: [endpoint("linux", address: "10.0.0.2")], isMember: true),
        ]
        let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(!result.isComplete)
        #expect(result.journal.pendingTasks.contains { $0.lastError?.contains("共用授权文件") == true })
        let commands = await runner.commands()
        #expect(!commands.contains { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB AUTHORIZE") })
    }

    @Test("A single Windows administrator and WSL remain independent and supported")
    func windowsAdministratorAndWSL() async {
        let runner = MembershipFixtureRunner(windowsScopes: [
            "win-a": "TMUXHUB_WINDOWS_ADMIN:11111111-2222-3333-4444-555555555555:S-1-5-21-1001",
        ])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let host = NetworkMeshHost(name: "Cube", endpoints: [
            endpoint("win-a", address: "10.0.0.1", environmentID: "windows", username: "alice", platform: .windows),
            endpoint("wsl", address: "10.61.0.1", environmentID: "wsl", username: "alice"),
        ], isMember: true)
        let result = await service.reconcile(hosts: [host], journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        #expect(result.journal.publicKeys.count == 2)
        #expect(result.journal.windowsAuthorizationScopes.count == 1)
    }

    @Test("Manual repair rechecks identities and restores already completed managed configuration")
    func manualRepairResetsCheckpoints() async {
        let runner = MembershipFixtureRunner()
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [endpoint("a", address: "10.0.0.1")], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2")], isMember: true),
        ]
        let first = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        let before = await runner.commands().count
        let noop = await service.reconcile(hosts: hosts, journal: first.journal)
        #expect(noop.isComplete)
        let afterNoop = await runner.commands()
        #expect(afterNoop.dropFirst(before).allSatisfy { !MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB AUTHORIZE") })
        let repaired = await service.reconcile(hosts: hosts, journal: first.journal, forceRepair: true)
        #expect(repaired.isComplete)
        #expect(await runner.commands().count > before)
    }

    @Test("Managed authorization tags distinguish both source and destination accounts")
    func authorizationTagIncludesTargetIdentity() throws {
        let source = String(repeating: "a", count: 24)
        let firstTarget = String(repeating: "b", count: 24)
        let secondTarget = String(repeating: "c", count: 24)
        let first = try NetworkMembershipCommands.authorizationScript(sourceID: source, targetID: firstTarget, publicKey: Self.publicKey(1), platform: .windows, revoke: false)
        let second = try NetworkMembershipCommands.authorizationScript(sourceID: source, targetID: secondTarget, publicKey: nil, platform: .windows, revoke: true)
        #expect(first.contains("tmuxhub-mesh:\(source):\(firstTarget)"))
        #expect(second.contains("tmuxhub-mesh:\(source):\(secondTarget)"))
        #expect(!second.contains("tmuxhub-mesh:\(source):\(firstTarget)"))
    }

    @Test("User SSH config links are rejected before writing Include or replacing contents")
    func configLinksArePreserved() throws {
        let host = NetworkMeshHost(name: "A", endpoints: [endpoint("a", address: "10.0.0.1")], isMember: true)
        let environment = try #require(NetworkOnboardingEnvironment.environments(for: host).first)
        let fingerprints = [environment.endpoints[0].id.uuidString: [Self.publicKey(1)]]
        let posix = try NetworkMembershipCommands.sourceConfigurationScript(target: environment, keys: fingerprints, platform: .posix, revoke: false)
        let guardRange = try #require(posix.range(of: "if [ -L"))
        let writeRange = try #require(posix.range(of: "touch \"$HOME/.ssh/config\""))
        #expect(guardRange.lowerBound < writeRange.lowerBound)
        let windows = try NetworkMembershipCommands.sourceConfigurationScript(target: environment, keys: fingerprints, platform: .windows, revoke: false)
        #expect(windows.contains("[IO.FileAttributes]::ReparsePoint"))
        #expect(windows.contains("Manually add: Include"))
    }

    @Test("Controller aliases use independently verified trust and preserve original proxy routing")
    func controllerAliasesHaveTheirOwnTrust() async throws {
        let runner = MembershipFixtureRunner(sshConfiguration: "hostkeyalias original-trust-name\nuserknownhostsfile /tmp/original-user-trust\nproxycommand /usr/bin/nc -X 5 -x 127.0.0.1:1080 %h %p\nproxyjump none\nproxyusefdpass no\n")
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        try fixture.writeManagementPlaceholder()
        let entry = endpoint("original-alias", address: "10.0.0.1")
        let host = NetworkMeshHost(name: "A", endpoints: [entry], isMember: true)
        let result = await service.reconcile(hosts: [host], journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        #expect(result.managementAliases[entry.id] == NetworkMembershipCommands.controlAlias(for: entry))
        let commands = await runner.commands()
        let writer = try #require(commands.first { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB CONTROL_ALIAS") })
        let script = MembershipFixtureRunner.decodedScript(writer)
        #expect(script.contains("IdentityFile ~/.ssh/tmuxhub_management_ed25519"))
        #expect(script.contains("UserKnownHostsFile ~/.ssh/tmuxhub_control_known_hosts"))
        #expect(script.contains("HostKeyAlias tmuxhub-control-"))
        #expect(script.contains("StrictHostKeyChecking yes"))
        #expect(script.contains("ProxyCommand /usr/bin/nc"))
        #expect(!script.contains("original-trust-name"))
        #expect(!script.contains("/tmp/original-user-trust"))
        #expect(script.contains(Self.publicKey(UInt8("original-alias".utf8.reduce(0) { (Int($0) + Int($1)) % 200 } + 1))))
    }

    @Test("Existing working SSH aliases remain unchanged when management-key setup has not occurred")
    func noManagementKeyKeepsOriginalAlias() async {
        let runner = MembershipFixtureRunner(identityFailure: "Warning: Identity file not accessible: No such file or directory.\nConnection closed by 10.4.129.108 port 2222")
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let entry = endpoint("original-working-alias", address: "10.0.0.1")
        let result = await service.reconcile(hosts: [NetworkMeshHost(name: "A", endpoints: [entry], isMember: true)], journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        #expect(result.managementAliases.isEmpty)
        let commands = await runner.commands()
        #expect(!commands.contains { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB CONTROL_ALIAS") })
        #expect(!commands.contains { $0.arguments.contains("-i") })
    }

    @Test("Generic management commands preserve the endpoint's configured SSH credentials")
    func managementCommandDoesNotInventIdentity() throws {
        let command = try NetworkMembershipCommands.managementCommand(
            endpoint: endpoint("existing-alias", address: "10.0.0.1"), script: "true"
        )
        #expect(!command.arguments.contains("-i"))
        #expect(MembershipFixtureRunner.destination(command) == "existing-alias")
    }

    @Test("An available management key retries original SSH credentials only after authentication fails")
    func managementAuthenticationRetriesOriginalCredentials() async throws {
        let runner = MembershipFixtureRunner(identityFailure: "Permission denied (publickey).")
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        try fixture.writeManagementPlaceholder()
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        _ = try await service.runManagementEndpoint(
            endpoint: endpoint("existing-alias", address: "10.0.0.1"), script: "# TMUXHUB PREPARE"
        )
        let commands = await runner.commands()
        #expect(commands.count == 2)
        #expect(commands[0].arguments.contains(NetworkMembershipCommands.managementIdentityFile))
        #expect(!commands[1].arguments.contains("-i"))
        #expect(commands.allSatisfy { MembershipFixtureRunner.destination($0) == "existing-alias" })
    }

    @Test("A management fingerprint failure stops before original credentials are retried")
    func managementFingerprintFailureStopsCredentialRetry() async throws {
        let runner = MembershipFixtureRunner(identityFailure: "REMOTE HOST IDENTIFICATION HAS CHANGED!")
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        try fixture.writeManagementPlaceholder()
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        do {
            _ = try await service.runManagementEndpoint(
                endpoint: endpoint("existing-alias", address: "10.0.0.1"), script: "# TMUXHUB PREPARE"
            )
            Issue.record("A changed host fingerprint must fail verification.")
        } catch {
            #expect(error.localizedDescription.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
        }
        #expect(await runner.commands().count == 1)
    }

    @Test("Local host keys are read once and assigned to every address of the same runtime")
    func localPreparationReadsHostKeysOnce() async {
        let runner = MembershipFixtureRunner()
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let entries = [endpoint("local-campus", address: "10.0.0.1"), endpoint("local-zt", address: "10.61.0.1", kind: .zeroTier)]
        let host = NetworkMeshHost(name: "Local", isLocal: true, endpoints: entries, isMember: true)
        let result = await service.reconcile(hosts: [host], journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        #expect(result.journal.hostPublicKeys[entries[0].id.uuidString] != nil)
        #expect(result.journal.hostPublicKeys[entries[0].id.uuidString] == result.journal.hostPublicKeys[entries[1].id.uuidString])
        let hostKeyCommands = await runner.commands().filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB HOSTKEYS") }
        #expect(hostKeyCommands.count == 1)
        #expect(hostKeyCommands[0].executable == "/bin/sh")
    }


    @Test("A successful campus route completes admission without requiring unrelated ZeroTier routes")
    func successfulCampusRouteCompletesAdmission() async {
        let runner = MembershipFixtureRunner(probeFailures: ["'-b' '10.61.0.1'": "No route to host", "'-b' '10.61.0.2'": "No route to host"])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [endpoint("a-zt", address: "10.61.0.1", kind: .zeroTier), endpoint("a-campus", address: "10.0.0.1")], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b-zt", address: "10.61.0.2", kind: .zeroTier), endpoint("b-campus", address: "10.0.0.2")], isMember: true),
        ]
        let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        let probes = await runner.commands().filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB PROBE") }
        #expect(probes.count == 2)
        #expect(probes.allSatisfy { !MembershipFixtureRunner.decodedScript($0).contains("10.61.") })
    }

    @Test("Admission falls back to a matching ZeroTier route after a campus network failure")
    func admissionFallsBackToZeroTierForNetworkFailure() async {
        let runner = MembershipFixtureRunner(probeFailures: ["'-b' '10.0.0.1'": "No route to host", "'-b' '10.0.0.2'": "Connection timed out"])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [endpoint("a-campus", address: "10.0.0.1"), endpoint("a-zt", address: "10.61.0.1", kind: .zeroTier)], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b-campus", address: "10.0.0.2"), endpoint("b-zt", address: "10.61.0.2", kind: .zeroTier)], isMember: true),
        ]
        let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(result.isComplete)
        let probes = await runner.commands().filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB PROBE") }
        #expect(probes.count >= 4)
        #expect(probes.filter { MembershipFixtureRunner.decodedScript($0).contains("10.61.") }.count == 2)
        #expect(probes.allSatisfy {
            let script = MembershipFixtureRunner.decodedScript($0)
            return !(script.contains("10.61.") && script.contains("10.0."))
        })
    }

    @Test("Admission stops on campus authentication and fingerprint errors")
    func admissionDoesNotFallbackForAuthenticationOrTrust() async {
        for failure in ["Permission denied (publickey).", "REMOTE HOST IDENTIFICATION HAS CHANGED!"] {
            let runner = MembershipFixtureRunner(probeFailures: ["'-b' '10.0.0.1'": failure])
            let fixture = MembershipFixtureHome()
            defer { fixture.remove() }
            let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
            let hosts = [
                NetworkMeshHost(name: "A", endpoints: [endpoint("a-campus", address: "10.0.0.1"), endpoint("a-zt", address: "10.61.0.1", kind: .zeroTier)], isMember: true),
                NetworkMeshHost(name: "B", endpoints: [endpoint("b-campus", address: "10.0.0.2"), endpoint("b-zt", address: "10.61.0.2", kind: .zeroTier)], isMember: true),
            ]
            let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
            #expect(!result.isComplete)
            let probes = await runner.commands().filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB PROBE") }
            #expect(!probes.contains { MembershipFixtureRunner.decodedScript($0).contains("'-b' '10.61.0.1'") })
            #expect(result.journal.pendingTasks.contains { $0.lastError?.contains(failure) == true })
        }
    }


    @Test("An offline campus endpoint remains pending while authenticated ZeroTier paths complete both directions")
    func offlineEndpointDoesNotBlockAuthenticatedRoutes() async throws {
        let runner = MembershipFixtureRunner(timedOut: ["a-campus"])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let campus = endpoint("a-campus", address: "10.0.0.1")
        let zeroTier = endpoint("a-zt", address: "10.61.0.1", kind: .zeroTier)
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [campus, zeroTier], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b-campus", address: "10.0.0.2"), endpoint("b-zt", address: "10.61.0.2", kind: .zeroTier)], isMember: true),
        ]
        let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        #expect(!result.isComplete)
        #expect(result.journal.pendingTasks.count == 1)
        #expect(result.journal.pendingTasks.allSatisfy { $0.kind == .prepare })
        #expect(result.journal.completedTaskIDs.filter { $0.hasPrefix("configure:") }.count == 2)
        #expect(result.journal.hostPublicKeys[campus.id.uuidString] == nil)
        #expect(result.journal.hostPublicKeys[zeroTier.id.uuidString] != nil)
        let commands = await runner.commands()
        let configurations = commands.filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB CONFIGURE") }
        let probes = commands.filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB PROBE") }
        let failedControlConfigurations = configurations.filter { MembershipFixtureRunner.destination($0) == campus.sshDestination }
        let failedControlProbes = probes.filter { MembershipFixtureRunner.destination($0) == campus.sshDestination }
        let executedConfigurations = configurations.filter { MembershipFixtureRunner.destination($0) != campus.sshDestination }
        let executedProbes = probes.filter { MembershipFixtureRunner.destination($0) != campus.sshDestination }
        // The timed-out campus controller never executes its attached script; ZeroTier retries it.
        #expect(failedControlConfigurations.count == 1)
        #expect(failedControlProbes.count == 1)
        #expect(executedConfigurations.count == 2)
        #expect(executedProbes.count == 2)
        #expect((configurations + probes).allSatisfy { !MembershipFixtureRunner.decodedScript($0).contains(campus.address) })
        #expect(executedProbes.allSatisfy { MembershipFixtureRunner.decodedScript($0).contains("10.61.") })
    }

    @Test("A newly authenticated endpoint invalidates both direction checkpoints and adds its own trust")
    func recoveredEndpointReconfiguresBothDirections() async throws {
        let aKey = Self.publicKey(1)
        let bKey = Self.publicKey(2)
        let runner = MembershipFixtureRunner(offline: ["a-campus"], preparationKeys: [
            "a-campus": aKey, "a-zt": aKey, "b-campus": bKey, "b-zt": bKey,
        ])
        let fixture = MembershipFixtureHome()
        defer { fixture.remove() }
        let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
        let campus = endpoint("a-campus", address: "10.0.0.1")
        let hosts = [
            NetworkMeshHost(name: "A", endpoints: [campus, endpoint("a-zt", address: "10.61.0.1", kind: .zeroTier)], isMember: true),
            NetworkMeshHost(name: "B", endpoints: [endpoint("b-campus", address: "10.0.0.2"), endpoint("b-zt", address: "10.61.0.2", kind: .zeroTier)], isMember: true),
        ]
        let first = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
        let previousConfigurations = Set(first.journal.completedTaskIDs.filter { $0.hasPrefix("configure:") })
        #expect(previousConfigurations.count == 2)
        let firstCommandCount = await runner.commands().count
        await runner.setOffline([])
        let second = await service.reconcile(hosts: hosts, journal: first.journal)
        #expect(second.isComplete)
        #expect(second.journal.publicKeys == first.journal.publicKeys)
        #expect(second.journal.hostPublicKeys[campus.id.uuidString] != nil)
        let addedConfigurations = Set(second.journal.completedTaskIDs.filter { $0.hasPrefix("configure:") }).subtracting(previousConfigurations)
        #expect(addedConfigurations.count == 2)
        let newCommands = Array(await runner.commands().dropFirst(firstCommandCount))
        let configurations = newCommands.filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB CONFIGURE") }
        #expect(configurations.count == 2)
        #expect(configurations.contains { MembershipFixtureRunner.decodedScript($0).contains(campus.address) })
        let probes = newCommands.filter { MembershipFixtureRunner.decodedScript($0).contains("# TMUXHUB PROBE") }
        #expect(probes.count == 2)
        #expect(probes.allSatisfy { !MembershipFixtureRunner.decodedScript($0).contains("10.61.") })
    }

    @Test("Endpoint authentication or fingerprint preparation errors block new related configuration")
    func unsafeEndpointPreparationBlocksConfiguration() async {
        for failure in ["Permission denied (publickey).", "REMOTE HOST IDENTIFICATION HAS CHANGED!"] {
            let runner = MembershipFixtureRunner(hostKeyFailures: ["a-campus": failure])
            let fixture = MembershipFixtureHome()
            defer { fixture.remove() }
            let service = NetworkOnboardingService(runner: runner, homeDirectory: fixture.home)
            let hosts = [
                NetworkMeshHost(name: "A", endpoints: [endpoint("a-campus", address: "10.0.0.1"), endpoint("a-zt", address: "10.61.0.1", kind: .zeroTier)], isMember: true),
                NetworkMeshHost(name: "B", endpoints: [endpoint("b", address: "10.0.0.2")], isMember: true),
            ]
            let result = await service.reconcile(hosts: hosts, journal: NetworkMembershipJournal())
            #expect(!result.isComplete)
            #expect(result.journal.pendingTasks.contains { $0.kind == .prepare })
            #expect(result.journal.pendingTasks.filter { $0.kind == .configure }.count == 2)
            let commands = await runner.commands()
            #expect(!commands.contains {
                let script = MembershipFixtureRunner.decodedScript($0)
                return script.contains("# TMUXHUB AUTHORIZE") || script.contains("# TMUXHUB CONFIGURE") || script.contains("# TMUXHUB PROBE")
            })
        }
    }

    @Test("Journal migrations retain outstanding revocations when new optional metadata is absent")
    func journalMetadataMigration() throws {
        var original = NetworkMembershipJournal()
        original.publicKeys = ["saved-environment": Self.publicKey(1)]
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["windowsAuthorizationScopes"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(NetworkMembershipJournal.self, from: legacy)
        #expect(restored.publicKeys == original.publicKeys)
        #expect(restored.managerID == original.managerID)
        #expect(restored.windowsAuthorizationScopes.isEmpty)
    }

    @Test("ZeroTier pending authorization never reports network ready")
    func zeroTierStates() throws {
        let pending = try NetworkZeroTierStatus.parse("[{\"nwid\":\"0123456789abcdef\",\"status\":\"ACCESS_DENIED\",\"assignedAddresses\":[]}]", networkID: "0123456789abcdef")
        #expect(pending.awaitsAuthorization)
        #expect(!pending.isReady)
        let noIP = try NetworkZeroTierStatus.parse("[{\"id\":\"0123456789abcdef\",\"status\":\"OK\",\"assignedAddresses\":[]}]", networkID: "0123456789abcdef")
        #expect(!noIP.isReady)
        let ready = try NetworkZeroTierStatus.parse("[{\"id\":\"0123456789abcdef\",\"status\":\"OK\",\"assignedAddresses\":[\"10.61.0.1/24\"]}]", networkID: "0123456789abcdef")
        #expect(ready.isReady)
        #expect(throws: NetworkOnboardingError.self) { try NetworkOnboardingCommands.validatedNetworkID("0123456789abcdef;bad") }
    }

    @Test("Managed aliases pin mesh identity and own known_hosts without weakening trust")
    func aliasAndRevocationScope() throws {
        let host = NetworkMeshHost(name: "A", endpoints: [endpoint("existing-alias", address: "10.0.0.1")], isMember: true)
        let environment = try #require(NetworkOnboardingEnvironment.environments(for: host).first)
        let configuration = try NetworkMembershipCommands.aliasConfiguration(target: environment)
        #expect(configuration.contains("Host tmuxhub-"))
        #expect(!configuration.contains("Host existing-alias"))
        #expect(configuration.contains("IdentityFile ~/.ssh/tmuxhub_mesh_ed25519"))
        #expect(configuration.contains("StrictHostKeyChecking yes"))
        let revoke = try NetworkMembershipCommands.authorizationScript(sourceID: environment.id, targetID: String(repeating: "b", count: 24), publicKey: nil, platform: .posix, revoke: true)
        #expect(revoke.contains("$NF != marker"))
        #expect(revoke.contains("tmuxhub-mesh:"))
        #expect(!revoke.contains("tmuxhub-manager:"))
        #expect(!revoke.contains("rm -f \"$auth\""))
    }

    private func endpoint(_ alias: String, address: String, environmentID: String = "main", username: String = "alice", platform: NetworkMeshPlatform = .posix, kind: NetworkMeshNetworkKind = .campus) -> NetworkMeshEndpoint {
        NetworkMeshEndpoint(label: alias, address: address, username: username, sshDestination: alias, networkKind: kind,
                            environmentID: environmentID, environmentName: environmentID, platform: platform)
    }

    fileprivate static func publicKey(_ value: UInt8) -> String {
        var data = Data([0, 0, 0, 11])
        data.append(Data("ssh-ed25519".utf8))
        data.append(contentsOf: [0, 0, 0, 32])
        data.append(Data(repeating: value, count: 32))
        return "ssh-ed25519 " + data.base64EncodedString()
    }
}

private struct MembershipFixtureHome {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxhub-membership-test-\(UUID().uuidString)", isDirectory: true)
    func remove() { try? FileManager.default.removeItem(at: home) }
    func writeManagementPlaceholder() throws {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("Test placeholder; fake runner never reads a private key.".utf8).write(to: ssh.appendingPathComponent("tmuxhub_management_ed25519"))
    }
}

private actor MembershipFixtureRunner: InventoryProcessRunning {
    private var recorded: [CommandSpec] = []
    private var offline: Set<String>
    private let returnsMarkers: Bool
    private let failures: [String: String]
    private let windowsScopes: [String: String]
    private let sshConfiguration: String
    private let identityFailure: String?
    private let probeFailures: [String: String]
    private let hostKeyFailures: [String: String]
    private let preparationKeys: [String: String]
    private let timedOut: Set<String>

    init(offline: Set<String> = [], returnsMarkers: Bool = true, failures: [String: String] = [:], windowsScopes: [String: String] = [:], sshConfiguration: String = "proxycommand none\nproxyjump none\n", identityFailure: String? = nil, probeFailures: [String: String] = [:], hostKeyFailures: [String: String] = [:], preparationKeys: [String: String] = [:], timedOut: Set<String> = []) {
        self.offline = offline
        self.returnsMarkers = returnsMarkers
        self.failures = failures
        self.windowsScopes = windowsScopes
        self.sshConfiguration = sshConfiguration
        self.identityFailure = identityFailure
        self.probeFailures = probeFailures
        self.hostKeyFailures = hostKeyFailures
        self.preparationKeys = preparationKeys
        self.timedOut = timedOut
    }

    func setOffline(_ aliases: Set<String>) { offline = aliases }
    func commands() -> [CommandSpec] { recorded }

    func run(_ command: CommandSpec) async throws -> InventoryProcessOutput {
        recorded.append(command)
        let alias = Self.destination(command) ?? "local"
        if command.arguments.contains("-G") { return InventoryProcessOutput(stdout: sshConfiguration, stderr: "", exitCode: 0) }
        if let identityFailure, command.arguments.contains("-i") {
            return InventoryProcessOutput(stdout: "", stderr: identityFailure, exitCode: 255)
        }
        if timedOut.contains(alias) { throw InventoryProcessTimeoutError.timedOut }
        if offline.contains(alias) { return InventoryProcessOutput(stdout: "", stderr: "Connection timed out", exitCode: 255) }
        if let failure = failures[alias] { return InventoryProcessOutput(stdout: "", stderr: failure, exitCode: 255) }
        let script = Self.decodedScript(command)
        if script.contains("# TMUXHUB PROBE"), let failure = probeFailures.first(where: { script.contains($0.key) }) {
            return InventoryProcessOutput(stdout: "", stderr: failure.value, exitCode: 255)
        }
        if script.contains("# TMUXHUB ACCOUNT_SCOPE") {
            return InventoryProcessOutput(stdout: (windowsScopes[alias] ?? "TMUXHUB_WINDOWS_USER:user-\(alias)") + "\n", stderr: "", exitCode: 0)
        }
        if script.contains("# TMUXHUB PREPARE"), let key = preparationKeys[alias] {
            return InventoryProcessOutput(stdout: key + "\n", stderr: "", exitCode: 0)
        }
        if script.contains("# TMUXHUB HOSTKEYS"), let failure = hostKeyFailures[alias] {
            return InventoryProcessOutput(stdout: "", stderr: failure, exitCode: 255)
        }
        if script.contains("# TMUXHUB PREPARE") || script.contains("# TMUXHUB HOSTKEYS") {
            let value = UInt8(alias.utf8.reduce(0) { (Int($0) + Int($1)) % 200 } + 1)
            return InventoryProcessOutput(stdout: NetworkOnboardingTests.publicKey(value) + "\n", stderr: "", exitCode: 0)
        }
        if script.contains("# TMUXHUB PROBE") || script.contains("# TMUXHUB CONTROL_VERIFY") {
            let expression = try NSRegularExpression(pattern: "# TMUXHUB (?:PROBE|CONTROL_VERIFY) (TMUXHUB_[A-F0-9]+)")
            let range = NSRange(script.startIndex..<script.endIndex, in: script)
            let match = expression.firstMatch(in: script, range: range)
            let tokenRange = match.flatMap { Range($0.range(at: 1), in: script) }
            let token = tokenRange.map { String(script[$0]) } ?? "missing"
            return InventoryProcessOutput(stdout: returnsMarkers ? token + "\n" : "Welcome banner\n", stderr: "", exitCode: 0)
        }
        return InventoryProcessOutput(stdout: "TMUXHUB_APPLIED\n", stderr: "", exitCode: 0)
    }

    nonisolated static func destination(_ command: CommandSpec) -> String? {
        guard let index = command.arguments.firstIndex(of: "--"), index + 1 < command.arguments.count else { return nil }
        return command.arguments[index + 1]
    }

    nonisolated static func decodedScript(_ command: CommandSpec) -> String {
        let value = command.arguments.last ?? ""
        if value.hasPrefix("sh -c '"), value.hasSuffix("'") {
            return String(value.dropFirst(7).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        guard let encoded = value.components(separatedBy: "-EncodedCommand ").last,
              value.contains("-EncodedCommand "), let data = Data(base64Encoded: encoded)
        else { return value }
        return String(data: data, encoding: .utf16LittleEndian) ?? value
    }
}
