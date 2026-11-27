import AuthenticationServices
import Foundation
import UIKit

enum PasskeyServiceError: Error, Equatable {
  case cancelled
  case invalidOptions
  case unexpectedCredential
  case missingAttestationObject
  case passkeyManagerUnavailable
}

enum AssertionPresentation: Sendable {
  case autoFill
  case modal
}

protocol PasskeyService: Sendable {
  func createPasskey(options: RegistrationOptions) async throws -> RegistrationFinishRequest
  func assertPasskey(options: AuthenticationOptions, presentation: AssertionPresentation) async throws -> AssertionFinishRequest
  func cancelCurrentRequest()
}

@MainActor
final class LivePasskeyService: NSObject, PasskeyService {
  private var continuation: CheckedContinuation<any ASAuthorizationCredential, any Error>?
  private var controller: ASAuthorizationController?

  func createPasskey(options: RegistrationOptions) async throws -> RegistrationFinishRequest {
    guard let challenge = Data(base64URLEncoded: options.challenge),
          let userID = Data(base64URLEncoded: options.user.id) else {
      throw PasskeyServiceError.invalidOptions
    }

    let platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rp.id)
    let platformRequest = platformProvider.createCredentialRegistrationRequest(
      challenge: challenge,
      name: options.user.name,
      userID: userID
    )
    platformRequest.displayName = options.user.displayName
    platformRequest.userVerificationPreference = .required
    platformRequest.attestationPreference = .none

    let securityKeyProvider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: options.rp.id)
    let securityKeyRequest = securityKeyProvider.createCredentialRegistrationRequest(
      challenge: challenge,
      displayName: options.user.displayName,
      name: options.user.name,
      userID: userID
    )
    securityKeyRequest.userVerificationPreference = .required
    securityKeyRequest.attestationPreference = .none
    securityKeyRequest.residentKeyPreference = .required
    securityKeyRequest.credentialParameters = options.pubKeyCredParams.map {
      ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier($0.alg))
    }
    securityKeyRequest.excludedCredentials = securityKeyDescriptors(from: options.excludeCredentials ?? [])

    let credential = try await perform(requests: [platformRequest, securityKeyRequest], presentation: .modal)
    guard let registration = credential as? any ASAuthorizationPublicKeyCredentialRegistration else {
      throw PasskeyServiceError.unexpectedCredential
    }
    guard let attestationObject = registration.rawAttestationObject else {
      throw PasskeyServiceError.missingAttestationObject
    }
    let credentialID = registration.credentialID.base64URLEncodedString
    return RegistrationFinishRequest(
      id: credentialID,
      rawId: credentialID,
      type: "public-key",
      response: RegistrationResponsePayload(
        clientDataJSON: registration.rawClientDataJSON.base64URLEncodedString,
        attestationObject: attestationObject.base64URLEncodedString,
        transports: []
      )
    )
  }

  func assertPasskey(options: AuthenticationOptions, presentation: AssertionPresentation) async throws -> AssertionFinishRequest {
    guard let challenge = Data(base64URLEncoded: options.challenge) else {
      throw PasskeyServiceError.invalidOptions
    }
    let platformProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpId)
    let platformRequest = platformProvider.createCredentialAssertionRequest(challenge: challenge)
    platformRequest.userVerificationPreference = .required
    platformRequest.allowedCredentials = platformDescriptors(from: options.allowCredentials ?? [])

    var requests: [ASAuthorizationRequest] = [platformRequest]
    if presentation == .modal {
      let securityKeyProvider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpId)
      let securityKeyRequest = securityKeyProvider.createCredentialAssertionRequest(challenge: challenge)
      securityKeyRequest.userVerificationPreference = .required
      securityKeyRequest.allowedCredentials = securityKeyDescriptors(from: options.allowCredentials ?? [])
      requests.append(securityKeyRequest)
    }

    let credential = try await perform(requests: requests, presentation: presentation)
    guard let assertion = credential as? any ASAuthorizationPublicKeyCredentialAssertion else {
      throw PasskeyServiceError.unexpectedCredential
    }
    let credentialID = assertion.credentialID.base64URLEncodedString
    return AssertionFinishRequest(
      id: credentialID,
      rawId: credentialID,
      type: "public-key",
      response: AssertionResponsePayload(
        clientDataJSON: assertion.rawClientDataJSON.base64URLEncodedString,
        authenticatorData: assertion.rawAuthenticatorData.base64URLEncodedString,
        signature: assertion.signature.base64URLEncodedString,
        userHandle: assertion.userID.base64URLEncodedString
      )
    )
  }

  func cancelCurrentRequest() {
    guard let continuation else { return }
    self.continuation = nil
    controller?.cancel()
    controller = nil
    continuation.resume(throwing: PasskeyServiceError.cancelled)
  }

  private func perform(
    requests: [ASAuthorizationRequest],
    presentation: AssertionPresentation
  ) async throws -> any ASAuthorizationCredential {
    cancelCurrentRequest()
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let controller = ASAuthorizationController(authorizationRequests: requests)
      controller.delegate = self
      controller.presentationContextProvider = self
      self.controller = controller
      switch presentation {
      case .autoFill:
        controller.performAutoFillAssistedRequests()
      case .modal:
        controller.performRequests()
      }
    }
  }

  private func platformDescriptors(from credentials: [CredentialDescriptor]) -> [ASAuthorizationPlatformPublicKeyCredentialDescriptor] {
    credentials.compactMap { credential in
      Data(base64URLEncoded: credential.id).map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
    }
  }

  private func securityKeyDescriptors(from credentials: [CredentialDescriptor]) -> [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor] {
    credentials.compactMap { credential in
      guard let id = Data(base64URLEncoded: credential.id) else { return nil }
      return ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
        credentialID: id,
        transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported
      )
    }
  }
}

extension LivePasskeyService: ASAuthorizationControllerDelegate {
  nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    Task { @MainActor in
      guard let continuation else { return }
      self.continuation = nil
      self.controller = nil
      continuation.resume(returning: authorization.credential)
    }
  }

  nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
    Task { @MainActor in
      guard let continuation else { return }
      self.continuation = nil
      self.controller = nil
      continuation.resume(throwing: error)
    }
  }
}

extension LivePasskeyService: ASAuthorizationControllerPresentationContextProviding {
  nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      for windowScene in windowScenes {
        if let window = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first {
          return window
        }
      }
      guard let windowScene = windowScenes.first else {
        preconditionFailure("No UIWindowScene is connected to present the passkey UI.")
      }
      return UIWindow(windowScene: windowScene)
    }
  }
}
