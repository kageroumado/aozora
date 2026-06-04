import AozoraCore
import SwiftUI

/// Authentication gate shown before the CIMS gateway is initialized.
///
/// Presents a sign-in button that opens the OAuth sheet. On successful
/// authentication, triggers gateway initialization via ``CIMSAppState``.
struct AuthGateView: View {
    @Environment(CIMSAppState.self) var appState
    @State private var showingOAuth = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("CIMS v4")
                .font(.largeTitle.bold())
            Text("Constructed Identity Memory System")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Sign in with Claude") {
                showingOAuth = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingOAuth) {
            ClaudeOAuthSheet(oauthManager: appState.oauthManager)
        }
        .task(id: showingOAuth) {
            if !showingOAuth, ClaudeCredentialStore.hasCredential {
                await appState.initialize()
            }
        }
    }
}
