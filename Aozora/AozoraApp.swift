import SwiftUI

@main
struct AozoraApp: App {
    @State private var appState = CIMSAppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(appState)
                .task { await appState.initialize() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.shutdown()
            }
        }
    }
}
