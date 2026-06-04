import ArgumentParser
import Foundation

// MARK: - ArgumentParser Conformances for AozoraCore Types

extension CredentialStore.Service: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

extension CredentialStore.CredentialType: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

// MARK: - Credential Subcommand

/// Manage API credentials stored in the macOS Keychain.
///
/// Supports multiple named credentials per service with priority-based resolution.
/// Environment variables override keychain credentials when set.
///
/// ```
/// aozora credential                                     # Show active credentials
/// aozora credential list                                # List all credentials
/// aozora credential add anthropic claude-max            # Add (reads secret from stdin)
/// aozora credential remove anthropic claude-max         # Remove
/// aozora credential set-priority anthropic claude-max 1 # Set priority
/// ```
struct CredentialSubcommand: AsyncParsableCommand {
    nonisolated static let configuration = CommandConfiguration(
        commandName: "credential",
        abstract: "Manage API credentials (Keychain + environment).",
        subcommands: [
            ListCredentials.self,
            AddCredential.self,
            RemoveCredential.self,
            SetPriority.self,
            ShowActive.self,
        ],
        defaultSubcommand: ShowActive.self,
    )
}

// MARK: - Show Active

extension CredentialSubcommand {
    /// Show which credential would be used for each service.
    struct ShowActive: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "active",
            abstract: "Show the active credential for each service.",
        )

        @Argument(help: "Service to check (anthropic, discord). Omit for all.")
        var service: CredentialStore.Service?

        func run() async throws {
            let services = service.map { [$0] } ?? CredentialStore.Service.allCases

            for svc in services {
                if let cred = CredentialStore.resolve(service: svc) {
                    let source = cred.isEnvironment ? "env:\(svc.envVar)" : "keychain:\(cred.name)"
                    let masked = maskSecret(cred.secret)
                    print("\(svc.rawValue): \(source) (\(cred.type.rawValue)) \(masked)")
                } else {
                    print("\(svc.rawValue): (none)")
                }
            }
        }
    }
}

// MARK: - List

extension CredentialSubcommand {
    /// List all stored credentials with their metadata.
    struct ListCredentials: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all stored credentials.",
        )

        @Option(name: .shortAndLong, help: "Filter by service (anthropic, discord).")
        var service: CredentialStore.Service?

        func run() async throws {
            let services = service.map { [$0] } ?? CredentialStore.Service.allCases
            var anyFound = false

            for svc in services {
                // Show environment variable if set
                if let envValue = ProcessInfo.processInfo.environment[svc.envVar], !envValue.isEmpty {
                    let type = detectType(envValue, service: svc)
                    print("  \(svc.rawValue)/\(formatEnvTag()) \(type.rawValue) priority:0 \(maskSecret(envValue))")
                    anyFound = true
                }

                // Show keychain credentials
                let creds = try CredentialStore.list(service: svc)
                for cred in creds {
                    let labelSuffix = cred.label.map { " — \($0)" } ?? ""
                    let dateStr = formatDate(cred.addedAt)
                    print("  \(svc.rawValue)/\(cred.name) \(cred.type.rawValue) priority:\(cred.priority) \(maskSecret(cred.secret)) added:\(dateStr)\(labelSuffix)")
                    anyFound = true
                }
            }

            if !anyFound {
                print("No credentials stored. Add one with: aozora credential add <service> <name>")
            }
        }

        private func formatEnvTag() -> String {
            "$env"
        }

        private func detectType(_ secret: String, service: CredentialStore.Service) -> CredentialStore.CredentialType {
            switch service {
            case .anthropic:
                if secret.hasPrefix("sk-ant-oat") { return .oauth }
                return .apiKey
            case .discord:
                return .botToken
            }
        }

        private func formatDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Add

extension CredentialSubcommand {
    /// Add or update a credential in the Keychain.
    ///
    /// Reads the secret value from stdin (pipe-friendly) or prompts interactively
    /// with hidden input. Use `--value` for scripting when stdin isn't available.
    struct AddCredential: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add or update a credential.",
        )

        @Argument(help: "Service (anthropic, discord).")
        var service: CredentialStore.Service

        @Argument(help: "Credential name (e.g., claude-max, backup-key).")
        var name: String

        @Option(name: .shortAndLong, help: "Priority (lower = higher priority). Default: 100.")
        var priority: Int = 100

        @Option(name: .shortAndLong, help: "Credential type (api-key, oauth, bot-token). Auto-detected if omitted.")
        var type: CredentialStore.CredentialType?

        @Option(name: .shortAndLong, help: "Human-readable label.")
        var label: String?

        @Option(help: "Secret value (visible in process list — prefer stdin).")
        var value: String?

        func run() async throws {
            let secret: String

            if let provided = value {
                secret = provided
            } else if isatty(STDIN_FILENO) == 0 {
                // Reading from pipe/redirection
                guard let line = readLine(strippingNewline: true), !line.isEmpty else {
                    print("Error: No secret provided. Pipe a value or use --value.")
                    throw ExitCode.failure
                }
                secret = line
            } else {
                // Interactive: hidden input via getpass
                guard let pass = getpass("Enter secret for \(service.rawValue)/\(name): "),
                      let passStr = String(validatingCString: pass), !passStr.isEmpty else {
                    print("Error: No secret entered.")
                    throw ExitCode.failure
                }
                secret = passStr
            }

            let resolvedType = type ?? autoDetectType(secret: secret, service: service)

            try CredentialStore.add(
                service: service,
                name: name,
                secret: secret,
                type: resolvedType,
                priority: priority,
                label: label,
            )

            let masked = maskSecret(secret)
            print("Stored \(service.rawValue)/\(name) (\(resolvedType.rawValue), priority \(priority)): \(masked)")
        }

        private func autoDetectType(
            secret: String,
            service: CredentialStore.Service,
        ) -> CredentialStore.CredentialType {
            switch service {
            case .anthropic:
                if secret.hasPrefix("sk-ant-oat") { return .oauth }
                return .apiKey
            case .discord:
                return .botToken
            }
        }
    }
}

// MARK: - Remove

extension CredentialSubcommand {
    /// Remove a credential from the Keychain.
    struct RemoveCredential: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a credential from the Keychain.",
        )

        @Argument(help: "Service (anthropic, discord).")
        var service: CredentialStore.Service

        @Argument(help: "Credential name to remove.")
        var name: String

        func run() async throws {
            guard let existing = try CredentialStore.get(service: service, name: name) else {
                print("No credential found: \(service.rawValue)/\(name)")
                throw ExitCode.failure
            }

            try CredentialStore.remove(service: service, name: name)
            print("Removed \(service.rawValue)/\(existing.name)")
        }
    }
}

// MARK: - Set Priority

extension CredentialSubcommand {
    /// Update the priority of an existing credential.
    struct SetPriority: AsyncParsableCommand {
        nonisolated static let configuration = CommandConfiguration(
            commandName: "set-priority",
            abstract: "Update a credential's resolution priority.",
        )

        @Argument(help: "Service (anthropic, discord).")
        var service: CredentialStore.Service

        @Argument(help: "Credential name.")
        var name: String

        @Argument(help: "New priority (lower = higher priority).")
        var priority: Int

        func run() async throws {
            try CredentialStore.setPriority(service: service, name: name, priority: priority)
            print("Updated \(service.rawValue)/\(name) → priority \(priority)")
        }
    }
}

// MARK: - Helpers

/// Mask a secret for display, showing only prefix and suffix.
private func maskSecret(_ secret: String) -> String {
    guard secret.count > 12 else { return "****" }
    let prefix = secret.prefix(8)
    let suffix = secret.suffix(4)
    return "\(prefix)...\(suffix)"
}
