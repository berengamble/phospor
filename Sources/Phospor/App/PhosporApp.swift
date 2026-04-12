import SwiftUI

@main
struct PhosporApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // No main window — the control panel is created programmatically by
    // AppDelegate so we can run as a borderless floating utility.
    Settings { EmptyView() }
  }
}
