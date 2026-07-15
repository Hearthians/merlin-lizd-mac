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
    public let handle: AgentTurnHandle
    public let turnID: AgentTurnID?
    public let conversationKey: TerminalConversationKey
    public let endpoint: TerminalEndpoint

    public var threadID: AgentThreadID {
        handle.threadID
    }

    public init(
        token: TerminalEndpointBindingToken = TerminalEndpointBindingToken(),
        handle: AgentTurnHandle,
        turnID: AgentTurnID?,
        conversationKey: TerminalConversationKey,
        endpoint: TerminalEndpoint
    ) {
        self.token = token
        self.handle = handle
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

public enum TerminalEndpointPinPhase: Hashable, Sendable {
    case prepared
    case active
}

public struct TerminalEndpointPinID: Hashable, Sendable {
    public let handle: AgentTurnHandle
    public let bindingToken: TerminalEndpointBindingToken

    public init(
        handle: AgentTurnHandle,
        bindingToken: TerminalEndpointBindingToken
    ) {
        self.handle = handle
        self.bindingToken = bindingToken
    }
}

public struct TerminalEndpointPin: Hashable, Sendable {
    public let id: TerminalEndpointPinID
    public let turnID: AgentTurnID?
    public let phase: TerminalEndpointPinPhase
    public let conversationKey: TerminalConversationKey
    public let endpointID: TerminalEndpointID

    public var handle: AgentTurnHandle { id.handle }
    public var bindingToken: TerminalEndpointBindingToken {
        id.bindingToken
    }
    public var threadID: AgentThreadID {
        handle.threadID
    }

    public init(
        handle: AgentTurnHandle,
        bindingToken: TerminalEndpointBindingToken,
        turnID: AgentTurnID?,
        phase: TerminalEndpointPinPhase,
        conversationKey: TerminalConversationKey,
        endpointID: TerminalEndpointID
    ) {
        self.id = TerminalEndpointPinID(
            handle: handle,
            bindingToken: bindingToken
        )
        self.turnID = turnID
        self.phase = phase
        self.conversationKey = conversationKey
        self.endpointID = endpointID
    }
}

public struct TerminalEndpointPinLoss: Equatable, Sendable {
    public let pin: TerminalEndpointPin

    public var handle: AgentTurnHandle { pin.handle }
    public var bindingToken: TerminalEndpointBindingToken {
        pin.bindingToken
    }
    public var threadID: AgentThreadID { pin.threadID }
    public var turnID: AgentTurnID? { pin.turnID }
    public var phase: TerminalEndpointPinPhase { pin.phase }
    public var conversationKey: TerminalConversationKey {
        pin.conversationKey
    }
    public var endpointID: TerminalEndpointID { pin.endpointID }

    public init(pin: TerminalEndpointPin) {
        self.pin = pin
    }
}

public enum TerminalEndpointRegistryEvent: Equatable, Sendable {
    case upsert(TerminalEndpointPin, revision: UInt64)
    case removed(TerminalEndpointPinID, revision: UInt64)
    case pinLost(TerminalEndpointPinLoss, revision: UInt64)
    case reconciliationRequired(revision: UInt64)

    public var revision: UInt64 {
        switch self {
        case let .upsert(_, revision),
            let .removed(_, revision),
            let .pinLost(_, revision),
            let .reconciliationRequired(revision):
            revision
        }
    }
}

public struct TerminalEndpointRegistrySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let pins: [TerminalEndpointPinID: TerminalEndpointPin]

    public init(
        revision: UInt64,
        pins: [TerminalEndpointPinID: TerminalEndpointPin]
    ) {
        self.revision = revision
        self.pins = pins
    }
}

public struct TerminalEndpointRegistrySubscription: Sendable {
    public let snapshot: TerminalEndpointRegistrySnapshot
    public let events: AsyncStream<TerminalEndpointRegistryEvent>

    public init(
        snapshot: TerminalEndpointRegistrySnapshot,
        events: AsyncStream<TerminalEndpointRegistryEvent>
    ) {
        self.snapshot = snapshot
        self.events = events
    }
}

public enum TerminalEndpointRegistryError: Error, Equatable, Sendable {
    case endpointNotFound
    case endpointAlreadyRegistered(TerminalEndpointID)
    case endpointRouteMismatch
    case noFocusedEndpoint
    case threadAlreadyPrepared
    case conversationBusy
    case preparedBindingNotFound
    case turnIDMismatch
    case bindingMismatch
    case pinLost
}

struct TerminalEndpointRegistryStateSnapshot: Equatable, Sendable {
    let endpointCount: Int
    let bindingCount: Int
    let conversationOwnerCount: Int
    let keyboardTransitionCount: Int
    let pinLossHistoryCount: Int
    let retiringEndpointCount: Int
    let eventSubscriberCount: Int
    let eventBufferCapacity: Int
}

public actor TerminalEndpointRegistry {
    private static let eventBufferCapacity = 1

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
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct StoredBinding: Sendable {
        let token: TerminalEndpointBindingToken
        let handle: AgentTurnHandle
        let conversationKey: TerminalConversationKey
        let endpoint: TerminalEndpoint
        var turnID: AgentTurnID?
        var phase: BindingPhase
        let preparationTransition: KeyboardTransition
        var releaseTransition: KeyboardTransition?

        var value: TerminalEndpointBinding {
            TerminalEndpointBinding(
                token: token,
                handle: handle,
                turnID: turnID,
                conversationKey: conversationKey,
                endpoint: endpoint
            )
        }
    }

    private var endpoints: [TerminalEndpointID: RegisteredEndpoint] = [:]
    private var retiringEndpointIDs: Set<TerminalEndpointID> = []
    private var bindings: [AgentThreadID: StoredBinding] = [:]
    private var conversationOwners: [TerminalConversationKey: AgentTurnHandle]
        = [:]
    private var focusOrder: UInt64 = 0
    private var keyboardTransitions: [TerminalEndpointID: KeyboardTransition]
        = [:]
    private var eventSubscribers: [
        UUID: AsyncStream<TerminalEndpointRegistryEvent>.Continuation
    ] = [:]
    private var pinRevision: UInt64 = 0
    private var subscriptionHook: (@Sendable () async -> Void)?
    private let bindingValidationHook: (@Sendable () async -> Void)?
    private let claimPreparedTurnHook: (@Sendable () async -> Void)?

    public init() {
        subscriptionHook = nil
        bindingValidationHook = nil
        claimPreparedTurnHook = nil
    }

    init(bindingValidationHook: @escaping @Sendable () async -> Void) {
        subscriptionHook = nil
        self.bindingValidationHook = bindingValidationHook
        claimPreparedTurnHook = nil
    }

    init(claimPreparedTurnHook: @escaping @Sendable () async -> Void) {
        subscriptionHook = nil
        bindingValidationHook = nil
        self.claimPreparedTurnHook = claimPreparedTurnHook
    }

    public func register(_ endpoint: TerminalEndpoint) throws {
        guard endpoints[endpoint.id] == nil,
            !retiringEndpointIDs.contains(endpoint.id)
        else {
            throw TerminalEndpointRegistryError.endpointAlreadyRegistered(
                endpoint.id
            )
        }
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
        guard endpoints[endpointID] != nil else { return }
        retiringEndpointIDs.insert(endpointID)
        defer { retiringEndpointIDs.remove(endpointID) }
        endpoints.removeValue(forKey: endpointID)
        var cleanup: [(
            handle: AgentTurnHandle,
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
            let lostPin = TerminalEndpointPin(
                handle: binding.handle,
                bindingToken: binding.token,
                turnID: binding.turnID,
                phase: binding.turnID == nil ? .prepared : .active,
                conversationKey: binding.conversationKey,
                endpointID: endpointID
            )
            binding.phase = .pinLost
            let transition = enqueueKeyboardOwner(
                .user,
                for: binding.endpoint
            )
            binding.releaseTransition = transition
            bindings[threadID] = binding
            cleanup.append(
                (
                    binding.handle,
                    binding.token,
                    removeAfterTransition,
                    transition
                )
            )
            publishPinMutation { revision in
                .pinLost(
                    TerminalEndpointPinLoss(pin: lostPin),
                    revision: revision
                )
            }
        }
        for item in cleanup {
            await item.transition.task.value
            guard item.removeAfterTransition else { continue }
            removeBinding(handle: item.handle, token: item.token)
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

    func prepareTurn(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken,
        conversationKey: TerminalConversationKey
    ) async throws -> TerminalEndpointBinding {
        let threadID = handle.threadID
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
            token: token,
            handle: handle,
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
        conversationOwners[conversationKey] = handle
        publishPinUpsert(stored)
        await stored.preparationTransition.task.value
        guard var current = exactBinding(
            handle: handle,
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
                publishPinRemoval(current)
                await transition.task.value
                removeBinding(handle: handle, token: current.token)
                throw CancellationError()
            }
            current.phase = .prepared
            bindings[threadID] = current
            return current.value
        case .prepared, .claimed:
            return current.value
        }
    }

    func claimPreparedTurn(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken,
        conversationKey: TerminalConversationKey,
        turnID: AgentTurnID
    ) async throws -> TerminalEndpointBinding {
        await claimPreparedTurnHook?()
        guard let initial = exactBinding(handle: handle, token: token) else {
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
            handle: handle,
            token: token
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
        bindings[handle.threadID] = stored
        publishPinUpsert(stored)
        return stored.value
    }

    func confirmTurnID(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken,
        turnID: AgentTurnID
    ) async throws {
        guard let initial = exactBinding(handle: handle, token: token) else {
            throw TerminalEndpointRegistryError.preparedBindingNotFound
        }
        if initial.phase == .preparing {
            await initial.preparationTransition.task.value
            try Task.checkCancellation()
        }
        guard var stored = exactBinding(
            handle: handle,
            token: token
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
        bindings[handle.threadID] = stored
        publishPinUpsert(stored)
    }

    func binding(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken,
        turnID: AgentTurnID,
        conversationKey: TerminalConversationKey
    ) async throws -> TerminalEndpointBinding {
        await bindingValidationHook?()
        guard let stored = exactBinding(handle: handle, token: token) else {
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

    func releaseTurn(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken,
        turnID: AgentTurnID
    ) async {
        guard var stored = exactBinding(handle: handle, token: token) else {
            return
        }
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
            bindings[handle.threadID] = stored
            transition = existing
        } else {
            stored.phase = .releasing
            transition = enqueueKeyboardOwner(.user, for: stored.endpoint)
            stored.releaseTransition = transition
            bindings[handle.threadID] = stored
            publishPinRemoval(stored)
        }
        await transition.task.value
        removeBinding(handle: handle, token: token)
    }

    func releasePrepared(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken,
        conversationKey: TerminalConversationKey
    ) async {
        guard var stored = exactBinding(handle: handle, token: token),
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
            bindings[handle.threadID] = stored
            transition = existing
        } else {
            stored.phase = .releasing
            transition = enqueueKeyboardOwner(.user, for: stored.endpoint)
            stored.releaseTransition = transition
            bindings[handle.threadID] = stored
            publishPinRemoval(stored)
        }
        await transition.task.value
        removeBinding(handle: handle, token: token)
    }

    func testingStateSnapshot() -> TerminalEndpointRegistryStateSnapshot {
        TerminalEndpointRegistryStateSnapshot(
            endpointCount: endpoints.count,
            bindingCount: bindings.count,
            conversationOwnerCount: conversationOwners.count,
            keyboardTransitionCount: keyboardTransitions.count,
            pinLossHistoryCount: 0,
            retiringEndpointCount: retiringEndpointIDs.count,
            eventSubscriberCount: eventSubscribers.count,
            eventBufferCapacity: Self.eventBufferCapacity
        )
    }

    /// Atomically captures the authoritative pin set and starts a bounded
    /// event stream. Consumers should initialize their known pins from the
    /// returned snapshot, apply newer upserts and removals by stable pin ID,
    /// and replace their pins with `pinSnapshot()` after reconciliation.
    public func subscribe() async -> TerminalEndpointRegistrySubscription {
        await subscriptionHook?()
        let subscriberID = UUID()
        let pair = AsyncStream<TerminalEndpointRegistryEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(subscriberID) }
        }
        eventSubscribers[subscriberID] = pair.continuation
        return TerminalEndpointRegistrySubscription(
            snapshot: makePinSnapshot(),
            events: pair.stream
        )
    }

    func setSubscriptionHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        subscriptionHook = hook
    }

    /// Returns the current authoritative exact pins at the latest registry
    /// revision. Use this to replace local state after a reconciliation event.
    public func pinSnapshot() -> TerminalEndpointRegistrySnapshot {
        makePinSnapshot()
    }

    private func publish(_ event: TerminalEndpointRegistryEvent) {
        var terminatedSubscriberIDs: [UUID] = []
        for (subscriberID, subscriber) in eventSubscribers {
            switch subscriber.yield(event) {
            case .enqueued:
                break
            case .dropped:
                _ = subscriber.yield(
                    .reconciliationRequired(revision: pinRevision)
                )
            case .terminated:
                terminatedSubscriberIDs.append(subscriberID)
            @unknown default:
                terminatedSubscriberIDs.append(subscriberID)
            }
        }
        for subscriberID in terminatedSubscriberIDs {
            eventSubscribers.removeValue(forKey: subscriberID)
        }
    }

    private func removeEventSubscriber(_ subscriberID: UUID) {
        eventSubscribers.removeValue(forKey: subscriberID)
    }

    private func makePinSnapshot() -> TerminalEndpointRegistrySnapshot {
        let pins = bindings.values.compactMap(makePin)
        return TerminalEndpointRegistrySnapshot(
            revision: pinRevision,
            pins: Dictionary(
                uniqueKeysWithValues: pins.map { ($0.id, $0) }
            )
        )
    }

    private func publishPinMutation(
        _ makeEvent: (UInt64) -> TerminalEndpointRegistryEvent
    ) {
        pinRevision += 1
        publish(makeEvent(pinRevision))
    }

    private func publishPinUpsert(_ binding: StoredBinding) {
        guard let pin = makePin(binding) else { return }
        publishPinMutation { revision in
            .upsert(pin, revision: revision)
        }
    }

    private func publishPinRemoval(_ binding: StoredBinding) {
        let id = TerminalEndpointPinID(
            handle: binding.handle,
            bindingToken: binding.token
        )
        publishPinMutation { revision in
            .removed(id, revision: revision)
        }
    }

    private func makePin(_ binding: StoredBinding) -> TerminalEndpointPin? {
        let phase: TerminalEndpointPinPhase
        switch binding.phase {
        case .preparing, .prepared:
            phase = .prepared
        case .claimed:
            phase = .active
        case .releasing, .pinLost:
            return nil
        }
        return TerminalEndpointPin(
            handle: binding.handle,
            bindingToken: binding.token,
            turnID: binding.turnID,
            phase: phase,
            conversationKey: binding.conversationKey,
            endpointID: binding.endpoint.id
        )
    }

    private func enqueueKeyboardOwner(
        _ owner: TerminalKeyboardOwner,
        for endpoint: TerminalEndpoint
    ) -> KeyboardTransition {
        let previous = keyboardTransitions[endpoint.id]?.task
        let token = UUID()
        let transition = KeyboardTransition(
            token: token,
            task: Task {
                if let previous {
                    await previous.value
                }
                await endpoint.terminal.setKeyboardOwner(owner)
                self.completeKeyboardTransition(
                    endpointID: endpoint.id,
                    token: token
                )
            }
        )
        keyboardTransitions[endpoint.id] = transition
        return transition
    }

    private func completeKeyboardTransition(
        endpointID: TerminalEndpointID,
        token: UUID
    ) {
        guard keyboardTransitions[endpointID]?.token == token else { return }
        keyboardTransitions.removeValue(forKey: endpointID)
    }

    private func exactBinding(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken
    ) -> StoredBinding? {
        guard let stored = bindings[handle.threadID],
            stored.handle == handle,
            stored.token == token
        else {
            return nil
        }
        return stored
    }

    private func removeBinding(
        handle: AgentTurnHandle,
        token: TerminalEndpointBindingToken
    ) {
        guard let stored = exactBinding(handle: handle, token: token) else {
            return
        }
        bindings.removeValue(forKey: handle.threadID)
        if conversationOwners[stored.conversationKey] == handle {
            conversationOwners.removeValue(forKey: stored.conversationKey)
        }
    }

    private func routeMatchesConversation(_ endpoint: TerminalEndpoint) -> Bool {
        endpoint.route.expectedIdentity == endpoint.conversationKey.tmux
            && TerminalTargetIdentity(endpoint.route.target)
                == endpoint.conversationKey.target
    }
}
