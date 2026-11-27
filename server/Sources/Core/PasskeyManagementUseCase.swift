public import Foundation
import Logging

public struct PasskeyPresentation: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var customName: String?
    public var providerName: String?
    public var iconLight: String?
    public var iconDark: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var backupEligible: Bool
    public var backupState: Bool
    public var transports: [String]
    public var signCountAnomalyAt: Date?
}

extension AuthCore {
    public func listPasskeys(context: AuthenticatedContext) async throws -> [PasskeyPresentation] {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        return try await store.passkeys(userID: context.user.id).map(present(_:))
    }

    public func renamePasskey(credentialID: Data, name: String?, context: AuthenticatedContext) async throws -> PasskeyPresentation {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        if let name {
            guard !name.isEmpty, name.count <= 64 else { throw AuthError.invalidRequest("名前は 1〜64 文字で指定してください") }
        }
        guard let passkey = try await store.renamePasskey(userID: context.user.id, credentialID: credentialID, name: name) else {
            throw AuthError.notFound
        }
        return present(passkey)
    }

    public func deletePasskey(credentialID: Data, context: AuthenticatedContext) async throws -> [Data] {
        guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
        try requireReauthenticated(context)
        try requireNotRecentlyRecovered(context)
        let result = try await store.deletePasskeyIfNotLast(userID: context.user.id, credentialID: credentialID)
        switch result {
        case .deleted(let remaining):
            securityEvent("passkey_deleted", metadata: ["user_id": "\(context.user.id.uuidString)"])
            await mailQueue.enqueue(notificationMail(email: context.user.email, operation: "パスキー削除", deviceLabel: context.session.deviceLabel))
            return remaining
        case .notFound: throw AuthError.notFound
        case .lastPasskey: throw AuthError.lastPasskey
        }
    }

    public func present(_ passkey: Passkey) -> PasskeyPresentation {
        let providerName = aaguidCatalog.providerName(aaguid: passkey.aaguid)
        let icons = aaguidCatalog.icons(aaguid: passkey.aaguid)
        let defaultName = "\(providerName ?? "パスキー")（\(Self.displayDateFormatter.string(from: passkey.createdAt))）"
        return PasskeyPresentation(
            id: passkey.id.pkBase64URLEncodedString(),
            name: passkey.name ?? defaultName,
            customName: passkey.name,
            providerName: providerName,
            iconLight: icons.light,
            iconDark: icons.dark,
            createdAt: passkey.createdAt,
            lastUsedAt: passkey.lastUsedAt,
            backupEligible: passkey.backupEligible,
            backupState: passkey.backupState,
            transports: passkey.transports,
            signCountAnomalyAt: passkey.signCountAnomalyAt
        )
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()
}
