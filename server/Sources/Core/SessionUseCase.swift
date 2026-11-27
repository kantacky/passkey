public import Foundation
import Logging

public struct SessionInfo: Codable, Sendable, Equatable {
    public var id: UUID
    public var deviceLabel: String
    public var createdAt: Date
    public var lastSeenAt: Date
    public var isCurrent: Bool
}

extension AuthCore {
    public func listSessions(context: AuthenticatedContext) async throws -> [SessionInfo] {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        return try await store.sessions(userID: context.user.id).map {
            SessionInfo(
                id: $0.id,
                deviceLabel: $0.deviceLabel,
                createdAt: $0.createdAt,
                lastSeenAt: $0.lastSeenAt,
                isCurrent: $0.id == context.session.id
            )
        }
    }

    public func signOut(context: AuthenticatedContext) async throws {
        try await store.deleteSession(id: context.session.id)
        securityEvent("session_revoked", metadata: ["user_id": "\(context.user.id.uuidString)", "scope": "current"])
    }

    public func revokeSession(id: UUID, context: AuthenticatedContext) async throws {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        try requireReauthenticated(context)
        guard let target = try await store.session(id: id), target.userID == context.user.id else { throw AuthError.notFound }
        try await store.deleteSession(id: target.id)
        securityEvent("session_revoked", metadata: ["user_id": "\(context.user.id.uuidString)", "scope": "selected"])
    }

    public func revokeOtherSessions(context: AuthenticatedContext) async throws {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        try requireReauthenticated(context)
        try await store.deleteSessions(userID: context.user.id, except: context.session.id)
        securityEvent("session_revoked", metadata: ["user_id": "\(context.user.id.uuidString)", "scope": "others"])
    }

    public func deleteUser(email confirmationEmail: String, context: AuthenticatedContext, country: String? = nil) async throws {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        try requireReauthenticated(context)
        try requireNotRecentlyRecovered(context)
        guard SecurityUtils.normalizeEmail(confirmationEmail) == SecurityUtils.normalizeEmail(context.user.email) else {
            throw AuthError.invalidRequest("メールアドレスが一致しません")
        }
        try await store.deleteUser(userID: context.user.id)
        securityEvent("user_deleted", metadata: ["user_id": "\(context.user.id.uuidString)"])
        await mailQueue.enqueue(notificationMail(email: context.user.email, operation: "ユーザー削除", deviceLabel: context.session.deviceLabel, country: country))
    }
}
