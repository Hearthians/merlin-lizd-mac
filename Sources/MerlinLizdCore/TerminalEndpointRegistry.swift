import Foundation

public struct TerminalEndpoint: Sendable {
    public let id: TerminalEndpointID
    public let conversationKey: TerminalConversationKey
    public let terminal: any TerminalSessionPort
    public let surfaces: any TmuxSurfaceControlling
    public let route: TmuxRoute

    public init(
        id: TerminalEndpointID,
        conversationKey: TerminalConversationKey,
        terminal: any TerminalSessionPort,
        surfaces: any TmuxSurfaceControlling,
        route: TmuxRoute
    ) {
        self.id = id
        self.conversationKey = conversationKey
        self.terminal = terminal
        self.surfaces = surfaces
        self.route = route
    }
}

public struct TerminalEndpointBinding: Sendable {
    public let threadID: AgentThreadID
    public let turnID: AgentTurnID?
    public let conversationKey: TerminalConversationKey
    public let endpoint: TerminalEndpoint

    public init(
        threadID: AgentThreadID,
        turnID: AgentTurnID?,
        conversationKey: TerminalConversationKey,
        endpoint: TerminalEndpoint
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.conversationKey = conversationKey
        self.endpoint = endpoint
    }
}

public struct TerminalEndpointPinLoss: Equatable, Sendable {
    public let threadID: AgentThreadID
    public let turnID: AgentTurnID
    public let conversationKey: TerminalConversationKey
    public let endpointID: TerminalEndpointID

    public init(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        conversationKey: TerminalConversationKey,
        endpointID: TerminalEndpointID
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.conversationKey = conversationKey
        self.endpointID = endpointID
    }
}

public enum TerminalEndpointRegistryEvent: Equatable, Sendable {
    case pinLost(TerminalEndpointPinLoss)
}

public enum TerminalEndpointRegistryError: Error, Equatable, Sendable {
    case endpointNotFound
    case endpointRouteMismatch
    case noFocusedEndpoint
    case threadAlreadyPrepared
    case conversationBusy
    case preparedBindingNotFound
    case turnIDMismatch
    case bindingMismatch
    case pinLost
}

public actor TerminalEndpointRegistry {
    private struct RegisteredEndpoint: Sendable {
        let endpoint: TerminalEndpoint
        var focusOrder: UInt64
    }

    private struct StoredBinding: Sendable {
        let threadID: AgentThreadID
        let conversationKey: TerminalConversationKey
        let endpoint: TerminalEndpoint
        var turnID: AgentTurnID?
        var pinLost: Bool

        var value: TerminalEndpointBinding {
            TerminalEndpointBinding(
                threadID: threadID,
                turnID: turnID,
                conversationKey: conversationKey,
                endpoint: endpoint
            )
        }
    }

    private var endpoints: [TerminalEndpointID: RegisteredEndpoint] = [:]
    private var bindings: [AgentThreadID: StoredBinding] = [:]
    private var conversationOwners: [TerminalConversationKey: AgentThreadID]
        = [:]
    private var focusOrder: UInt64 = 0
    private var losses: [TerminalEndpointPinLoss] = []
    private var eventSubscribers: [
        UUID: AsyncStream<TerminalEndpointRegistryEvent>.Continuation
    ] = [:]

    public init() {}

    public func register(_ endpoint: TerminalEndpoint) {
        guard routeMatchesConversation(endpoint) else { return }
        focusOrder &+= 1
        endpoints[endpoint.id] = RegisteredEndpoint(
            endpoint: endpoint,
            focusOrder: focusOrder
        )
    }

    public func unregister(_ endpointID: TerminalEndpointID) {
        endpoints.removeValue(forKey: endpointID)
        for threadID in Array(bindings.keys) {
            guard var binding = bindings[threadID],
                binding.endpoint.id == endpointID,
                !binding.pinLost
            else { continue }
            binding.pinLost = true
            bindings[threadID] = binding
            if let turnID = binding.turnID {
                let loss = TerminalEndpointPinLoss(
                    threadID: threadID,
                    turnID: turnID,
                    conversationKey: binding.conversationKey,
                    endpointID: endpointID
                )
                losses.append(loss)
                eventSubscribers.values.forEach {
                    $0.yield(.pinLost(loss))
                }
            }
        }
    }

    public func focus(_ endpointID: TerminalEndpointID) throws {
        guard var endpoint = endpoints[endpointID] else {
            throw TerminalEndpointRegistryError.endpointNotFound
        }
        focusOrder &+= 1
        endpoint.focusOrder = focusOrder
        endpoints[endpointID] = endpoint
    }

    public func prepareTurn(
        threadID: AgentThreadID,
        conversationKey: TerminalConversationKey
    ) async throws -> TerminalEndpointBinding {
        guard bindings[threadID] == nil else {
            throw TerminalEndpointRegistryError.threadAlreadyPrepared
        }
        guard conversationOwners[conversationKey] == nil else {
            throw TerminalEndpointRegistryError.conversationBusy
        }
        guard let endpoint = endpoints.values
            .filter({ $0.endpoint.conversationKey == conversationKey })
            .max(by: { $0.focusOrder < $1.focusOrder })?
            .endpoint
        else {
            throw TerminalEndpointRegistryError.noFocusedEndpoint
        }

        let stored = StoredBinding(
            threadID: threadID,
            conversationKey: conversationKey,
            endpoint: endpoint,
            turnID: nil,
            pinLost: false
        )
        bindings[threadID] = stored
        conversationOwners[conversationKey] = threadID
        await endpoint.terminal.setKeyboardOwner(.codex)
        guard let current = bindings[threadID], !current.pinLost else {
            bindings.removeValue(forKey: threadID)
            conversationOwners.removeValue(forKey: conversationKey)
            await endpoint.terminal.setKeyboardOwner(.user)
            throw TerminalEndpointRegistryError.pinLost
        }
        return current.value
    }

    public func claimPreparedTurn(
        threadID: AgentThreadID,
        conversationKey: TerminalConversationKey,
        turnID: AgentTurnID
    ) throws -> TerminalEndpointBinding {
        guard var stored = bindings[threadID] else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        guard !stored.pinLost else {
            throw TerminalEndpointRegistryError.pinLost
        }
        guard stored.conversationKey == conversationKey else {
            throw TerminalEndpointRegistryError.bindingMismatch
        }
        if let existing = stored.turnID {
            guard existing == turnID else {
                throw TerminalEndpointRegistryError.turnIDMismatch
            }
            return stored.value
        }
        stored.turnID = turnID
        bindings[threadID] = stored
        return stored.value
    }

    public func confirmTurnID(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) throws {
        guard var stored = bindings[threadID] else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        guard !stored.pinLost else {
            throw TerminalEndpointRegistryError.pinLost
        }
        if let existing = stored.turnID {
            guard existing == turnID else {
                throw TerminalEndpointRegistryError.turnIDMismatch
            }
            return
        }
        stored.turnID = turnID
        bindings[threadID] = stored
    }

    public func binding(
        threadID: AgentThreadID,
        turnID: AgentTurnID,
        conversationKey: TerminalConversationKey
    ) throws -> TerminalEndpointBinding {
        guard let stored = bindings[threadID] else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        guard !stored.pinLost else {
            throw TerminalEndpointRegistryError.pinLost
        }
        guard stored.turnID == turnID else {
            throw TerminalEndpointRegistryError.turnIDMismatch
        }
        guard stored.conversationKey == conversationKey else {
            throw TerminalEndpointRegistryError.bindingMismatch
        }
        guard endpoints[stored.endpoint.id] != nil else {
            throw TerminalEndpointRegistryError.pinLost
        }
        return stored.value
    }

    public func releaseTurn(
        threadID: AgentThreadID,
        turnID: AgentTurnID?
    ) async {
        guard let stored = bindings[threadID] else { return }
        if let turnID, let existing = stored.turnID, existing != turnID {
            return
        }
        bindings.removeValue(forKey: threadID)
        conversationOwners.removeValue(forKey: stored.conversationKey)
        await stored.endpoint.terminal.setKeyboardOwner(.user)
    }

    public func pinLossEvents() -> [TerminalEndpointPinLoss] {
        losses
    }

    public func events() -> AsyncStream<TerminalEndpointRegistryEvent> {
        let subscriberID = UUID()
        return AsyncStream { continuation in
            eventSubscribers[subscriberID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventSubscriber(subscriberID) }
            }
        }
    }

    private func removeEventSubscriber(_ subscriberID: UUID) {
        eventSubscribers.removeValue(forKey: subscriberID)
    }

    private func routeMatchesConversation(_ endpoint: TerminalEndpoint) -> Bool {
        endpoint.route.expectedIdentity == endpoint.conversationKey.tmux
            && TerminalTargetIdentity(endpoint.route.target)
                == endpoint.conversationKey.target
    }
}
