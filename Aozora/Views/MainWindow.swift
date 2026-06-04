import SwiftUI

/// Root view for the CIMS chat interface.
///
/// Switches on ``CIMSAppState/phase`` to show either the auth gate,
/// a loading indicator, the main three-column interface, or an error view.
/// The three columns are: sidebar (sessions + nav), detail (contextual content),
/// and a collapsible inspector panel.
struct MainWindow: View {
    @Environment(CIMSAppState.self) var appState
    @State private var selection: SidebarSelection? = .session("default")
    @State private var inspectorVisible = true

    var body: some View {
        switch appState.phase {
        case .notAuthenticated:
            AuthGateView()
        case .loading:
            ProgressView("Initializing CIMS...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .error(message):
            errorView(message: message)
        case .ready:
            readyView
        }
    }

    /// The main three-column interface shown when gateway is ready.
    private var readyView: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            HSplitView {
                detailContent
                    .frame(minWidth: 400)

                if inspectorVisible {
                    InspectorView()
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        withAnimation { inspectorVisible.toggle() }
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
                }
            }
        }
    }

    /// Detail content based on sidebar selection.
    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case let .session(key):
            ChatView(sessionKey: key)
        case .settings:
            SettingsView()
        case .identity:
            ClaimBrowserView()
        case .plugins:
            PluginManagementView()
        case nil:
            Text("Select a session or tool")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Error view with retry button.
    ///
    /// - Parameter message: The error description to display.
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Initialization Failed")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await appState.initialize() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
