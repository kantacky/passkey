import SwiftUI

@main
struct PasskeyApp: App {
  @State private var model = AppModel.live()

  var body: some Scene {
    WindowGroup {
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
        RootView(model: model)
          .task { await model.task() }
          .onOpenURL { url in
            Task { await model.openedURL(url) }
          }
      } else {
        Text("PasskeyTests")
      }
    }
  }
}
