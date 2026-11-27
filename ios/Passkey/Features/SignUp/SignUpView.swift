import AuthenticationServices
import SwiftUI

@MainActor
@Observable
final class SignUpViewModel {
  enum Step {
    case email
    case verify
    case createPasskey
  }

  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let passkeyService: any PasskeyService
  @ObservationIgnored let sessionStore: any SessionStore

  var email = ""
  var code = ""
  var step = Step.email
  var errorMessage: String?
  var isWorking = false
  var created = false
  @ObservationIgnored private var flowID: UUID?
  @ObservationIgnored private var flowSecret: String?
  @ObservationIgnored var flowExpiresAt: Date?

  init(api: any APIClient, passkeyService: any PasskeyService, sessionStore: any SessionStore) {
    self.api = api
    self.passkeyService = passkeyService
    self.sessionStore = sessionStore
  }

  func startButtonTapped() async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let response = try await api.startEmailVerification(email: email, purpose: .signup)
      flowID = response.id
      flowSecret = response.secret
      flowExpiresAt = response.expiresAt ?? Date().addingTimeInterval(600)
      try sessionStore.saveActiveFlow(id: response.id, secret: response.secret)
      code = ""
      step = .verify
    } catch {
      errorMessage = "確認メールを送信できませんでした。メールアドレスを確認して、もう一度お試しください。"
    }
  }

  func verifyButtonTapped() async {
    guard let flowID, let flowSecret else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      _ = try await api.verifyEmail(id: flowID, secret: flowSecret, request: .code(code), includeSession: false)
      step = .createPasskey
    } catch let error as APIError {
      switch error.errorCode {
      case "invalid_code":
        errorMessage = "コードが正しくありません"
      case "device_mismatch":
        errorMessage = "登録を始めた画面でコードを入力してください"
      case "flow_expired":
        errorMessage = "時間切れです。コードを再送するか、最初からやり直してください。"
      default:
        errorMessage = error.errorDescription
      }
    } catch {
      errorMessage = "コードを確認できませんでした。もう一度お試しください。"
    }
  }

  func pollVerificationStatus() async {
    while step == .verify && !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
      guard step == .verify, !Task.isCancelled, let flowID, let flowSecret else { return }
      if let status = try? await api.emailVerificationStatus(id: flowID, secret: flowSecret) {
        switch status.status {
        case .verified:
          step = .createPasskey
        case .expired, .consumed:
          errorMessage = "時間切れです。コードを再送するか、最初からやり直してください。"
        case .pending:
          break
        }
      }
    }
  }

  func createPasskeyButtonTapped() async -> SessionResponse? {
    guard let flowSecret else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let options = try await api.registrationOptions(flowSecret: flowSecret)
      let registration = try await passkeyService.createPasskey(options: options)
      let response = try await api.register(registration, flowSecret: flowSecret)
      guard let token = response.token else { throw APIError.missingSessionToken }
      try? sessionStore.deleteActiveFlow()
      created = true
      return SessionResponse(token: token)
    } catch {
      presentCreationError(error)
      return nil
    }
  }

  func startOverButtonTapped() {
    try? sessionStore.deleteActiveFlow()
    flowID = nil
    flowSecret = nil
    code = ""
    step = .email
    errorMessage = nil
  }

  private func presentCreationError(_ error: any Error) {
    if isCancellation(error) { return }
    if let apiError = error as? APIError {
      switch apiError.errorCode {
      case "credential_exists":
        errorMessage = "このパスキーは登録済みです。このパスキーでサインインできます。"
      case "email_taken":
        errorMessage = "このメールアドレスのアカウントは既にあります。サインインまたはアカウント回復をしてください。"
      case "invalid_challenge", "flow_expired":
        errorMessage = "時間切れです。もう一度お試しください。"
      default:
        errorMessage = "パスキーを作成できませんでした。もう一度お試しください。サインアップにはパスキーが必要です。"
      }
    } else {
      errorMessage = "パスキーを作成できませんでした。もう一度お試しください。サインアップにはパスキーが必要です。"
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

struct SignUpView: View {
  @State var model: SignUpViewModel
  let onSignedIn: (SessionResponse) async -> Void

  init(model: SignUpViewModel, onSignedIn: @escaping (SessionResponse) async -> Void) {
    _model = State(initialValue: model)
    self.onSignedIn = onSignedIn
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        switch model.step {
        case .email:
          emailStep
        case .verify:
          VerificationCodeSection(
            code: Bindable(model).code,
            isWorking: model.isWorking,
            errorMessage: model.errorMessage,
            expiresAt: model.flowExpiresAt,
            verifyButtonTapped: model.verifyButtonTapped,
            resendButtonTapped: model.startButtonTapped
          )
          .task { await model.pollVerificationStatus() }
          Button("最初からやり直す", action: model.startOverButtonTapped)
        case .createPasskey:
          createPasskeyStep
        }
      }
      .padding()
    }
    .navigationTitle("サインアップ")
  }

  private var emailStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("アカウントを作成")
        .font(.largeTitle.bold())
      Text("メールアドレスの所有を確認してから、パスキーを作成します。")
        .foregroundStyle(.secondary)
      TextField("メールアドレス", text: Bindable(model).email)
        .keyboardType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textContentType(.emailAddress)
        .textFieldStyle(.roundedBorder)
      Button {
        Task { await model.startButtonTapped() }
      } label: {
        HStack {
          if model.isWorking { ProgressView() }
          Text("確認メールを送信")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.isWorking || model.email.isEmpty)
      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
  }

  private var createPasskeyStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("パスキーを作成")
        .font(.largeTitle.bold())
      Text("パスキーは、顔・指紋・画面ロックを使ってサインインするためのデジタルの鍵です。iCloud キーチェーンや Google パスワードマネージャーなどのパスワード管理に保存され、同じアカウントの他の端末でも使えます。")
        .foregroundStyle(.secondary)
      Button {
        Task {
          if let session = await model.createPasskeyButtonTapped() {
            await onSignedIn(session)
          }
        }
      } label: {
        HStack {
          if model.isWorking { ProgressView() }
          Text("パスキーを作成")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.isWorking)
      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityAddTraits(.updatesFrequently)
      }
      if model.created {
        Text("パスキーを作成しました。次回からこのパスキーでサインインできます。")
          .foregroundStyle(.secondary)
      }
    }
  }
}
