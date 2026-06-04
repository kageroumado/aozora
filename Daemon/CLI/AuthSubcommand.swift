import ArgumentParser
import Foundation

/// Manage OAuth authentication for external services.
///
/// Supports login (browser-based OAuth flow), logout, and status checking.
/// Tokens are stored in `~/.aozora/oauth/<service>.json`.
struct AuthSubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage OAuth authentication for external services.",
        subcommands: [Login.self, Logout.self, Status.self, Register.self],
        defaultSubcommand: Status.self,
    )

    /// Login to a service via OAuth (opens browser).
    struct Login: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            abstract: "Login to a service via OAuth.",
        )

        @Argument(help: "Service name (e.g., alphaxiv).")
        var service: String

        func run() async throws {
            guard let config = OAuthServiceRegistry.config(for: service) else {
                let available = OAuthServiceRegistry.allServices()
                print("Unknown service: \(service)")
                if !available.isEmpty {
                    print("Available: \(available.joined(separator: ", "))")
                }
                print("Register a custom service with: aozora auth register")
                throw ExitCode.failure
            }

            guard !config.clientID.isEmpty else {
                print("Service '\(service)' has no client ID configured.")
                print("Register the OAuth app with the provider, then update the config:")
                print("  ~/.aozora/oauth/services/\(service).json")
                throw ExitCode.failure
            }

            let client = OAuthClient(config: config)
            let (verifier, challenge) = OAuthClient.generatePKCE()

            var stateBytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
            let state = Data(stateBytes).base64URLEncoded()

            let authURL = try client.buildAuthorizeURL(state: state, challenge: challenge)

            print("Opening browser for \(service) login...")
            print("URL: \(authURL.absoluteString)")
            print()
            print("Waiting for authorization (5 minute timeout)...")

            // Open in default browser
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = [authURL.absoluteString]
            try openProcess.run()

            // Start callback server
            let server = OAuthCallbackServer(port: config.callbackPort)
            let result = try await server.waitForCallback(expectedState: state)

            switch result {
            case let .success(code):
                print("Authorization code received. Exchanging for tokens...")
                let tokenResponse = try await client.exchangeCode(code, verifier: verifier)

                let store = OAuthTokenStore(service: service)
                try store.save(from: tokenResponse)

                print("Authenticated with \(service).")
                print("Token expires in \(tokenResponse.expires_in ?? 86_400)s.")
                if tokenResponse.refresh_token != nil {
                    print("Refresh token stored — will auto-refresh on expiry.")
                }

            case let .error(description):
                print("Authentication failed: \(description)")
                throw ExitCode.failure
            }
        }
    }

    /// Logout from a service (delete stored tokens).
    struct Logout: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            abstract: "Logout from a service (delete tokens).",
        )

        @Argument(help: "Service name.")
        var service: String

        func run() async throws {
            let store = OAuthTokenStore(service: service)
            if store.hasCredential {
                store.delete()
                print("Logged out of \(service).")
            } else {
                print("Not authenticated with \(service).")
            }
        }
    }

    /// Show authentication status for all services.
    struct Status: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            abstract: "Show authentication status.",
        )

        @Argument(help: "Optional service name to check.")
        var service: String?

        func run() async throws {
            if let service {
                let store = OAuthTokenStore(service: service)
                print("\(service): \(store.status)")
            } else {
                let services = OAuthServiceRegistry.allServices()
                if services.isEmpty {
                    print("No services configured.")
                    return
                }
                print("OAuth Status:")
                for name in services {
                    let store = OAuthTokenStore(service: name)
                    let status = store.hasCredential ? store.status : "not authenticated"
                    print("  \(name): \(status)")
                }
            }
        }
    }

    /// Register a custom OAuth service.
    struct Register: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            abstract: "Register a custom OAuth service.",
        )

        @Argument(help: "Service name.")
        var name: String

        @Option(help: "Authorization endpoint URL.")
        var authorizeURL: String

        @Option(help: "Token endpoint URL.")
        var tokenURL: String

        @Option(help: "OAuth client ID.")
        var clientID: String

        @Option(help: "OAuth client secret (optional).")
        var clientSecret: String?

        @Option(help: "Requested scopes (space-separated).")
        var scopes: String = "profile email"

        @Option(help: "Local callback port.")
        var port: Int = 19_876

        func run() async throws {
            let config = OAuthClient.ServiceConfig(
                name: name,
                authorizeURL: authorizeURL,
                tokenURL: tokenURL,
                clientID: clientID,
                clientSecret: clientSecret,
                scopes: scopes,
                callbackPort: port,
            )
            try OAuthServiceRegistry.saveCustom(config)
            print("Registered service '\(name)'.")
            print("Login with: aozora auth login \(name)")
        }
    }
}
