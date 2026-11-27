public import Foundation
import Logging

public struct EmailVerificationStartResult: Sendable, Equatable {
    public var id: UUID
    public var secret: String
    public var status: FlowStatus
}

public enum EmailVerificationVerifyResult: Sendable, Equatable {
    case signupVerified
    case recoverySession(IssuedSession)
    case emailChanged(IssuedSession, email: String)
}

extension AuthCore {
    public func startEmailVerification(
        email rawEmail: String,
        purpose: VerificationPurpose,
        client: ClientKind,
        ip: String,
        userAgent: String?,
        authenticatedContext: AuthenticatedContext? = nil
    ) async throws -> EmailVerificationStartResult {
        let email = SecurityUtils.normalizeEmail(rawEmail)
        guard email.contains("@"), email.count <= 320 else { throw AuthError.invalidRequest("メールアドレスが正しくありません") }

        var sessionID: UUID?
        if purpose == .emailChange {
            guard let context = authenticatedContext else { throw AuthError.unauthenticated }
            guard context.session.kind == .normal else { throw AuthError.recoverySessionRestricted }
            try requireReauthenticated(context)
            try requireNotRecentlyRecovered(context)
            sessionID = context.session.id
        }

        let current = now
        let ipKey = "email_verify:ip:\(SecurityUtils.normalizeClientIP(ip))"
        let ipCount = try await store.incrementRateLimit(key: ipKey, windowStart: SecurityUtils.hourWindowStart(for: current))
        if ipCount > 20 {
            securityEvent("rate_limited", metadata: ["scope": "email_verify_ip"])
            let retryAfter = max(1, 3600 - Int(current.timeIntervalSince(SecurityUtils.hourWindowStart(for: current))))
            throw AuthError(statusCode: 429, code: "rate_limited", message: AuthError.rateLimited.message, retryAfter: retryAfter)
        }

        let normalizedIPHash = SecurityUtils.sha256(email).map { String(format: "%02x", $0) }.joined()
        let emailKey = "email_verify:email:\(normalizedIPHash)"
        let emailCount = try await store.incrementRateLimit(key: emailKey, windowStart: SecurityUtils.hourWindowStart(for: current))
        let latest = try await store.latestEmailVerificationCreatedAt(email: email, purpose: purpose)
        let maySendMail = emailCount <= 5 && (latest == nil || latest!.addingTimeInterval(60) <= current)

        try await store.invalidateActiveEmailVerifications(email: email, purpose: purpose, at: current)

        let token = SecurityUtils.randomToken()
        let code = SecurityUtils.randomCode()
        let secret = SecurityUtils.randomToken()
        let flow = EmailVerification(
            id: SecurityUtils.uuidv7(at: current),
            email: email,
            purpose: purpose,
            sessionID: sessionID,
            client: client,
            tokenHash: SecurityUtils.sha256(token),
            codeHash: SecurityUtils.sha256(code),
            secretHash: SecurityUtils.sha256(secret),
            createdAt: current,
            expiresAt: current.addingTimeInterval(configuration.emailVerificationLifetime)
        )
        try await store.createEmailVerification(flow)
        securityEvent("email_verification_started", metadata: ["email_hash": "\(emailLogHash(email))", "purpose": "\(purpose.rawValue)"])

        if maySendMail {
            let existingUser = try await store.user(email: email)
            let message: MailMessage
            switch purpose {
            case .signup where existingUser != nil:
                message = MailMessage(
                    to: email,
                    subject: "Passkey アカウントは既にあります",
                    text: "このメールアドレスのアカウントは既にあります。サインインまたはアカウント回復をしてください。"
                )
            case .recovery where existingUser == nil:
                message = MailMessage(
                    to: email,
                    subject: "Passkey アカウントが見つかりません",
                    text: "このメールアドレスのアカウントはありません。新規登録からアカウントを作成してください。"
                )
            case .emailChange where existingUser != nil && existingUser?.id != authenticatedContext?.user.id:
                message = MailMessage(
                    to: email,
                    subject: "このメールアドレスは既に使われています",
                    text: "このメールアドレスは既に使われているため、Passkey アカウントのメールアドレスには変更できません。"
                )
            default:
                message = verificationMail(email: email, purpose: purpose, flowID: flow.id, token: token, code: code, client: client)
            }
            await mailQueue.enqueue(message)
        }

        return EmailVerificationStartResult(id: flow.id, secret: secret, status: .pending)
    }

    public func emailVerificationStatus(id: UUID, secret: String) async throws -> FlowStatus {
        guard let flow = try await store.emailVerification(id: id) else { throw AuthError.notFound }
        guard flow.secretHash == SecurityUtils.sha256(secret) else { throw AuthError.deviceMismatch }
        return flow.status(at: now)
    }

    public func verifyEmailVerification(
        id: UUID,
        secret: String,
        token: String?,
        code: String?,
        authenticatedContext: AuthenticatedContext? = nil,
        ip: String,
        country: String? = nil,
        userAgent: String?
    ) async throws -> EmailVerificationVerifyResult {
        guard (token == nil) != (code == nil) else { throw AuthError.invalidRequest("token または code のどちらか一方を指定してください") }
        guard let flow = try await store.emailVerification(id: id) else { throw AuthError.notFound }
        guard flow.secretHash == SecurityUtils.sha256(secret) else { throw AuthError.deviceMismatch }
        let current = now
        guard flow.status(at: current) == .pending else { throw AuthError.flowExpired }

        let suppliedHash: Data
        var isCodeFailure = false
        if let token {
            suppliedHash = SecurityUtils.sha256(token)
        } else if let code {
            guard code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else { throw AuthError.invalidCode }
            suppliedHash = SecurityUtils.sha256(code)
            isCodeFailure = true
        } else {
            throw AuthError.invalidRequest()
        }

        guard suppliedHash == (token == nil ? flow.codeHash : flow.tokenHash) else {
            if isCodeFailure {
                let emailHash = SecurityUtils.sha256(flow.email).map { String(format: "%02x", $0) }.joined()
                let failures = try await store.incrementRateLimit(key: "code_fail:email:\(emailHash)", windowStart: SecurityUtils.hourWindowStart(for: current))
                securityEvent("email_code_failed", metadata: ["email_hash": "\(emailLogHash(flow.email))"])
                if failures >= 5 {
                    try await store.invalidateActiveEmailVerifications(email: flow.email, at: current)
                }
            }
            throw AuthError.invalidCode
        }

        switch flow.purpose {
        case .signup:
            try await store.markEmailVerificationVerified(
                id: flow.id,
                verifiedAt: current,
                verifiedExpiresAt: current.addingTimeInterval(configuration.verifiedFlowLifetime)
            )
            securityEvent("email_verification_verified", metadata: ["purpose": "signup"])
            return .signupVerified

        case .recovery:
            guard let user = try await store.user(email: flow.email) else { throw AuthError.invalidRequest() }
            let device = SecurityUtils.deviceLabel(userAgent: userAgent, client: flow.client)
            let issued = makeSession(userID: user.id, kind: .recovery, flowID: flow.id, deviceLabel: device, reauthenticated: false)
            guard try await store.consumeFlowAndCreateRecoverySession(flowID: flow.id, session: issued.session, consumedAt: current) else {
                throw AuthError.flowExpired
            }
            securityEvent("recovery_started", metadata: ["user_id": "\(user.id.uuidString)"])
            await mailQueue.enqueue(notificationMail(email: user.email, operation: "アカウント回復の開始", deviceLabel: device, country: country))
            return .recoverySession(issued)

        case .emailChange:
            guard let context = authenticatedContext, context.session.kind == .normal else { throw AuthError.unauthenticated }
            guard context.session.id == flow.sessionID else { throw AuthError.deviceMismatch }
            guard context.session.userID == context.user.id else { throw AuthError.unauthenticated }
            let newToken = SecurityUtils.randomToken()
            let result = try await store.changeEmailConsumingFlow(
                flowID: flow.id,
                userID: context.user.id,
                newEmail: flow.email,
                sessionID: context.session.id,
                newTokenHash: tokenHash(newToken),
                at: current
            )
            switch result {
            case .emailTaken: throw AuthError.emailTaken
            case .flowUnavailable: throw AuthError.flowExpired
            case .sessionUnavailable: throw AuthError.unauthenticated
            case .success: break
            }
            var rotated = context.session
            rotated.tokenHash = tokenHash(newToken)
            let issued = IssuedSession(session: rotated, token: newToken)
            securityEvent("email_changed", metadata: ["user_id": "\(context.user.id.uuidString)"])
            let device = SecurityUtils.deviceLabel(userAgent: userAgent, client: flow.client)
            await mailQueue.enqueue(notificationMail(email: context.user.email, operation: "メールアドレス変更", deviceLabel: device, detail: "新しいアドレス: \(maskEmail(flow.email))", country: country))
            await mailQueue.enqueue(notificationMail(email: flow.email, operation: "メールアドレス変更の完了", deviceLabel: device, country: country))
            return .emailChanged(issued, email: flow.email)
        }
    }

    private func maskEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "***" }
        let name = email[..<at]
        let domain = email[at...]
        return "\(name.prefix(1))***\(domain)"
    }
}
