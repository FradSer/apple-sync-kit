import SQLite

// SQLite.swift's `Connection` serializes every operation through an internal
// serial queue, so it is safe to share across concurrency domains. The library
// predates `Sendable`, so we declare the conformance here (once, in the kit) for
// Swift 6 strict concurrency. Consuming projects import this and must not
// redeclare it.
extension Connection: @retroactive @unchecked Sendable {}
