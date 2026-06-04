import AozoraCore
import SwiftUI

/// Root lifecycle manager for the CIMS cognitive architecture.
///
/// Owns the ``CIMSGateway`` and all feature managers. Manages the
/// `notAuthenticated → loading → ready` lifecycle. Injected into the
/// SwiftUI environment as the single source of truth.
@Observable
final class CIMSAppState {
    /// Application lifecycle phase.
    nonisolated enum AppPhase {
        /// No credential found — show auth gate.
        case notAuthenticated
        /// Gateway is initializing.
        case loading
        /// Gateway and all managers are ready.
        case ready
        /// Initialization failed with a displayable message.
        case error(String)
    }

    /// Current application phase.
    var phase: AppPhase = .notAuthenticated

    /// The CIMS gateway (available when phase is `.ready`, in-process mode only).
    private(set) var gateway: CIMSGateway?

    /// IPC client for daemon communication (available when phase is `.ready`, IPC mode only).
    private(set) var ipcClient: IPCClient?

    /// Feature managers (available when phase is `.ready`).
    private(set) var chatManager: ChatManager?

    /// Inspector telemetry manager (available when phase is `.ready`).
    private(set) var inspectorManager: InspectorManager?

    /// Runtime configuration manager.
    private(set) var settingsManager: SettingsManager?

    /// Plugin lifecycle manager (available when phase is `.ready`).
    private(set) var pluginManager: PluginManager?

    /// Identity claim browser manager (available when phase is `.ready`).
    private(set) var identityManager: IdentityManager?

    /// OAuth flow manager for sign-in.
    let oauthManager = ClaudeOAuthManager()

    /// Initialize the app — try daemon IPC first, then fall back to in-process mode.
    ///
    /// Connection priority:
    /// 1. Local Unix domain socket (same machine, lowest latency)
    /// 2. Remote WebSocket via configured host (e.g., Tailscale)
    /// 3. In-process gateway (requires credential)
    ///
    /// Called once on app launch via `.task` modifier.
    func initialize() async {
        // 1. Try local Unix socket first — no credential needed
        if IPCClient.daemonAvailable() {
            let client = IPCClient()
            if client.connect() {
                setupIPCMode(client: client, via: "local Unix socket")
                return
            }
        }

        // 2. Try remote WebSocket if a daemon host is configured
        if let remoteHost = UserDefaults.standard.string(forKey: "daemonHost"),
           !remoteHost.isEmpty {
            let port = UInt16(UserDefaults.standard.integer(forKey: "daemonPort"))
            let client = IPCClient()
            if client.connect(mode: .webSocket(host: remoteHost, port: port > 0 ? port : IPCClient.defaultWSPort)) {
                setupIPCMode(client: client, via: "WebSocket \(remoteHost):\(port > 0 ? port : IPCClient.defaultWSPort)")
                return
            }
        }

        // 3. Fall back to in-process mode — need a credential
        guard let credential = ClaudeCredentialStore.activeCredential() else {
            phase = .notAuthenticated
            return
        }

        // If OAuth token is expired, try refreshing
        if case let .oauthToken(_, refresh, expiresAt) = credential,
           Date.now >= expiresAt {
            if let refreshed = await ClaudeOAuthManager.refreshToken(refreshToken: refresh) {
                let newCredential = ClaudeCredential.oauthToken(
                    refreshed.accessToken,
                    refresh: refreshed.refreshToken,
                    expiresAt: refreshed.expiresAt,
                )
                await initializeGateway(with: newCredential)
            } else {
                ClaudeCredentialStore.deleteAll()
                phase = .notAuthenticated
            }
            return
        }

        await initializeGateway(with: credential)
    }

    /// Wire up IPC mode with a connected client.
    private func setupIPCMode(client: IPCClient, via transport: String) {
        ipcClient = client
        let chat = ChatManager(ipcClient: client)
        let inspector = InspectorManager(ipcClient: client)
        chat.onInspectorData = { [weak inspector] data in
            inspector?.updateFromIPC(data)
        }
        chatManager = chat
        inspectorManager = inspector
        phase = .ready
        print("[CIMSAppState] Connected to daemon via \(transport)")
    }

    /// Create the CIMS gateway and all feature managers.
    ///
    /// Tries connecting to a running daemon via IPC first. If the daemon socket exists
    /// and the connection succeeds, uses IPC mode where the app receives live state
    /// from the daemon. Falls back to creating an in-process ``CIMSGateway`` if no
    /// daemon is available.
    ///
    /// - Parameter credential: The authenticated credential to use.
    func initializeGateway(with credential: ClaudeCredential) async {
        phase = .loading

        do {
            let dbPath = Self.databasePath()
            let provider = AnthropicProvider(credential: credential)
            let gw = try await CIMSGateway(databasePath: dbPath, modelProvider: provider)

            gateway = gw
            chatManager = ChatManager(gateway: gw)
            inspectorManager = InspectorManager(gateway: gw)
            settingsManager = SettingsManager()
            pluginManager = PluginManager(registry: gw.pluginRegistry)
            identityManager = IdentityManager(gateway: gw)

            phase = .ready
        } catch {
            phase = .error("Failed to initialize CIMS: \(error.localizedDescription)")
        }
    }

    /// Clean shutdown: disconnect IPC and stop polling.
    ///
    /// Called when the app terminates or the scene phase transitions to background.
    /// Does not clear credentials or reset phase — use ``signOut()`` for that.
    func shutdown() {
        ipcClient?.disconnect()
    }

    /// Sign out: tear down gateway/IPC, clear keychain, reset to auth gate.
    func signOut() {
        ipcClient?.disconnect()
        ipcClient = nil
        gateway = nil
        chatManager = nil
        inspectorManager = nil
        settingsManager = nil
        pluginManager = nil
        identityManager = nil
        ClaudeCredentialStore.deleteAll()
        phase = .notAuthenticated
    }

    /// Database file path in Application Support.
    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
        ).first!.appendingPathComponent("Aozora")

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("cims.sqlite").path
    }
}
