import Foundation

// MARK: - Discord Interaction Handler

/// Bridges Discord slash command interactions to the CIMS ``CommandRouter``.
///
/// When Discord sends an interaction event (type 2 = APPLICATION_COMMAND),
/// this handler extracts the command path and options, translates them into
/// a command string, and routes through the ``CommandRouter``.
///
/// The handler is called by the Discord messaging channel plugin when it
/// receives an interaction webhook or gateway event.
public actor DiscordInteractionHandler {
    private let router: CommandRouter
    private let botToken: String
    private let apiBase = "https://discord.com/api/v10"

    public init(router: CommandRouter, botToken: String) {
        self.router = router
        self.botToken = botToken
    }

    /// Handle a raw Discord interaction payload.
    ///
    /// Parses the interaction, routes to the command router, and sends the
    /// response back via the Discord interaction response endpoint.
    ///
    /// - Parameter payload: The raw interaction JSON from Discord's gateway.
    public func handle(_ payload: [String: Any]) async {
        guard let interactionType = payload["type"] as? Int,
              interactionType == 2, // APPLICATION_COMMAND
              let data = payload["data"] as? [String: Any],
              let interactionId = payload["id"] as? String,
              let interactionToken = payload["token"] as? String
        else {
            return
        }

        let commandString = extractCommandString(from: data)
        let result = await router.execute(commandString)

        await respondToInteraction(
            id: interactionId,
            token: interactionToken,
            content: result.displayText,
            ephemeral: false,
        )
    }

    /// Extract a flat command string from Discord's nested interaction data.
    ///
    /// Discord represents `/aozora config set key value` as:
    /// ```json
    /// {
    ///   "name": "aozora",
    ///   "options": [{
    ///     "name": "config",
    ///     "type": 2,
    ///     "options": [{
    ///       "name": "set",
    ///       "type": 1,
    ///       "options": [
    ///         {"name": "key", "value": "context.budget"},
    ///         {"name": "value", "value": "800000"}
    ///       ]
    ///     }]
    ///   }]
    /// }
    /// ```
    ///
    /// This flattens it to: `"config set context.budget 800000"`
    private func extractCommandString(from data: [String: Any]) -> String {
        var parts: [String] = []

        // Include the root command name (e.g., "status", "config", "memory")
        if let name = data["name"] as? String {
            parts.append(name)
        }

        var options = data["options"] as? [[String: Any]] ?? []

        // Walk down the subcommand group / subcommand chain
        while let opt = options.first {
            let optType = opt["type"] as? Int ?? 0

            if optType == 2 {
                // SUB_COMMAND_GROUP — descend
                parts.append(opt["name"] as? String ?? "")
                options = opt["options"] as? [[String: Any]] ?? []
            } else if optType == 1 {
                // SUB_COMMAND — this is the leaf command
                parts.append(opt["name"] as? String ?? "")
                // Collect arguments from this subcommand's options
                let args = opt["options"] as? [[String: Any]] ?? []
                for arg in args {
                    if let value = arg["value"] {
                        parts.append("\(value)")
                    }
                }
                break
            } else {
                // Direct option (no subcommand) — just collect values
                for o in options {
                    if let value = o["value"] {
                        parts.append("\(value)")
                    }
                }
                break
            }
        }

        return parts.joined(separator: " ")
    }

    /// Send an interaction response to Discord.
    ///
    /// Uses the interaction callback endpoint for initial responses (within 3s)
    /// or the followup endpoint for deferred responses.
    private func respondToInteraction(
        id: String,
        token: String,
        content: String,
        ephemeral: Bool,
    ) async {
        let url = URL(string: "\(apiBase)/interactions/\(id)/\(token)/callback")!

        // Truncate to Discord's 2000-char limit
        let truncated: String = if content.count > 1_990 {
            String(content.prefix(1_987)) + "..."
        } else {
            content
        }

        let responseBody: [String: Any] = [
            "type": 4, // CHANNEL_MESSAGE_WITH_SOURCE
            "data": [
                "content": truncated,
                "flags": ephemeral ? 64 : 0,
            ],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: responseBody) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("DiscordBot (Aozora, 1.0)", forHTTPHeaderField: "User-Agent")

        _ = try? await URLSession.shared.data(for: request)
    }

    /// Send a deferred response (acknowledge → edit later).
    ///
    /// Use this for commands that might take longer than 3 seconds.
    ///
    /// - Parameter applicationId: The Discord application ID from the
    ///   interaction payload's `application_id` field, used to construct
    ///   the followup webhook URL.
    public func deferAndProcess(
        interactionId: String,
        interactionToken: String,
        applicationId: String,
        data: [String: Any],
    ) async {
        // 1. Send deferred response (type 5 = DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE)
        let deferUrl = URL(string: "\(apiBase)/interactions/\(interactionId)/\(interactionToken)/callback")!
        let deferBody: [String: Any] = ["type": 5]
        if let bodyData = try? JSONSerialization.data(withJSONObject: deferBody) {
            var request = URLRequest(url: deferUrl)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
            request.setValue("DiscordBot (Aozora, 1.0)", forHTTPHeaderField: "User-Agent")
            _ = try? await URLSession.shared.data(for: request)
        }

        // 2. Execute the command
        let commandString = extractCommandString(from: data)
        let result = await router.execute(commandString)

        // 3. Edit the original response with the result
        let editUrl = URL(
            string: "\(apiBase)/webhooks/\(applicationId)/\(interactionToken)/messages/@original",
        )!
        let content = result.displayText.count > 1_990
            ? String(result.displayText.prefix(1_987)) + "..."
            : result.displayText

        let editBody: [String: Any] = ["content": content]
        if let bodyData = try? JSONSerialization.data(withJSONObject: editBody) {
            var request = URLRequest(url: editUrl)
            request.httpMethod = "PATCH"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
            request.setValue("DiscordBot (Aozora, 1.0)", forHTTPHeaderField: "User-Agent")
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
