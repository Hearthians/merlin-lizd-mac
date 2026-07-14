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
    public let token: TerminalEndpointBindingToken
    public let threadID: AgentThreadID
    public let turnID: AgentTurnID?
    public let conversationKey: TerminalConversationKey
    public let endpoint: TerminalEndpoint

    public init(
        token: TerminalEndpointBindingToken = TerminalEndpointBindingToken(),
        threadID: AgentThreadID,
        turnID: AgentTurnID?,
        conversationKey: TerminalConversationKey,
        endpoint: TerminalEndpoint
    ) {
        self.token = token
        self.threadID = threadID
        self.turnID = turnID
        self.conversationKey = conversationKey
        self.endpoint = endpoint
    }
}

public struct TerminalEndpointBindingToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum TerminalEndpointPinPhase: Equatable, Sendable {
    case prepared
    case active
}

public struct TerminalEndpointPinLoss: Equatable, Sendable {
    public let threadID: AgentThreadID
    public let turnID: AgentTurnID?
    public let phase: TerminalEndpointPinPhase
    public let conversationKey: TerminalConversationKey
    public let endpointID: TerminalEndpointID

    public init(
        threadID: AgentThreadID,
        turnID: AgentTurnID?,
        phase: TerminalEndpointPinPhase,
        conversationKey: TerminalConversationKey,
        endpointID: TerminalEndpointID
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.phase = phase
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

    private enum BindingPhase: Sendable {
        case preparing
        case prepared
        case claimed
        case releasing
        case pinLost
    }

    private struct KeyboardTransition: Sendable {
        let task: Task<Void, Never>
    }

    private struct StoredBinding: Sendable {
        let token: TerminalEndpointBindingToken
        let threadID: AgentThreadID
        let conversationKey: TerminalConversationKey
        let endpoint: TerminalEndpoint
        var turnID: AgentTurnID?
        var phase: BindingPhase
        let preparationTransition: KeyboardTransition
        var releaseTransition: KeyboardTransition?

        var value: TerminalEndpointBinding {
            TerminalEndpointBinding(
                token: token,
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
    private var keyboardTransitions: [TerminalEndpointID: KeyboardTransition]
        = [:]
    private var losses: [TerminalEndpointPinLoss] = []
    private var eventSubscribers: [
        UUID: AsyncStream<TerminalEndpointRegistryEvent>.Continuation
    ] = [:]

    public init() {}

    public func register(_ endpoint: TerminalEndpoint) throws {
        guard routeMatchesConversation(endpoint) else {
            throw TerminalEndpointRegistryError.endpointRouteMismatch
        }
        focusOrder &+= 1
        endpoints[endpoint.id] = RegisteredEndpoint(
            endpoint: endpoint,
            focusOrder: focusOrder
        )
    }

    public func unregister(_ endpointID: TerminalEndpointID) async {
        endpoints.removeValue(forKey: endpointID)
        var cleanup: [(
            threadID: AgentThreadID,
            token: TerminalEndpointBindingToken,
            removeAfterTransition: Bool,
            transition: KeyboardTransition
        )] = []
        for threadID in Array(bindings.keys) {
            guard var binding = bindings[threadID],
                binding.endpoint.id == endpointID,
                binding.phase != .pinLost,
                binding.phase != .releasing
            else { continue }
            let removeAfterTransition = binding.turnID == nil
            binding.phase = .pinLost
            let transition = enqueueKeyboardOwner(
                .user,
                for: binding.endpoint
            )
            binding.releaseTransition = transition
            bindings[threadID] = binding
            cleanup.append(
                (
                    threadID,
                    binding.token,
                    removeAfterTransition,
                    transition
                )
            )
            let loss = TerminalEndpointPinLoss(
                threadID: threadID,
                turnID: binding.turnID,
                phase: binding.turnID == nil ? .prepared : .active,
                conversationKey: binding.conversationKey,
                endpointID: endpointID
            )
            losses.append(loss)
            eventSubscribers.values.forEach {
                $0.yield(.pinLost(loss))
            }
        }
        for item in cleanup {
            await item.transition.task.value
            guard item.removeAfterTransition else { continue }
            removeBinding(threadID: item.threadID, token: item.token)
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
            token: TerminalEndpointBindingToken(),
            threadID: threadID,
            conversationKey: conversationKey,
            endpoint: endpoint,
            turnID: nil,
            phase: .preparing,
            preparationTransition: enqueueKeyboardOwner(
                .codex,
                for: endpoint
            ),
            releaseTransition: nil
        )
        bindings[threadID] = stored
        conversationOwners[conversationKey] = threadID
        await stored.preparationTransition.task.value
        guard var current = exactBinding(
            threadID: threadID,
            token: stored.token
        ) else {
            if endpoints[stored.endpoint.id] == nil {
                throw TerminalEndpointRegistryError.pinLost
            }
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        switch current.phase {
        case .pinLost:
            throw TerminalEndpointRegistryError.pinLost
        case .releasing:
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        case .preparing:
            if Task.isCancelled {
                current.phase = .releasing
                let transition = enqueueKeyboardOwner(
                    .user,
                    for: current.endpoint
                )
                current.releaseTransition = transition
                bindings[threadID] = current
                await transition.task.value
                removeBinding(threadID: threadID, token: current.token)
                throw CancellationError()
            }
            current.phase = .prepared
            bindings[threadID] = current
            return current.value
        case .prepared, .claimed:
            return current.value
        }
    }

    public func claimPreparedTurn(
        threadID: AgentThreadID,
        conversationKey: TerminalConversationKey,
        turnID: AgentTurnID
    ) async throws -> TerminalEndpointBinding {
        guard let initial = bindings[threadID] else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        guard initial.conversationKey == conversationKey else {
            throw TerminalEndpointRegistryError.bindingMismatch
        }
        if initial.phase == .preparing {
            await initial.preparationTransition.task.value
            try Task.checkCancellation()
        }
        guard var stored = exactBinding(
            threadID: threadID,
            token: initial.token
        ) else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        guard stored.phase != .pinLost else {
            throw TerminalEndpointRegistryError.pinLost
        }
        guard stored.phase != .releasing else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
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
        stored.phase = .claimed
        stored.turnID = turnID
        bindings[threadID] = stored
        return stored.value
    }

    public func confirmTurnID(
        threadID: AgentThreadID,
        turnID: AgentTurnID
    ) async throws {
        guard let initial = bindings[threadID] else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        if initial.phase == .preparing {
            await initial.preparationTransition.task.value
            try Task.checkCancellation()
        }
        guard var stored = exactBinding(
            threadID: threadID,
            token: initial.token
        ) else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        guard stored.phase != .pinLost else {
            throw TerminalEndpointRegistryError.pinLost
        }
        guard stored.phase != .releasing else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        if let existing = stored.turnID {
            guard existing == turnID else {
                throw TerminalEndpointRegistryError.turnIDMismatch
            }
            return
        }
        stored.phase = .claimed
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
        guard stored.phase != .pinLost else {
            throw TerminalEndpointRegistryError.pinLost
        }
        guard stored.phase != .releasing else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
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
        turnID: AgentTurnID
    ) async {
        guard var stored = bindings[threadID] else { return }
        guard stored.turnID == turnID else { return }
        let transition: KeyboardTransition
        if stored.phase == .releasing,
            let existing = stored.releaseTransition
        {
            transition = existing
        } else if stored.phase == .pinLost,
            let existing = stored.releaseTransition
        {
            stored.phase = .releasing
            bindings[threadID] = stored
            transition = existing
        } else {
            stored.phase = .releasing
            transition = enqueueKeyboardOwner(.user, for: stored.endpoint)
            stored.releaseTransition = transition
            bindings[threadID] = stored
        }
        await transition.task.value
        removeBinding(threadID: threadID, token: stored.token)
    }

    public func releasePrepared(
        threadID: AgentThreadID,
        conversationKey: TerminalConversationKey
    ) async {
        guard var stored = bindings[threadID],
            stored.turnID == nil,
            stored.conversationKey == conversationKey
        else { return }
        let transition: KeyboardTransition
        if stored.phase == .releasing,
            let existing = stored.releaseTransition
        {
            transition = existing
        } else if stored.phase == .pinLost,
            let existing = stored.releaseTransition
        {
            stored.phase = .releasing
            bindings[threadID] = stored
            transition = existing
        } else {
            stored.phase = .releasing
            transition = enqueueKeyboardOwner(.user, for: stored.endpoint)
            stored.releaseTransition = transition
            bindings[threadID] = stored
        }
        await transition.task.value
        removeBinding(threadID: threadID, token: stored.token)
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

    private func enqueueKeyboardOwner(
        _ owner: TerminalKeyboardOwner,
        for endpoint: TerminalEndpoint
    ) -> KeyboardTransition {
        let previous = keyboardTransitions[endpoint.id]?.task
        let transition = KeyboardTransition(
            task: Task {
                if let previous {
                    await previous.value
                }
                await endpoint.terminal.setKeyboardOwner(owner)
            }
        )
        keyboardTransitions[endpoint.id] = transition
        return transition
    }

    private func exactBinding(
        threadID: AgentThreadID,
        token: TerminalEndpointBindingToken
    ) -> StoredBinding? {
        guard let stored = bindings[threadID], stored.token == token else {
            return nil
        }
        return stored
    }

    private func removeBinding(
        threadID: AgentThreadID,
        token: TerminalEndpointBindingToken
    ) {
        guard let stored = exactBinding(threadID: threadID, token: token) else {
            return
        }
        bindings.removeValue(forKey: threadID)
        if conversationOwners[stored.conversationKey] == threadID {
            conversationOwners.removeValue(forKey: stored.conversationKey)
        }
    }

    private func routeMatchesConversation(_ endpoint: TerminalEndpoint) -> Bool {
        endpoint.route.expectedIdentity == endpoint.conversationKey.tmux
            && TerminalTargetIdentity(endpoint.route.target)
                == endpoint.conversationKey.target
    }
}
