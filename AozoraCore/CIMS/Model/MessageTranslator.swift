import Foundation

/// Translates between Anthropic and OpenAI message formats.
///
/// Stateless, `Sendable` struct. Converts ``Prompt`` values (Anthropic's system/messages/tools
/// structure) into OpenAI-compatible `/v1/chat/completions` request bodies, and parses
/// OpenAI streaming responses back into ``ModelDelta`` values.
///
/// The translation handles all content block types: text, tool_use → function_call,
/// tool_result → tool message, images → image_url, and system blocks → system messages.
public struct MessageTranslator: Sendable {
    /// Convert an Anthropic ``Prompt`` to an OpenAI-compatible messages array.
    ///
    /// System blocks become a single system message. Conversation messages are translated
    /// from Anthropic's multipart content block format to OpenAI's message format.
    ///
    /// - Parameter prompt: The Anthropic-format prompt to translate.
    /// - Returns: An array of dictionaries suitable for the OpenAI `messages` field.
    public func translateMessages(from prompt: Prompt) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        let systemText = prompt.system.map(\.text).joined(separator: "\n\n")
        if !systemText.isEmpty {
            messages.append([
                "role": "system",
                "content": systemText,
            ])
        }

        for message in prompt.messages {
            messages.append(contentsOf: translateMessage(message))
        }

        return messages
    }

    /// Convert Anthropic tool schemas to OpenAI function definitions.
    ///
    /// Translates from Anthropic's `input_schema` format to OpenAI's `function.parameters`
    /// format wrapped in `type: "function"` tool objects.
    ///
    /// - Parameter tools: The Anthropic-format tool schemas to translate.
    /// - Returns: An array of dictionaries suitable for the OpenAI `tools` field.
    public func translateTools(from tools: [ToolSchema]) -> [[String: Any]] {
        tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": jsonValueToAny(tool.inputSchema),
                ] as [String: Any],
            ]
        }
    }

    // MARK: - Message Translation

    /// Translate a single Anthropic ``APIMessage`` to one or more OpenAI messages.
    ///
    /// A single Anthropic message with mixed content (text + tool_use, or tool_results)
    /// may expand to multiple OpenAI messages because OpenAI uses separate message objects
    /// for tool calls and tool results.
    private func translateMessage(_ message: APIMessage) -> [[String: Any]] {
        let role = message.role == .assistant ? "assistant" : "user"

        switch message.content {
        case let .text(string):
            return [[
                "role": role,
                "content": string,
            ]]

        case let .blocks(blocks):
            return translateBlocks(blocks, role: role)
        }
    }

    /// Translate an array of Anthropic content blocks into OpenAI messages.
    ///
    /// Groups blocks by type: text blocks become content, tool_use blocks become
    /// `tool_calls` on an assistant message, and tool_result blocks become
    /// individual `tool` role messages.
    private func translateBlocks(_ blocks: [ContentBlock], role: String) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []
        var toolResults: [[String: Any]] = []

        for block in blocks {
            switch block {
            case let .text(string):
                textParts.append(string)

            case let .cacheableText(cached):
                textParts.append(cached.text)

            case let .toolUse(toolUse):
                toolCalls.append([
                    "id": toolUse.id,
                    "type": "function",
                    "function": [
                        "name": toolUse.name,
                        "arguments": jsonValueToString(toolUse.input),
                    ] as [String: Any],
                ])

            case let .toolResult(result):
                toolResults.append([
                    "role": "tool",
                    "tool_call_id": result.toolUseId,
                    "content": result.content,
                ])

            case let .image(image):
                textParts.append("[image: \(image.mediaType)]")
            }
        }

        if role == "assistant" {
            var msg: [String: Any] = ["role": "assistant"]
            let combinedText = textParts.joined(separator: "\n")
            if !combinedText.isEmpty {
                msg["content"] = combinedText
            }
            if !toolCalls.isEmpty {
                msg["tool_calls"] = toolCalls
            }
            if !combinedText.isEmpty || !toolCalls.isEmpty {
                messages.append(msg)
            }
        } else {
            if !textParts.isEmpty {
                messages.append([
                    "role": "user",
                    "content": textParts.joined(separator: "\n"),
                ])
            }
        }

        messages.append(contentsOf: toolResults)

        return messages
    }

    // MARK: - JSONValue Conversion

    /// Convert a ``JSONValue`` to a Foundation `Any` for JSON serialization.
    func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case let .bool(b):
            return b
        case let .int(i):
            return i
        case let .double(d):
            return d
        case let .string(s):
            return s
        case let .array(arr):
            return arr.map { jsonValueToAny($0) }
        case let .object(pairs):
            var dict: [String: Any] = [:]
            for (key, val) in pairs {
                dict[key] = jsonValueToAny(val)
            }
            return dict
        }
    }

    /// Convert a ``JSONValue`` to a JSON string.
    func jsonValueToString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
