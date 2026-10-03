/// Carries a value the compiler can't prove Sendable across a concurrency boundary.
/// Only use for values that are safe to hand off (e.g. a one-shot callback).
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
