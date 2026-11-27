import AuthenticationServices
import SwiftUI

@MainActor
@Observable
final class RecoveryViewModel {
  enum Step {
    case email
    case verify
  }

  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let sessionStore: any SessionStore

  var email = ""
  var code = ""
  var step = Step.email
  var errorMessage: String?
  var isWorking = false
  @ObservationIgnored private var flowID: UUID?
  @ObservationIgnored private var flowSecret: String?
  @ObservationIgnored var flowExpiresAt: Date?

  init(api: any APIClient, sessionStore: any SessionStore) {
    self.api = api
    self.sessionStore = sessionStore
  }

  func startButtonTapped() async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let response = try await api.startEmailVerification(email: email, purpose: .recovery)
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

  func verifyButtonTapped() async -> SessionResponse? {
    guard let flowID, let flowSecret else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let response = try await api.verifyEmail(id: flowID, secret: flowSecret, request: .code(code), includeSession: false)
      try? sessionStore.deleteActiveFlow()
      return response.session
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
      return nil
    } catch {
      errorMessage = "コードを確認できませんでした。もう一度お試しください。"
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
}

struct RecoveryView: View {
  @State var model: RecoveryViewModel
  let onRecoverySession: (SessionResponse) async -> Void

  init(model: RecoveryViewModel, onRecoverySession: @escaping (SessionResponse) async -> Void) {
    _model = State(initialValue: model)
    self.onRecoverySession = onRecoverySession
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
            verifyButtonTapped: {
              guard let session = await model.verifyButtonTapped() else { return }
              await onRecoverySession(session)
            },
            resendButtonTapped: model.startButtonTapped
          )
          Button("最初からやり直す", action: model.startOverButtonTapped)
        }
      }
      .padding()
    }
    .navigationTitle("アカウント回復")
  }

  private var emailStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("アカウントを回復")
        .font(.largeTitle.bold())
      Text("メールアドレスの所有を確認した後、新しいパスキーの作成が必要です。回復セッションは 15 分間有効です。")
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
          Text("回復メールを送信")
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
}

@MainActor
@Observable
final class RecoveryCreatePasskeyViewModel {
  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let passkeyService: any PasskeyService
  @ObservationIgnored let sessionStore: any SessionStore

  var errorMessage: String?
  var isWorking = false
  var completedSession: SessionResponse?
  var existingPasskeys: [PasskeyCredential] = []

  init(api: any APIClient, passkeyService: any PasskeyService, sessionStore: any SessionStore) {
    self.api = api
    self.passkeyService = passkeyService
    self.sessionStore = sessionStore
  }

  func createPasskeyButtonTapped() async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let options = try await api.registrationOptions(flowSecret: nil)
      let registration = try await passkeyService.createPasskey(options: options)
      let response = try await api.register(registration, flowSecret: nil)
      guard let token = response.token else { throw APIError.missingSessionToken }
      let session = SessionResponse(token: token)
      try sessionStore.saveSessionToken(session.token)
      existingPasskeys = (try? await api.passkeys()) ?? []
      completedSession = session
    } catch {
      if isCancellation(error) { return }
      errorMessage = "パスキーを作成できませんでした。もう一度お試しください。回復を完了するには新しいパスキーが必要です。"
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

struct RecoveryCreatePasskeyView: View {
  @State var model: RecoveryCreatePasskeyViewModel
  let onCompleted: (SessionResponse) async -> Void

  init(model: RecoveryCreatePasskeyViewModel, onCompleted: @escaping (SessionResponse) async -> Void) {
    _model = State(initialValue: model)
    self.onCompleted = onCompleted
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("新しいパスキーを作成")
          .font(.largeTitle.bold())
        Text("アカウント回復を完了するには、新しいパスキーの作成が必要です。作成すると他のセッションはすべてサインアウトされます。")
          .foregroundStyle(.secondary)
        if model.completedSession == nil {
          Button {
            Task { await model.createPasskeyButtonTapped() }
          } label: {
            HStack {
              if model.isWorking { ProgressView() }
              Text("パスキーを作成")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking)
        } else {
          VStack(alignment: .leading, spacing: 12) {
            Text("アカウント回復が完了しました")
              .font(.title2.bold())
            Text("紛失した端末のパスキーは削除してください。回復直後は削除できない場合があります。")
              .foregroundStyle(.secondary)
            ForEach(model.existingPasskeys) { passkey in
              Label(passkey.name ?? "パスキー", systemImage: "key.fill")
            }
            Button("続ける") {
              Task {
                if let session = model.completedSession {
                  await onCompleted(session)
                }
              }
            }
            .buttonStyle(.borderedProminent)
          }
        }
        if let errorMessage = model.errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
      .padding()
    }
  }
}
