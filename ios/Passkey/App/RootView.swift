import SwiftUI

@MainActor
@Observable
final class AppModel {
  enum State {
    case loading
    case unauthenticated
    case authenticated(User)
  }

  @ObservationIgnored let api: any APIClient
  @ObservationIgnored let sessionStore: any SessionStore
  @ObservationIgnored let passkeyService: any PasskeyService
  @ObservationIgnored let signalService: any CredentialSignalService

  var state = State.loading
  var universalLinkMessage: String?

  init(
    api: any APIClient,
    sessionStore: any SessionStore,
    passkeyService: any PasskeyService,
    signalService: any CredentialSignalService
  ) {
    self.api = api
    self.sessionStore = sessionStore
    self.passkeyService = passkeyService
    self.signalService = signalService
  }

  static func live() -> AppModel {
    let sessionStore = KeychainSessionStore()
    return AppModel(
      api: LiveAPIClient(sessionStore: sessionStore),
      sessionStore: sessionStore,
      passkeyService: LivePasskeyService(),
      signalService: LiveCredentialSignalService()
    )
  }

  var authenticatedUser: User? {
    guard case let .authenticated(user) = state else { return nil }
    return user
  }

  func task() async {
    guard sessionStore.sessionToken() != nil else {
      state = .unauthenticated
      return
    }
    await reloadUser()
  }

  func reloadUser() async {
    do {
      let user = try await api.me()
      state = .authenticated(user)
    } catch {
      if let apiError = error as? APIError, apiError.isUnauthenticated {
        try? sessionStore.deleteSessionToken()
        state = .unauthenticated
      } else {
        state = .unauthenticated
      }
    }
  }

  func didReceiveSession(_ session: SessionResponse) async {
    do {
      try sessionStore.saveSessionToken(session.token)
      await reloadUser()
    } catch {
      universalLinkMessage = "サインイン状態を保存できませんでした"
    }
  }

  func sessionExpired() async {
    try? sessionStore.deleteSessionToken()
    state = .unauthenticated
  }

  func signOutButtonTapped() async {
    do {
      try await api.signOut()
    } catch {
    }
    try? sessionStore.deleteSessionToken()
    state = .unauthenticated
  }

  func accountDeleted() async {
    try? sessionStore.deleteSessionToken()
    state = .unauthenticated
  }

  func openedURL(_ url: URL) async {
    guard url.path == "/app/verify",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let fragment = components.fragment else {
      return
    }
    let queryItems = components.queryItems ?? []
    guard let flowIDString = queryItems.first(where: { $0.name == "flow" })?.value,
          let flowID = UUID(uuidString: flowIDString),
          fragment.hasPrefix("token=") else {
      universalLinkMessage = "メールのリンクを解釈できませんでした。メールに記載の 6 桁コードを入力してください。"
      return
    }
    guard let activeFlow = sessionStore.activeFlow(), activeFlow.id == flowID else {
      universalLinkMessage = "登録を始めた画面で、メールに記載の 6 桁コードを入力してください。"
      return
    }
    let token = String(fragment.dropFirst("token=".count))
    do {
      let response = try await api.verifyEmail(
        id: flowID,
        secret: activeFlow.secret,
        request: .token(token),
        includeSession: true
      )
      universalLinkMessage = nil
      if let session = response.session {
        try? sessionStore.deleteActiveFlow()
        await didReceiveSession(session)
        if let email = response.email,
           case let .authenticated(user) = state,
           let userHandle = Data(base64URLEncoded: user.userHandle) {
          try? await signalService.reportUserDetailsUpdate(userHandle: userHandle, newName: email)
        }
      }
    } catch let error as APIError {
      universalLinkMessage = error.errorDescription
    } catch {
      universalLinkMessage = "メールのリンクを確認できませんでした。コードを入力してください。"
    }
  }
}

struct RootView: View {
  let model: AppModel

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .unauthenticated:
        NavigationStack {
          SignInView(
            model: SignInViewModel(
              api: model.api,
              passkeyService: model.passkeyService,
              signalService: model.signalService,
              sessionStore: model.sessionStore
            ),
            onSignedIn: model.didReceiveSession
          )
        }
      case let .authenticated(user):
        if user.kind == .recovery {
          RecoveryCreatePasskeyView(
            model: RecoveryCreatePasskeyViewModel(
              api: model.api,
              passkeyService: model.passkeyService,
              sessionStore: model.sessionStore
            ),
            onCompleted: model.didReceiveSession
          )
        } else {
          MainTabView(model: model, user: user)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .passkeySessionExpired)) { _ in
      Task { await model.sessionExpired() }
    }
    .alert("メールのリンク", isPresented: universalLinkMessageIsPresented) {
      Button("OK") { model.universalLinkMessage = nil }
    } message: {
      Text(model.universalLinkMessage ?? "")
    }
  }

  private var universalLinkMessageIsPresented: Binding<Bool> {
    Binding(
      get: { model.universalLinkMessage != nil },
      set: { isPresented in
        if !isPresented { model.universalLinkMessage = nil }
      }
    )
  }
}

struct MainTabView: View {
  let model: AppModel
  let user: User

  var body: some View {
    TabView {
      PasskeysView(
        model: PasskeysViewModel(
          api: model.api,
          passkeyService: model.passkeyService,
          signalService: model.signalService,
          sessionStore: model.sessionStore
        )
      )
      .tabItem { Label("パスキー", systemImage: "key.fill") }

      SessionsView(
        model: SessionsViewModel(
          api: model.api,
          passkeyService: model.passkeyService,
          sessionStore: model.sessionStore
        )
      )
      .tabItem { Label("セッション", systemImage: "laptopcomputer.and.iphone") }

      AccountView(
        model: AccountViewModel(
          api: model.api,
          passkeyService: model.passkeyService,
          signalService: model.signalService,
          sessionStore: model.sessionStore,
          currentEmail: user.email,
          userHandle: user.userHandle
        ),
        currentEmail: user.email,
        onSignOut: model.signOutButtonTapped,
        onAccountDeleted: model.accountDeleted
      )
      .tabItem { Label("アカウント", systemImage: "person.circle") }
    }
  }
}
