import Foundation

public struct Effect<Schema: HiveSchema>: Sendable {
    public var writes: [AnyHiveWrite<Schema>]
    public var spawn: [HiveTaskSeed<Schema>]
    public var next: HiveNext?
    public var interrupt: HiveInterruptRequest<Schema>?

    public init(
        writes: [AnyHiveWrite<Schema>] = [],
        spawn: [HiveTaskSeed<Schema>] = [],
        next: HiveNext? = nil,
        interrupt: HiveInterruptRequest<Schema>? = nil
    ) {
        self.writes = writes
        self.spawn = spawn
        self.next = next
        self.interrupt = interrupt
    }

    func merged(with other: Effect<Schema>) -> Effect<Schema> {
        var merged = self
        merged.writes.append(contentsOf: other.writes)
        merged.spawn.append(contentsOf: other.spawn)
        if let next = other.next {
            merged.next = next
        }
        if let interrupt = other.interrupt {
            merged.interrupt = interrupt
        }
        return merged
    }

    func materialize() -> HiveNodeOutput<Schema> {
        HiveNodeOutput(
            writes: writes,
            spawn: spawn,
            next: (next ?? .useGraphEdges)._hiveDSLNormalized,
            interrupt: interrupt
        )
    }
}

extension HiveNext {
    var _hiveDSLNormalized: HiveNext {
        switch self {
        case .nodes(let nodes) where nodes.isEmpty:
            return .end
        default:
            return self
        }
    }
}

@resultBuilder
public enum EffectsBuilder<Schema: HiveSchema> {
    public static func buildExpression(_ expression: Effect<Schema>) -> Effect<Schema> {
        expression
    }

    public static func buildBlock(_ components: Effect<Schema>...) -> Effect<Schema> {
        components.reduce(Effect(), { $0.merged(with: $1) })
    }

    public static func buildOptional(_ component: Effect<Schema>?) -> Effect<Schema> {
        component ?? Effect()
    }

    public static func buildEither(first component: Effect<Schema>) -> Effect<Schema> {
        component
    }

    public static func buildEither(second component: Effect<Schema>) -> Effect<Schema> {
        component
    }

    public static func buildArray(_ components: [Effect<Schema>]) -> Effect<Schema> {
        components.reduce(Effect(), { $0.merged(with: $1) })
    }

    public static func buildFinalResult(_ component: Effect<Schema>) -> HiveNodeOutput<Schema> {
        component.materialize()
    }
}

public func Effects<Schema: HiveSchema>(
    @EffectsBuilder<Schema> _ content: () -> HiveNodeOutput<Schema>
) -> HiveNodeOutput<Schema> {
    content()
}

// MARK: - Effect Primitives

public func Set<Schema: HiveSchema, Value: Sendable>(
    _ key: HiveChannelKey<Schema, Value>,
    _ value: Value
) -> Effect<Schema> {
    Effect(writes: [AnyHiveWrite(key, value)])
}

public func Append<Schema: HiveSchema, Value: RangeReplaceableCollection & Sendable>(
    _ key: HiveChannelKey<Schema, Value>,
    elements: Value
) -> Effect<Schema> {
    Effect(writes: [AnyHiveWrite(key, elements)])
}

public func GoTo<Schema: HiveSchema>(_ node: String) -> Effect<Schema> {
    Effect(next: .nodes([HiveNodeID(node)]))
}

public func GoTo<Schema: HiveSchema>(_ nodes: String...) -> Effect<Schema> {
    Effect(next: .nodes(nodes.map(HiveNodeID.init)))
}

public func UseGraphEdges<Schema: HiveSchema>() -> Effect<Schema> {
    Effect(next: .useGraphEdges)
}

public func End<Schema: HiveSchema>() -> Effect<Schema> {
    Effect(next: .end)
}

public func Interrupt<Schema: HiveSchema>(_ payload: Schema.InterruptPayload) -> Effect<Schema> {
    Effect(interrupt: HiveInterruptRequest(payload: payload))
}

public func SpawnEach<Schema: HiveSchema, Items: Sequence>(
    _ items: Items,
    node: String,
    local makeLocal: (Items.Element) -> HiveTaskLocalStore<Schema>
) -> Effect<Schema> {
    let id = HiveNodeID(node)
    let seeds = items.map { item in
        HiveTaskSeed(nodeID: id, local: makeLocal(item))
    }
    return Effect(spawn: Array(seeds))
}
