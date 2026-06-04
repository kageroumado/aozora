import SwiftUI
import WebKit

/// Sheet presenting a WKWebView for the Anthropic OAuth sign-in flow.
///
/// Loads the OAuth authorization URL (claude.ai/oauth/authorize) and intercepts
/// the redirect callback to complete the PKCE token exchange.
struct ClaudeOAuthSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The OAuth manager driving the authentication flow.
    let oauthManager: ClaudeOAuthManager

    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in with Claude")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if let error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        self.error = nil
                        isLoading = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ZStack {
                    OAuthWebView(
                        oauthManager: oauthManager,
                        isLoading: $isLoading,
                        error: $error,
                        onComplete: {
                            dismiss()
                        },
                    )

                    if isLoading {
                        ProgressView()
                    }
                }
            }
        }
        .frame(width: 500, height: 650)
    }
}

/// NSViewRepresentable wrapping a WKWebView for the OAuth authorization flow.
///
/// Loads the authorization URL and intercepts the redirect callback via
/// the navigation delegate to complete the token exchange.
private struct OAuthWebView: NSViewRepresentable {
    /// The OAuth manager that built the authorization URL and handles callbacks.
    let oauthManager: ClaudeOAuthManager

    /// Whether the web view is still loading its initial content.
    @Binding var isLoading: Bool

    /// Error message to display if navigation fails.
    @Binding var error: String?

    /// Called when authentication completes successfully.
    let onComplete: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        let url = oauthManager.buildAuthorizeURL()
        webView.load(URLRequest(url: url))

        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Navigation delegate that intercepts the OAuth redirect callback.
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The parent representable providing the OAuth manager and bindings.
        let parent: OAuthWebView

        init(parent: OAuthWebView) {
            self.parent = parent
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
            parent.isLoading = false
            parent.error = error.localizedDescription
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .allow
            }

            if url.absoluteString.hasPrefix(ClaudeOAuthManager.redirectURI) {
                let handled = await parent.oauthManager.handleCallback(url: url)
                if handled {
                    if let authError = parent.oauthManager.authError {
                        parent.error = authError
                    } else {
                        parent.onComplete()
                    }
                }
                return .cancel
            }

            return .allow
        }
    }
}
