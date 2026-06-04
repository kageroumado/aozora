import Foundation

/// Single entry point for all API prompt construction.
///
/// Replaces `AnthropicProvider.buildRequest()`, `CIMSCoordinator.buildInitialMessages()`,
/// and `CIMSCoordinator.buildSystemPromptText()`. Produces a fully typed ``Prompt`` value
/// from an ``AssembledContext``, a credential discriminant, and tool definitions.
///
/// **Prompt layout (three-tier caching):**
///
/// The Anthropic API hashes the entire `system` array as one unit for cache key
/// computation. Any change in any system block — even blocks without `cache_control`
/// — invalidates all cache breakpoints. Content is therefore split into three tiers
/// by volatility, each with different caching behavior:
///
/// ```
/// SYSTEM BLOCKS (all stable — cached as a unit, ~95K tokens)
///   ├─ [0] OAuth identity prefix ("You are Claude Code...")
///   ├─ [1] INTRO.md preamble (grounding context)
///   ├─ [2] Stable summaries (condensed DAG nodes, frozen history)
///   ├─ [3] Recent summaries (leaf/leaf_summary nodes)
///   └─ [4] System prompt (SOUL.md, IDENTITY.md, USER.md, WRITING.md)
///          ← cache_control: ephemeral (last block)
///
/// MESSAGES
///   ├─ [first]     Slow-changing state: identity claims, mirror, cognitive state
///   │              (changes hours/days — cached by stubbing boundary breakpoint)
///   ├─ ...         Conversation history (aged, tool results stubbed)
///   ├─ [boundary]  ← cache_control: ephemeral (message-level breakpoint)
///   ├─ ...         Recent messages (last ~32 turns, verbatim tool results)
///   └─ [last]      Per-turn state + current user message:
///                  chronoception, temporal grounding (timestamps),
///                  then the actual user text (never cached)
///
/// TOOLS
///   └─ 24+ tool definitions (bash, read, write, edit, etc.)
/// ```
///
/// **Why this structure:**
/// - System blocks never change between turns → system cache hits every turn
/// - Slow-changing state before the stubbing boundary → message cache hits when
///   identity claims are stable (most turns)
/// - Per-turn timestamps in the last message → only a few hundred tokens reprocessed
/// Result of prompt construction, pairing the prompt with cache metadata.
public struct PromptBuildResult: Sendable {
    /// The fully constructed prompt ready for serialization.
    public let prompt: Prompt
    /// Index into `prompt.messages` where the message-level cache breakpoint was placed.
    /// `nil` if no boundary was placed (too few messages).
    public let boundaryMessageIndex: Int?
}

public struct PromptBuilder: Sendable {
    /// The OAuth identity prefix required by Claude Code subscription tokens.
    private static let oauthIdentityPrefix = "You are Claude Code, Anthropic's official CLI for Claude."

    /// Marker for the INTRO.md preamble section.
    private static let introMarker = "# Context Introduction"

    /// Marker for the SOUL.md boundary in the system prompt.
    private static let soulMarker = "# SOUL.md"

    public init() {}

    /// Build a prompt for an inference call.
    ///
    /// Constructs system blocks with cache_control breakpoints, reconstructs the conversation
    /// message array from stored messages with tool_use/tool_result blocks and image attachments,
    /// and converts tool definitions to API schema.
    ///
    /// - Parameters:
    ///   - context: The assembled context containing sections, messages, and current input.
    ///   - credential: Whether the credential is OAuth (requires identity prefix) or API key.
    ///   - tools: Tool definitions to include in the prompt.
    /// - Returns: A ``PromptBuildResult`` containing the prompt and cache boundary metadata.
    public func build(
        context: AssembledContext,
        credential: CredentialKind,
        tools: [ToolDefinition],
    ) -> PromptBuildResult {
        let systemBlocks = buildSystemBlocks(context: context, credential: credential)
        let (messages, boundaryIndex) = buildMessages(context: context)
        let toolSchemas = tools.map { ToolSchema(from: $0) }
        let prompt = Prompt(system: systemBlocks, messages: messages, tools: toolSchemas)
        return PromptBuildResult(prompt: prompt, boundaryMessageIndex: boundaryIndex)
    }

    /// Build a tool loop follow-up prompt.
    ///
    /// Reuses the base prompt's system blocks and message prefix identically,
    /// appending the new tool exchanges as assistant + user message pairs.
    /// This guarantees byte-for-byte identical prefixes for KV cache reuse.
    ///
    /// - Parameters:
    ///   - basePrompt: The initial prompt whose system and messages serve as the prefix.
    ///   - exchanges: Tool exchanges to append — each expands to an assistant + user pair.
    ///   - tools: Tool definitions for this follow-up turn (may differ from the initial set).
    /// - Returns: A new ``Prompt`` with the same prefix and the exchanges appended.
    public func buildFollowUp(
        basePrompt: Prompt,
        exchanges: [ToolExchange],
        tools: [ToolDefinition],
    ) -> Prompt {
        var messages = basePrompt.messages
        for exchange in exchanges {
            messages.append(contentsOf: exchange.toMessages())
        }
        return Prompt(
            system: basePrompt.system,
            messages: messages,
            tools: tools.map { ToolSchema(from: $0) },
        )
    }

    /// Live temporal state for heartbeat prompts.
    ///
    /// The frozen prompt prefix captures identity and conversation. This struct carries
    /// the parts that SHOULD change between heartbeats — the system's sense of time passing.
    public struct HeartbeatTemporalState: Sendable {
        /// How many heartbeats since the last real turn (1-based).
        public let heartbeatCount: Int
        /// Current time.
        public let now: Date
        /// Time since the last real user message.
        public let idleDuration: Duration?
        /// Time since the last real turn completed.
        public let sinceLastTurn: Duration?

        public init(heartbeatCount: Int, now: Date, idleDuration: Duration?, sinceLastTurn: Duration?) {
            self.heartbeatCount = heartbeatCount
            self.now = now
            self.idleDuration = idleDuration
            self.sinceLastTurn = sinceLastTurn
        }
    }

    /// Build a heartbeat prompt from a frozen snapshot and live temporal state.
    ///
    /// The frozen prefix (system + tools + messages through breakpoint 3) is replayed
    /// verbatim for cache hits. The heartbeat message carries live temporal state so the
    /// model experiences time passing during idle — not just a counter, but a sense of
    /// how long it's been quiet and how many heartbeat cycles have elapsed.
    ///
    /// - Parameters:
    ///   - snapshot: The frozen prompt snapshot from the last real turn.
    ///   - temporal: Live temporal state (count, time, idle duration).
    /// - Returns: A prompt ready for the API — frozen prefix + live heartbeat message.
    public func buildHeartbeatPrompt(
        from snapshot: PromptSnapshot,
        temporal: HeartbeatTemporalState,
    ) -> Prompt {
        var messages = snapshot.frozenMessages

        // Ensure the last frozen message is assistant role for proper alternation
        if messages.last?.role != .assistant {
            messages.append(APIMessage(role: .assistant, content: .text("...")))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")
        let timeStr = formatter.string(from: temporal.now)

        let idleStr: String
        if let idle = temporal.idleDuration {
            let minutes = Int(idle.components.seconds / 60)
            idleStr = minutes < 60 ? "\(minutes)min" : "\(minutes / 60)h\(minutes % 60)min"
        } else {
            idleStr = "unknown"
        }

        let mode: String = if let idle = temporal.idleDuration {
            idle.components.seconds > 3_600 ? "recovery" : idle.components.seconds > 600 ? "idle" : "active"
        } else {
            "idle"
        }

        let heartbeatText = """
        <temporal_grounding>
          <now>\(timeStr)</now>
          <allostasis mode="\(mode)" />
          <heartbeat n="\(temporal.heartbeatCount)" idle="\(idleStr)" />
        </temporal_grounding>
        This is a periodic heartbeat. Reply HEARTBEAT_SKIP if nothing needs attention, \
        or act normally (tools available) if something does.
        """

        messages.append(APIMessage(role: .user, content: .text(heartbeatText)))

        return Prompt(
            system: snapshot.system,
            messages: messages,
            tools: snapshot.tools,
        )
    }

    /// Build a minimal prompt for workers.
    ///
    /// Workers don't go through the full context assembly pipeline — they have
    /// a simple system prompt and a goal message. No cache breakpoints needed.
    ///
    /// - Parameters:
    ///   - systemPrompt: The worker's system prompt text.
    ///   - goal: The goal message sent as the initial user turn.
    ///   - tools: Tool definitions available to the worker.
    /// - Returns: A minimal ``Prompt`` with one system block and one user message.
    public func buildWorkerPrompt(
        systemPrompt: String,
        goal: String,
        tools: [ToolDefinition],
    ) -> Prompt {
        Prompt(
            system: [SystemBlock(text: systemPrompt, cacheControl: nil)],
            messages: [APIMessage(role: .user, content: .text(goal))],
            tools: tools.map { ToolSchema(from: $0) },
        )
    }

    // MARK: - System Blocks

    /// Assemble ordered system blocks with a single `cache_control` on the last block.
    ///
    /// All system blocks must be completely stable between turns — the Anthropic API
    /// hashes the entire array as one unit, so any byte change in any block invalidates
    /// all caches. Only content that never changes between turns belongs here.
    ///
    /// Volatile content (identity, mirror, cognitive state, timestamps) is handled
    /// separately in ``buildMessages(context:)`` — injected into the message array
    /// where it doesn't affect system-level caching.
    ///
    /// - Parameters:
    ///   - context: The assembled context with categorized sections.
    ///   - credential: Credential discriminant for the OAuth identity prefix.
    /// - Returns: Ordered system blocks ready for the API `system` parameter.
    private func buildSystemBlocks(context: AssembledContext, credential: CredentialKind) -> [SystemBlock] {
        var blocks: [SystemBlock] = []

        // Extract the system prompt text from sections.
        let systemPromptText = context.sections
            .first(where: { $0.kind == .systemPrompt })?.content ?? ""

        // -- Block 0: OAuth identity prefix (uncached) --
        if case .oauth = credential {
            blocks.append(SystemBlock(text: Self.oauthIdentityPrefix, cacheControl: nil))
        }

        // -- Preamble: INTRO.md extract (uncached) --
        // If the system prompt contains both the INTRO marker and the SOUL marker,
        // extract the content before SOUL as a separate preamble block.
        if systemPromptText.contains(Self.introMarker),
           let soulRange = systemPromptText.range(of: Self.soulMarker) {
            let introText = String(systemPromptText[systemPromptText.startIndex ..< soulRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !introText.isEmpty {
                blocks.append(SystemBlock(text: introText, cacheControl: nil))
            }
        }

        // -- Stable summaries (oldest, least likely to change) --
        let stableParts = collectContent(from: context.sections, kinds: [.stableSummaries, .summaries])
        if !stableParts.isEmpty {
            blocks.append(SystemBlock(text: stableParts, cacheControl: nil))
        }

        // -- Recent summaries (changes on compaction) --
        let recentParts = collectContent(from: context.sections, kinds: [.recentSummaries])
        if !recentParts.isEmpty {
            blocks.append(SystemBlock(text: recentParts, cacheControl: nil))
        }

        // -- System prompt (SOUL.md, IDENTITY.md, etc. — last, most important) --
        // Placed last so the model's strongest priming is closest to the conversation.
        var soulText = systemPromptText
        if systemPromptText.contains(Self.introMarker),
           let soulRange = systemPromptText.range(of: Self.soulMarker) {
            soulText = String(systemPromptText[soulRange.lowerBound...])
        }
        if !soulText.isEmpty {
            blocks.append(SystemBlock(text: soulText, cacheControl: nil))
        }

        // -- Single cache_control on the last block --
        // Caches the entire system prefix. Multiple breakpoints are unnecessary
        // since the API hashes the whole array as one unit anyway.
        if let lastIdx = blocks.indices.last {
            blocks[lastIdx] = SystemBlock(text: blocks[lastIdx].text, cacheControl: .ephemeral)
        }

        return blocks
    }

    // MARK: - Messages

    /// Reconstruct the conversation message array with volatile state injection.
    ///
    /// Builds the message array in three phases:
    /// 1. **Conversation history** — stored messages converted to API format with proper
    ///    tool_use/tool_result blocks, image attachments, and message alternation.
    /// 2. **Slow-changing state injection** — identity, mirror, and cognitive state
    ///    prepended to the first user message. These change infrequently (hours/days)
    ///    and sit before the stubbing boundary, so they're covered by the message-level
    ///    cache breakpoint.
    /// 3. **Per-turn state injection** — chronoception and temporal grounding (containing
    ///    timestamps that change every turn) appended to the current user message. These
    ///    sit after the stubbing boundary and are never cached.
    ///
    /// The stubbing boundary ``cache_control`` breakpoint sits ~32 meaningful turns from
    /// the end. Everything before it (system + tools + old messages + slow-changing state)
    /// is cached. Everything after it (recent messages + per-turn state) is reprocessed.
    ///
    /// - Parameter context: The assembled context.
    /// - Returns: A tuple of (message array in strict alternation, boundary index or nil).
    private func buildMessages(context: AssembledContext) -> ([APIMessage], Int?) {
        var messages: [APIMessage] = []
        var pendingToolResults: [ContentBlock] = []
        var emittedToolUseIds: Set<String> = []

        for msg in context.freshTailMessages {
            switch msg.role {
            case .user:
                flushToolResults(&pendingToolResults, into: &messages)
                messages.append(APIMessage(role: .user, content: .text(msg.content)))

            case .assistant:
                flushToolResults(&pendingToolResults, into: &messages)

                let toolCallParts = msg.parts.filter { $0.kind == .toolCall }

                let hasVerbatimResults = Self.hasVerbatimToolResults(
                    toolCallParts: toolCallParts,
                    in: context.freshTailMessages,
                )

                if toolCallParts.isEmpty || !hasVerbatimResults {
                    if !msg.content.isEmpty {
                        messages.append(APIMessage(role: .assistant, content: .text(msg.content)))
                    }
                } else {
                    var contentBlocks: [ContentBlock] = []

                    if !msg.content.isEmpty {
                        contentBlocks.append(.text(msg.content))
                    }

                    for part in toolCallParts {
                        guard let metadataStr = part.metadata,
                              let metaData = metadataStr.data(using: .utf8),
                              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                              let id = meta["id"] as? String,
                              let name = meta["name"] as? String
                        else { continue }

                        let input: JSONValue = if let parsed = try? JSONValue.parse(part.content) {
                            parsed
                        } else {
                            .object([])
                        }

                        contentBlocks.append(.toolUse(ToolUseBlock(id: id, name: name, input: input)))
                        emittedToolUseIds.insert(id)
                    }

                    if !contentBlocks.isEmpty {
                        messages.append(APIMessage(role: .assistant, content: .blocks(contentBlocks)))
                    } else if !msg.content.isEmpty {
                        messages.append(APIMessage(role: .assistant, content: .text(msg.content)))
                    }
                }

            case .tool:
                let resultPart = msg.parts.first(where: { $0.kind == .toolResult })
                guard let metadataStr = resultPart?.metadata,
                      let metaData = metadataStr.data(using: .utf8),
                      let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                      let toolUseId = meta["toolUseId"] as? String,
                      emittedToolUseIds.contains(toolUseId)
                else {
                    continue
                }

                let isError = (meta["isError"] as? Bool) ?? false
                pendingToolResults.append(
                    .toolResult(ToolResultBlock(toolUseId: toolUseId, content: msg.content, isError: isError)),
                )

            case .system:
                continue
            }
        }

        flushToolResults(&pendingToolResults, into: &messages)

        // -- Inject slow-changing state into the first user message --
        // Identity and mirror change infrequently (hours/days).
        // Placed before the stubbing boundary so they're covered by the message-level
        // cache breakpoint. Only re-processed when claims actually change.
        let slowChangingParts = collectContent(
            from: context.sections,
            kinds: [.identity, .mirror],
        )

        if messages.isEmpty {
            let text = slowChangingParts.isEmpty ? "(conversation context)" : slowChangingParts
            messages.append(APIMessage(role: .user, content: .text(text)))
        } else if messages.first?.role != .user {
            let prefix = slowChangingParts.isEmpty ? "(conversation context)" : slowChangingParts
            messages.insert(APIMessage(role: .user, content: .text(prefix)), at: 0)
        } else if !slowChangingParts.isEmpty {
            let existingFirst = messages[0]
            switch existingFirst.content {
            case let .text(t):
                messages[0] = APIMessage(role: .user, content: .text(slowChangingParts + "\n\n" + t))
            case let .blocks(bs):
                messages[0] = APIMessage(role: .user, content: .blocks([.text(slowChangingParts)] + bs))
            }
        }

        // -- Inject per-turn state into the current (last) user message --
        // Chronoception, temporal grounding, and cognitive state change every turn.
        // Placed after the stubbing boundary so they never invalidate the message cache.
        let perTurnParts = collectContent(
            from: context.sections,
            kinds: [.chronoception, .temporalGrounding, .cognitiveState],
        )

        appendCurrentMessage(from: context, perTurnPrefix: perTurnParts, to: &messages)

        messages = Self.ensureAlternation(messages)

        // NO message-level cache_control breakpoints.
        //
        // Adding cache_control to a message changes its serialization (wraps text
        // in a blocks array with a cache_control object). This means the SAME message
        // at the SAME position serializes differently depending on whether it was the
        // breakpoint that turn. The lookback then fails because the prefix hash changed.
        //
        // Instead, rely entirely on top-level automatic caching:
        //   "cache_control": {"type": "ephemeral"} on the request body
        // The API places the breakpoint on the last block and walks backward up to
        // 20 blocks. Since we only append messages (never modify old ones), the prefix
        // at the prior turn's last-block position is byte-identical → cache hit.
        //
        // System blocks still have an explicit cache_control (set in buildSystemBlocks)
        // as a separate cache tier — they never move, so their serialization is stable.
        let boundaryIndex = messages.count >= 2 ? messages.count - 2 : nil

        return (messages, boundaryIndex)
    }

    // computeAPIBoundaryIndex removed — automatic caching handles boundary placement.

    // MARK: - Message Helpers

    /// Flush accumulated tool result blocks as a single user message.
    ///
    /// Tool results are batched into one user message with multiple ``ContentBlock/toolResult``
    /// blocks, matching the Anthropic API's expectation that all tool results from a single
    /// assistant turn appear in the same user message.
    ///
    /// - Parameters:
    ///   - pending: The pending tool results buffer — emptied after flushing.
    ///   - messages: The message array to append the flushed user message to.
    private func flushToolResults(_ pending: inout [ContentBlock], into messages: inout [APIMessage]) {
        guard !pending.isEmpty else { return }
        messages.append(APIMessage(role: .user, content: .blocks(pending)))
        pending = []
    }

    /// Append the current user message as the final turn with optional per-turn context.
    ///
    /// Per-turn state (chronoception, temporal grounding) is prepended to the current
    /// message so it appears after the stubbing boundary and is never cached.
    ///
    /// - Parameters:
    ///   - context: The assembled context with current message text and images.
    ///   - perTurnPrefix: Per-turn volatile state to prepend (timestamps, session info).
    ///   - messages: The message array to append to.
    private func appendCurrentMessage(
        from context: AssembledContext,
        perTurnPrefix: String,
        to messages: inout [APIMessage],
    ) {
        let currentText = context.currentMessageText

        // Combine per-turn prefix with the current message text
        let combinedText: String? = switch (perTurnPrefix.isEmpty, currentText) {
        case (true, let t): t
        case (false, let .some(t)): perTurnPrefix + "\n\n" + t
        case (false, .none): perTurnPrefix + "\n\nContinue."
        }

        guard let text = combinedText else { return }

        if context.currentMessageImages.isEmpty {
            messages.append(APIMessage(role: .user, content: .text(text)))
        } else {
            var contentBlocks: [ContentBlock] = []
            for image in context.currentMessageImages {
                contentBlocks.append(.image(ImageBlock(mediaType: image.mediaType, data: image.data)))
            }
            contentBlocks.append(.text(text))
            messages.append(APIMessage(role: .user, content: .blocks(contentBlocks)))
        }
    }

    /// Check whether an assistant message's tool calls have verbatim (non-stubbed) results.
    ///
    /// Looks ahead in the fresh tail for `.tool` messages whose `.toolResult` part has a
    /// `toolUseId` matching one of the tool call IDs. If ANY matching result has real content
    /// (doesn't start with `"[Tool output omitted"`), returns `true`.
    ///
    /// When all matching results are stubbed, the tool_use/tool_result pair adds no value —
    /// the caller should emit text-only.
    ///
    /// - Parameters:
    ///   - toolCallParts: The `.toolCall` parts from the assistant message.
    ///   - tailMessages: The full fresh tail message array to search.
    /// - Returns: `true` if at least one matching tool result has verbatim content.
    private static func hasVerbatimToolResults(
        toolCallParts: [MessagePart],
        in tailMessages: [StoredMessage],
    ) -> Bool {
        guard !toolCallParts.isEmpty else { return false }

        let toolUseIds = Set(toolCallParts.compactMap { part -> String? in
            guard let meta = part.metadata,
                  let data = meta.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json["id"] as? String
        })

        for tailMsg in tailMessages where tailMsg.role == .tool {
            let resultId = tailMsg.parts
                .first(where: { $0.kind == .toolResult })
                .flatMap { p -> String? in
                    guard let m = p.metadata, let d = m.data(using: .utf8),
                          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                    else { return nil }
                    return j["toolUseId"] as? String
                }
            if let id = resultId, toolUseIds.contains(id),
               !tailMsg.content.hasPrefix("[Tool output omitted") {
                return true
            }
        }
        return false
    }

    /// Enforce strict user/assistant alternation by merging consecutive same-role messages.
    ///
    /// The Anthropic API requires messages to strictly alternate between user and assistant
    /// roles. When two consecutive messages have the same role, their content is merged:
    /// - `.text` + `.text` → `.text` (joined with double newline)
    /// - `.text` + `.blocks` → `.blocks` (text wrapped as text block, prepended)
    /// - `.blocks` + `.text` → `.blocks` (text wrapped as text block, appended)
    /// - `.blocks` + `.blocks` → `.blocks` (concatenated)
    ///
    /// - Parameter messages: The message array, possibly with consecutive same-role messages.
    /// - Returns: A new message array with strict alternation.
    private static func ensureAlternation(_ messages: [APIMessage]) -> [APIMessage] {
        guard !messages.isEmpty else { return messages }

        var result: [APIMessage] = []

        for message in messages {
            if let last = result.last, last.role == message.role {
                let merged = mergeContent(last.content, message.content)
                result[result.count - 1] = APIMessage(role: message.role, content: merged)
            } else {
                result.append(message)
            }
        }

        return result
    }

    /// Merge two ``MessageContent`` values into a single content value.
    ///
    /// Converts text to blocks when mixing with block content. Two text values
    /// are joined with a double newline separator.
    ///
    /// - Parameters:
    ///   - a: The first (earlier) content.
    ///   - b: The second (later) content.
    /// - Returns: Merged content containing all blocks from both inputs.
    private static func mergeContent(_ a: MessageContent, _ b: MessageContent) -> MessageContent {
        switch (a, b) {
        case let (.text(t1), .text(t2)):
            .text(t1 + "\n\n" + t2)
        case let (.text(s), .blocks(bs)):
            .blocks([.text(s)] + bs)
        case let (.blocks(as_), .text(s)):
            .blocks(as_ + [.text(s)])
        case let (.blocks(as_), .blocks(bs)):
            .blocks(as_ + bs)
        }
    }

    // MARK: - Helpers

    /// Collect and join non-empty content from sections matching any of the given kinds.
    ///
    /// Iterates sections in their original order, filtering by kind and skipping empty content.
    /// Multiple matching sections are joined with double newlines.
    ///
    /// - Parameters:
    ///   - sections: All context sections to search.
    ///   - kinds: The section kinds to include.
    /// - Returns: Joined content string, or empty string if no matching non-empty sections.
    private func collectContent(from sections: [ContextSection], kinds: Set<ContextSectionKind>) -> String {
        sections
            .filter { kinds.contains($0.kind) && !$0.content.isEmpty }
            .map(\.content)
            .joined(separator: "\n\n")
    }
}
