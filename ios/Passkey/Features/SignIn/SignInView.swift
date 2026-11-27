import AuthenticationServices
import SwiftUI

@MainActor
@Observable
final class SignInViewModel {
  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let passkeyService: any PasskeyService
  @ObservationIgnored let signalService: any CredentialSignalService
  @ObservationIgnored let sessionStore: any SessionStore

  var email = ""
  var errorMessage: String?
  var isModalWorking = false
  @ObservationIgnored private var autoFillTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?

  init(api: any APIClient, passkeyService: any PasskeyService, signalService: any CredentialSignalService, sessionStore: any SessionStore) {
    self.api = api
    self.passkeyService = passkeyService
    self.signalService = signalService
    self.sessionStore = sessionStore
  }

  func appeared() {
    startAutoFill()
  }

  func disappeared() {
    autoFillTask?.cancel()
    refreshTask?.cancel()
    passkeyService.cancelCurrentRequest()
  }

  func modalSignInButtonTapped() async -> SessionResponse? {
    cancelAutoFill()
    isModalWorking = true
    defer { isModalWorking = false }
    do {
      let options = try await api.authenticationOptions(reauth: false)
      let assertion = try await passkeyService.assertPasskey(options: options, presentation: .modal)
      return try await finishAuthentication(assertion)
    } catch {
      present(error, cancelledMessage: nil)
      startAutoFill()
      return nil
    }
  }

  private func startAutoFill() {
    cancelAutoFill()
    autoFillTask = Task {
      await performAutoFill()
    }
    refreshTask = Task {
      try? await Task.sleep(nanoseconds: 240 * 1_000_000_000)
      guard !Task.isCancelled else { return }
      startAutoFill()
    }
  }

  private func cancelAutoFill() {
    autoFillTask?.cancel()
    refreshTask?.cancel()
    autoFillTask = nil
    refreshTask = nil
    passkeyService.cancelCurrentRequest()
  }

  private func performAutoFill() async {
    do {
      let options = try await api.authenticationOptions(reauth: false)
      let assertion = try await passkeyService.assertPasskey(options: options, presentation: .autoFill)
      _ = try await finishAuthentication(assertion)
    } catch {
      if !Task.isCancelled, !isCancellation(error) {
        present(error, cancelledMessage: nil)
      }
    }
  }

  private func finishAuthentication(_ assertion: AssertionFinishRequest) async throws -> SessionResponse? {
    do {
      return try await api.authenticate(assertion)
    } catch let error as APIError {
      if error.errorCode == "unknown_credential",
         let credentialID = Data(base64URLEncoded: assertion.id) {
        try? await signalService.reportUnknownCredential(credentialID: credentialID)
      }
      throw error
    }
  }

  private func present(_ error: any Error, cancelledMessage: String?) {
    if isCancellation(error) {
      errorMessage = cancelledMessage
      return
    }
    if let apiError = error as? APIError {
      switch apiError.errorCode {
      case "unknown_credential":
        errorMessage = "このパスキーは使えません。削除されたパスキーです。別のパスキーを選ぶか、アカウントを回復してください。"
      case "invalid_challenge":
        errorMessage = "時間切れです。もう一度お試しください。"
      case "rate_limited":
        errorMessage = "しばらく待ってから再試行してください。"
      default:
        errorMessage = apiError.errorDescription
      }
    } else {
      errorMessage = "サインインできませんでした。もう一度お試しください。"
    }
  }

  private func isCancellation(_ error: any Error) -> Bool {
    if case PasskeyServiceError.cancelled = error { return true }
    if let authorizationError = error as? ASAuthorizationError {
      return authorizationError.code == .canceled
    }
    return false
  }
}

struct SignInView: View {
  @State var model: SignInViewModel
  let onSignedIn: (SessionResponse) async -> Void

  init(model: SignInViewModel, onSignedIn: @escaping (SessionResponse) async -> Void) {
    _model = State(initialValue: model)
    self.onSignedIn = onSignedIn
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("パスキーでサインイン")
            .font(.largeTitle.bold())
          Text("メールアドレス欄から保存済みのパスキーを選ぶか、ボタンからサインインできます。")
            .foregroundStyle(.secondary)
        }

        TextField("メールアドレス", text: Bindable(model).email)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textContentType(.username)
          .textFieldStyle(.roundedBorder)

        Button {
          Task {
            if let session = await model.modalSignInButtonTapped() {
              await onSignedIn(session)
            }
          }
        } label: {
          HStack {
            if model.isModalWorking { ProgressView() }
            Text("パスキーでサインイン")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isModalWorking)

        if let errorMessage = model.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityAddTraits(.updatesFrequently)
        }

        VStack(spacing: 12) {
          NavigationLink("はじめて利用する") {
            SignUpView(
              model: SignUpViewModel(
                api: model.api,
                passkeyService: model.passkeyService,
                sessionStore: model.sessionStore
              ),
              onSignedIn: onSignedIn
            )
          }
          NavigationLink("パスキーを使えない場合（アカウント回復）") {
            RecoveryView(
              model: RecoveryViewModel(
                api: model.api,
                sessionStore: model.sessionStore
              ),
              onRecoverySession: onSignedIn
            )
          }
        }
        .frame(maxWidth: .infinity)

        Link("パスキーについてのヘルプ", destination: URL(string: "https://passkeys.dev/docs/intro/what-are-passkeys/")!)
          .font(.footnote)
      }
      .padding()
    }
    .onAppear { model.appeared() }
    .onDisappear { model.disappeared() }
  }
}
