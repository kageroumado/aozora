import SwiftUI

/// Navigation selection for the sidebar.
///
/// Determines which view is shown in the detail column.
nonisolated enum SidebarSelection: Hashable {
    /// A chat session identified by its key.
    case session(String)
    /// Settings panel.
    case settings
    /// Identity/mirror claim browser.
    case identity
    /// Plugin management view.
    case plugins
}

/// Sidebar view with session list and navigation links.
///
/// Shows a "Sessions" section with conversation sessions and a "Tools"
/// section with links to Settings, Identity, and Plugins views.
/// In IPC mode (daemon-connected), the Tools section is hidden since
/// settings are managed by the daemon process.
struct SidebarView: View {
    @Environment(CIMSAppState.self) private var appState

    /// The currently selected sidebar item.
    @Binding var selection: SidebarSelection?

    /// Whether the app is running in IPC (daemon) mode.
    private var isIPCMode: Bool {
        appState.ipcClient != nil
    }

    var body: some View {
        List(selection: $selection) {
            Section("Sessions") {
                // Default session for now — real session management is future work
                Label("Default Session", systemImage: "bubble.left.and.bubble.right")
                    .tag(SidebarSelection.session("default"))
            }

            if isIPCMode {
                Section("Tools") {
                    Label("Settings are managed by the daemon", systemImage: "gearshape")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } else {
                Section("Tools") {
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarSelection.settings)
                    Label("Identity", systemImage: "person.text.rectangle")
                        .tag(SidebarSelection.identity)
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                        .tag(SidebarSelection.plugins)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("CIMS")
    }
}
