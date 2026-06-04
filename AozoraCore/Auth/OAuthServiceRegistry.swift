import Foundation

/// Registry of known OAuth services with their configurations.
///
/// Add new services here as they're needed. The agent can also
/// register services dynamically at runtime.
public enum OAuthServiceRegistry {
    /// Known service configurations.
    public static let services: [String: OAuthClient.ServiceConfig] = [
        // alphaxiv uses Clerk — dynamically registered via RFC 7591
        // Client registered with redirect_uri http://127.0.0.1:19876/oauth/callback
        "alphaxiv": .init(
            name: "alphaxiv",
            authorizeURL: "https://clerk.alphaxiv.org/oauth/authorize",
            tokenURL: "https://clerk.alphaxiv.org/oauth/token",
            clientID: "NCa9flgXa0REBImC",
            scopes: "profile email offline_access",
        ),
    ]

    /// Load a custom service config from ~/.aozora/oauth/services/<name>.json
    public static func loadCustom(_ name: String) -> OAuthClient.ServiceConfig? {
        let path = NSHomeDirectory() + "/.aozora/oauth/services/\(name).json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(OAuthClient.ServiceConfig.self, from: data)
    }

    /// Save a custom service config.
    public static func saveCustom(_ config: OAuthClient.ServiceConfig) throws {
        let dir = NSHomeDirectory() + "/.aozora/oauth/services"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/\(config.name).json"
        let data = try JSONEncoder().encode(config)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Get a service config by name (checks custom configs first, then built-in).
    public static func config(for name: String) -> OAuthClient.ServiceConfig? {
        loadCustom(name) ?? services[name]
    }

    /// List all available services (built-in + custom).
    public static func allServices() -> [String] {
        var names = Set(services.keys)
        let customDir = NSHomeDirectory() + "/.aozora/oauth/services"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: customDir) {
            for file in contents where file.hasSuffix(".json") {
                names.insert(String(file.dropLast(5)))
            }
        }
        return names.sorted()
    }
}
