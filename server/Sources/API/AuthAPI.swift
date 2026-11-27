public import Core
import Foundation
public import Hummingbird
public import HTTPTypes
import NIOCore

extension HTTPField.Name {
    static let xClient = Self("X-Client")!
    static let xClientIP = Self("X-Client-IP")!
    static let xClientCountry = Self("X-Client-Country")!
    static let xFlowSecret = Self("X-Flow-Secret")!
}

struct RequestCredentials {
    var client: ClientKind
    var ip: String
    var country: String?
    var userAgent: String?
    var sessionToken: String?
    var sessionUsesCookie: Bool
    var flowSecret: String?
}

extension AuthError: HTTPResponseError {
    public var status: HTTPResponse.Status { HTTPResponse.Status(code: statusCode) }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        var response = try context.responseEncoder.encode(
            ErrorResponse(error: .init(code: code, message: message)),
            from: request,
            context: context
        )
        response.status = status
        if let retryAfter {
            response.headers.append(.init(name: .retryAfter, value: String(retryAfter)))
        }
        return response
    }
}

public struct APIBuilder: Sendable {
    private let core: AuthCore

    public init(core: AuthCore) {
        self.core = core
    }

    public func router() -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        router.add(middleware: APIErrorMiddleware())

        router.post("/api/v1/email-verifications") { request, context in
            let input = try await request.decode(as: StartEmailVerificationRequest.self, context: context)
            let credentials = try self.credentials(request)
            let auth = try await self.optionalAuth(credentials)
            let result = try await self.core.startEmailVerification(
                email: input.email,
                purpose: input.purpose,
                client: credentials.client,
                ip: credentials.ip,
                userAgent: credentials.userAgent,
                authenticatedContext: auth
            )
            var headers = HTTPFields()
            if credentials.client == .web {
                headers.append(.init(name: .setCookie, value: self.flowCookie(result.secret)))
            }
            return try self.json(
                StartEmailVerificationResponse(
                    id: result.id,
                    status: result.status,
                    secret: credentials.client == .ios ? result.secret : nil
                ),
                status: .accepted,
                headers: headers,
                request: request,
                context: context
            )
        }

        router.get("/api/v1/email-verifications/:id") { request, context in
            guard let id = context.parameters.get("id", as: UUID.self) else { throw AuthError.invalidRequest() }
            let credentials = try self.credentials(request)
            guard let secret = credentials.flowSecret else { throw AuthError.deviceMismatch }
            let status = try await self.core.emailVerificationStatus(id: id, secret: secret)
            return try self.json(FlowStatusResponse(id: id, status: status), request: request, context: context)
        }

        router.post("/api/v1/email-verifications/:id/verify") { request, context in
            guard let id = context.parameters.get("id", as: UUID.self) else { throw AuthError.invalidRequest() }
            let input = try await request.decode(as: VerifyEmailRequest.self, context: context)
            let credentials = try self.credentials(request)
            guard let secret = credentials.flowSecret else { throw AuthError.deviceMismatch }
            let auth = try await self.optionalAuth(credentials)
            let result = try await self.core.verifyEmailVerification(
                id: id,
                secret: secret,
                token: input.token,
                code: input.code,
                authenticatedContext: auth,
                ip: credentials.ip,
                country: credentials.country,
                userAgent: credentials.userAgent
            )
            switch result {
            case .signupVerified:
                return try self.json(VerifyEmailResponse(status: "verified", kind: nil, token: nil, email: nil), request: request, context: context)
            case .recoverySession(let issued):
                return try self.sessionJSON(
                    VerifyEmailResponse(status: "verified", kind: .recovery, token: credentials.client == .ios ? issued.token : nil, email: nil),
                    issued: issued,
                    credentials: credentials,
                    deleteFlowCookie: true,
                    request: request,
                    context: context
                )
            case .emailChanged(let issued, let email):
                return try self.sessionJSON(
                    VerifyEmailResponse(status: "verified", kind: .normal, token: credentials.client == .ios ? issued.token : nil, email: email),
                    issued: issued,
                    credentials: credentials,
                    deleteFlowCookie: true,
                    request: request,
                    context: context
                )
            }
        }

        router.post("/api/v1/registrations/options") { request, context in
            let credentials = try self.credentials(request)
            let auth = try await self.optionalAuth(credentials, allowRecovery: true)
            let data = try await self.core.registrationOptions(flowSecret: auth == nil ? credentials.flowSecret : nil, authenticatedContext: auth)
            return try self.json(RegistrationOptionsResponse(data: data), request: request, context: context)
        }

        router.post("/api/v1/registrations") { request, context in
            let wire = try await request.decode(as: RegistrationCredentialRequest.self, context: context)
            let credentials = try self.credentials(request)
            let auth = try await self.optionalAuth(credentials, allowRecovery: true)
            let result = try await self.core.finishRegistration(
                input: wire.coreInput(),
                flowSecret: auth == nil ? credentials.flowSecret : nil,
                authenticatedContext: auth,
                userAgent: credentials.userAgent,
                country: credentials.country,
                client: credentials.client
            )
            let body = RegistrationResponse(
                user: UserResponse(user: result.user),
                passkey: self.core.present(result.passkey),
                token: credentials.client == .ios && !result.session.token.isEmpty ? result.session.token : nil
            )
            if result.session.token.isEmpty {
                return try self.json(body, request: request, context: context)
            }
            return try self.sessionJSON(
                body,
                issued: result.session,
                credentials: credentials,
                deleteFlowCookie: auth == nil && credentials.flowSecret != nil,
                request: request,
                context: context
            )
        }

        router.post("/api/v1/authentications/options") { request, context in
            let input = try? await request.decode(as: AuthenticationOptionsRequest.self, context: context)
            let credentials = try self.credentials(request)
            let auth = try await self.optionalAuth(credentials)
            let data = try await self.core.authenticationOptions(reauth: input?.reauth ?? false, authenticatedContext: auth)
            return try self.json(AuthenticationOptionsResponse(data: data), request: request, context: context)
        }

        router.post("/api/v1/authentications") { request, context in
            let wire = try await request.decode(as: AuthenticationCredentialRequest.self, context: context)
            let credentials = try self.credentials(request)
            let auth = try await self.optionalAuth(credentials)
            let result = try await self.core.finishAuthentication(
                input: wire.coreInput(),
                authenticatedContext: auth,
                ip: credentials.ip,
                userAgent: credentials.userAgent,
                client: credentials.client
            )
            let body = AuthenticationResponse(
                user: UserResponse(user: result.user),
                token: credentials.client == .ios ? result.session.token : nil,
                reauthenticated: result.isReauthentication
            )
            return try self.sessionJSON(body, issued: result.session, credentials: credentials, request: request, context: context)
        }

        router.get("/api/v1/sessions") { request, context in
            let auth = try await self.requiredAuth(request)
            let sessions = try await self.core.listSessions(context: auth)
            return try self.json(SessionsResponse(sessions: sessions), request: request, context: context)
        }

        router.delete("/api/v1/sessions/current") { request, context in
            let auth = try await self.requiredAuth(request, allowRecovery: true)
            try await self.core.signOut(context: auth)
            var headers = HTTPFields()
            if try self.credentials(request).sessionUsesCookie {
                headers.append(.init(name: .setCookie, value: self.deleteSessionCookie()))
            }
            return try self.json(EmptyResponse(), status: .noContent, headers: headers, request: request, context: context)
        }

        router.delete("/api/v1/sessions/:id") { request, context in
            guard let id = context.parameters.get("id", as: UUID.self) else { throw AuthError.invalidRequest() }
            let auth = try await self.requiredAuth(request)
            try await self.core.revokeSession(id: id, context: auth)
            return try self.json(EmptyResponse(), status: .noContent, request: request, context: context)
        }

        router.post("/api/v1/sessions/revoke-others") { request, context in
            let auth = try await self.requiredAuth(request)
            try await self.core.revokeOtherSessions(context: auth)
            return try self.json(EmptyResponse(), status: .noContent, request: request, context: context)
        }

        router.get("/api/v1/me") { request, context in
            let auth = try await self.requiredAuth(request, allowRecovery: true)
            let body = MeResponse(
                id: auth.user.id,
                email: auth.user.email,
                userHandle: auth.user.userHandle.pkBase64URLEncodedString(),
                kind: auth.session.kind,
                recoveredAt: auth.user.recoveredAt
            )
            return try self.json(body, request: request, context: context)
        }

        router.delete("/api/v1/me") { request, context in
            let input = try await request.decode(as: DeleteMeRequest.self, context: context)
            let auth = try await self.requiredAuth(request)
            let credentials = try self.credentials(request)
            try await self.core.deleteUser(email: input.email, context: auth, country: credentials.country)
            var headers = HTTPFields()
            if try self.credentials(request).sessionUsesCookie {
                headers.append(.init(name: .setCookie, value: self.deleteSessionCookie()))
            }
            return try self.json(EmptyResponse(), status: .noContent, headers: headers, request: request, context: context)
        }

        router.get("/api/v1/passkeys") { request, context in
            let auth = try await self.requiredAuth(request)
            let passkeys = try await self.core.listPasskeys(context: auth)
            return try self.json(PasskeysResponse(passkeys: passkeys), request: request, context: context)
        }

        router.patch("/api/v1/passkeys/:id") { request, context in
            guard let idString = context.parameters.get("id"), let credentialID = Data(pkBase64URL: idString) else {
                throw AuthError.invalidRequest()
            }
            let input = try await request.decode(as: PatchPasskeyRequest.self, context: context)
            let auth = try await self.requiredAuth(request)
            let passkey = try await self.core.renamePasskey(credentialID: credentialID, name: input.name, context: auth)
            return try self.json(passkey, request: request, context: context)
        }

        router.delete("/api/v1/passkeys/:id") { request, context in
            guard let idString = context.parameters.get("id"), let credentialID = Data(pkBase64URL: idString) else {
                throw AuthError.invalidRequest()
            }
            let auth = try await self.requiredAuth(request)
            let credentials = try self.credentials(request)
            let remaining = try await self.core.deletePasskey(credentialID: credentialID, context: auth, country: credentials.country)
            return try self.json(
                DeletePasskeyResponse(allAcceptedCredentialIds: remaining.map { $0.pkBase64URLEncodedString() }),
                request: request,
                context: context
            )
        }

        return router
    }

    private func credentials(_ request: Request) throws -> RequestCredentials {
        let origin = request.headers[.origin]
        let client: ClientKind = origin != nil ? .web : (request.headers[.xClient] == "ios" ? .ios : .web)
        let cookieHeader = request.headers[.cookie]
        let cookieSession = cookieValue("session", from: cookieHeader)
        let bearer = request.headers[.authorization].flatMap { value -> String? in
            guard value.hasPrefix("Bearer ") else { return nil }
            return String(value.dropFirst(7))
        }
        if cookieSession != nil && bearer != nil { throw AuthError.invalidRequest("Cookie と Bearer を同時に送ることはできません") }
        let mutating = request.method == .post || request.method == .patch || request.method == .delete
        if client == .web && mutating && (cookieSession != nil || cookieValue("flow", from: cookieHeader) != nil) {
            guard origin == core.configuration.origin else { throw AuthError.originMismatch }
        }
        return RequestCredentials(
            client: client,
            ip: request.headers[.xClientIP] ?? "unknown",
            country: request.headers[.xClientCountry],
            userAgent: request.headers[.userAgent],
            sessionToken: cookieSession ?? bearer,
            sessionUsesCookie: cookieSession != nil,
            flowSecret: cookieValue("flow", from: cookieHeader) ?? request.headers[.xFlowSecret]
        )
    }

    private func optionalAuth(_ credentials: RequestCredentials, allowRecovery: Bool = false) async throws -> AuthenticatedContext? {
        guard let token = credentials.sessionToken else { return nil }
        return try await core.authenticate(token: token, allowRecovery: allowRecovery)
    }

    private func requiredAuth(_ request: Request, allowRecovery: Bool = false) async throws -> AuthenticatedContext {
        let credentials = try credentials(request)
        guard let auth = try await optionalAuth(credentials, allowRecovery: allowRecovery) else { throw AuthError.unauthenticated }
        return auth
    }

    private func json<Body: Encodable>(
        _ body: Body,
        status: HTTPResponse.Status = .ok,
        headers: HTTPFields = HTTPFields(),
        request: Request,
        context: some RequestContext
    ) throws -> Response {
        var response = try context.responseEncoder.encode(body, from: request, context: context)
        response.status = status
        response.headers.append(contentsOf: headers)
        return response
    }

    private func sessionJSON<Body: Encodable>(
        _ body: Body,
        issued: IssuedSession,
        credentials: RequestCredentials,
        deleteFlowCookie: Bool = false,
        request: Request,
        context: some RequestContext
    ) throws -> Response {
        var headers = HTTPFields()
        if credentials.client == .web {
            headers.append(.init(name: .setCookie, value: sessionCookie(issued.token)))
            if deleteFlowCookie {
                headers.append(.init(name: .setCookie, value: deleteFlowCookieValue()))
            }
        }
        return try json(body, headers: headers, request: request, context: context)
    }

    private func cookieValue(_ name: String, from header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == "__Host-\(name)" else { continue }
            return String(pair[1])
        }
        return nil
    }

    private func sessionCookie(_ token: String) -> String {
        "__Host-session=\(token); HttpOnly; Secure; SameSite=Strict; Path=/"
    }

    private func deleteSessionCookie() -> String {
        "__Host-session=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0"
    }

    private func flowCookie(_ secret: String) -> String {
        "__Host-flow=\(secret); HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=1500"
    }

    private func deleteFlowCookieValue() -> String {
        "__Host-flow=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0"
    }
}

struct APIErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    @concurrent func handle(_ request: Request, context: Context, next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as AuthError {
            return try error.response(from: request, context: context)
        } catch {
            var response = try context.responseEncoder.encode(
                ErrorResponse(error: .init(code: "internal_server_error", message: "サーバーエラーが発生しました")),
                from: request,
                context: context
            )
            response.status = .internalServerError
            return response
        }
    }
}
