public import Foundation

extension AuthCore {
    public func cleanupExpiredRecords() async throws -> CleanupCounts {
        let current = now
        return try await store.cleanupExpired(
            now: current,
            idleBefore: current.addingTimeInterval(-configuration.sessionIdleLifetime),
            rateLimitWindowBefore: current.addingTimeInterval(-48 * 3600)
        )
    }
}
