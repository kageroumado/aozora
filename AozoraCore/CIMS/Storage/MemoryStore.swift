import CryptoKit
import Foundation
import GRDB

/// LCM-backed memory persistence and retrieval actor.
///
/// Manages the entire memory DAG lifecycle: message persistence with structured parts,
/// depth-0 raw turn node creation, FTS5 indexing, frontier maintenance, keyword/regex search,
/// node expansion, delegation grant CRUD, and assembly-support queries (fresh tail, summaries).
///
/// All database operations go through ``CIMSDatabase/dbPool`` without holding the actor's
/// executor during long I/O — each method `await`s into the database pool's serialized writer
/// or concurrent readers, then returns results back to the actor.
///
/// Offline components (``DAGCompactor``, ``ColdStorage``, ``BumpDetector``) are injected
/// after initialization via ``setOfflineComponents(compactor:coldStorage:bumpDetector:)``
/// because they share the same ``CIMSDatabase`` but are created by ``CIMSGateway``.
public actor MemoryStore: MemoryStoring {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// The DAG compactor for leaf and condensed passes. Injected by ``CIMSGateway``.
    private var compactor: DAGCompactor?

    /// The cold storage manager for demoting infrequently-accessed nodes. Injected by ``CIMSGateway``.
    private var coldStorage: ColdStorage?

    /// The bump detector for identifying reminiscence bumps. Injected by ``CIMSGateway``.
    private var bumpDetector: BumpDetector?

    /// Runtime configuration store for tunable thresholds. Injected by ``CIMSGateway``.
    private var configStore: ConfigStore?

    /// Consolidation proposals extracted from high-salience content during pre-compression
    /// claim extraction. Accumulated during compaction passes and consumed by
    /// ``ConsolidationEngine`` via ``consumePreCompressionProposals()``.
    private var pendingPreCompressionProposals: [ConsolidationProposal] = []

    /// Creates a memory store backed by the given database.
    ///
    /// Offline components must be injected separately via
    /// ``setOfflineComponents(compactor:coldStorage:bumpDetector:)`` after creation.
    ///
    /// - Parameter database: The CIMS database instance to use for all persistence.
    public init(database: CIMSDatabase) {
        self.db = database
    }

    /// Inject the offline maintenance components into this memory store.
    ///
    /// Called by ``CIMSGateway`` after constructing all components, since the compactor,
    /// cold storage, and bump detector share the same ``CIMSDatabase`` instance but
    /// require a ``ModelProviding`` reference that the memory store doesn't own.
    ///
    /// - Parameters:
    ///   - compactor: The DAG compactor for leaf and condensed summarization passes.
    ///   - coldStorage: The cold storage manager for tiered demotion/promotion.
    ///   - bumpDetector: The bump detector for identifying reminiscence bumps.
    public func setOfflineComponents(
        compactor: DAGCompactor,
        coldStorage: ColdStorage,
        bumpDetector: BumpDetector,
        configStore: ConfigStore? = nil,
    ) {
        self.compactor = compactor
        self.coldStorage = coldStorage
        self.bumpDetector = bumpDetector
        self.configStore = configStore
    }

    // MARK: - Persistence

    /// Persist a user message and assistant response as a new turn in the DAG.
    ///
    /// Creates the conversation record if one doesn't exist for the current session,
    /// inserts both the user message and assistant response as ``MessageRecord``s with
    /// their structured ``MessagePartRecord``s, creates a depth-0 ``LCMNodeRecord``
    /// with a deterministic node ID, indexes the turn content in FTS5, and appends
    /// the node to the conversation frontier.
    ///
    /// Node IDs are deterministic: `"node_" + SHA-256(canonicalText).prefix(16)`.
    ///
    /// - Parameters:
    ///   - message: The inbound user message.
    ///   - response: The assistant's response to persist alongside.
    public func ingest(_ message: InboundMessage, response: AssistantResponse) async {
        let now = Self.formatDate(Date())

        do {
            try await db.dbPool.write { db in
                // Find or create conversation. Use a stable session key derived from the message.
                // For now, use a default session key — the coordinator will manage sessions.
                let sessionKey = "default"
                let userKey = "default"

                var conversation: ConversationRecord
                if let existing = try ConversationRecord
                    .filter(Column("sessionKey") == sessionKey)
                    .fetchOne(db) {
                    conversation = existing
                } else {
                    conversation = ConversationRecord(
                        sessionKey: sessionKey,
                        userKey: userKey,
                        startedAt: now,
                        lastMessageAt: nil,
                        messageCount: 0,
                    )
                    try conversation.insert(db)
                }

                let conversationId = conversation.id!

                // Insert user message
                let userTokenEstimate = message.text.utf8.count / 4
                var userRecord = MessageRecord(
                    conversationId: conversationId,
                    role: MessageRole.user.rawValue,
                    content: message.text,
                    tokenEstimate: userTokenEstimate,
                    salienceScore: nil,
                    createdAt: now,
                )
                try userRecord.insert(db)

                // Insert user message parts, intercepting large content
                for part in message.parts {
                    let partTokens = part.content.utf8.count / 4
                    if partTokens > CIMSDefaults.largeFileTokenThreshold {
                        let fileId = "file_\(UUID().uuidString)"
                        let storagePath = Self.largeFileStoragePath(for: fileId)
                        try part.content.write(toFile: storagePath, atomically: true, encoding: .utf8)

                        let summary = Self.makeLargeFileSummary(part.content)
                        let record = LargeFileRecord(
                            fileId: fileId,
                            conversationId: conversationId,
                            messageId: userRecord.id!,
                            fileName: nil,
                            mimeType: nil,
                            byteSize: part.content.utf8.count,
                            tokenEstimate: partTokens,
                            explorationSummary: summary,
                            storagePath: storagePath,
                            createdAt: now,
                        )
                        try record.insert(db)

                        let placeholder = "[Large content intercepted: \(partTokens) tokens — stored as file \(fileId)]"
                        var partRecord = MessagePartRecord(
                            messageId: userRecord.id!,
                            partKind: MessagePartKind.file.rawValue,
                            ordinal: part.ordinal,
                            content: placeholder,
                            metadata: fileId,
                        )
                        try partRecord.insert(db)
                    } else {
                        var partRecord = MessagePartRecord(
                            messageId: userRecord.id!,
                            partKind: part.kind.rawValue,
                            ordinal: part.ordinal,
                            content: part.content,
                            metadata: part.metadata,
                        )
                        try partRecord.insert(db)
                    }
                }

                // Insert assistant message
                let assistantTokenEstimate = response.content.utf8.count / 4
                var assistantRecord = MessageRecord(
                    conversationId: conversationId,
                    role: MessageRole.assistant.rawValue,
                    content: response.content,
                    tokenEstimate: assistantTokenEstimate,
                    salienceScore: nil,
                    createdAt: Self.formatDate(Date()),
                )
                try assistantRecord.insert(db)

                // Insert assistant message parts, intercepting large content
                for part in response.parts {
                    let partTokens = part.content.utf8.count / 4
                    if partTokens > CIMSDefaults.largeFileTokenThreshold {
                        let fileId = "file_\(UUID().uuidString)"
                        let storagePath = Self.largeFileStoragePath(for: fileId)
                        try part.content.write(toFile: storagePath, atomically: true, encoding: .utf8)

                        let summary = Self.makeLargeFileSummary(part.content)
                        let record = LargeFileRecord(
                            fileId: fileId,
                            conversationId: conversationId,
                            messageId: assistantRecord.id!,
                            fileName: nil,
                            mimeType: nil,
                            byteSize: part.content.utf8.count,
                            tokenEstimate: partTokens,
                            explorationSummary: summary,
                            storagePath: storagePath,
                            createdAt: now,
                        )
                        try record.insert(db)

                        let placeholder = "[Large content intercepted: \(partTokens) tokens — stored as file \(fileId)]"
                        var partRecord = MessagePartRecord(
                            messageId: assistantRecord.id!,
                            partKind: MessagePartKind.file.rawValue,
                            ordinal: part.ordinal,
                            content: placeholder,
                            metadata: fileId,
                        )
                        try partRecord.insert(db)
                    } else {
                        var partRecord = MessagePartRecord(
                            messageId: assistantRecord.id!,
                            partKind: part.kind.rawValue,
                            ordinal: part.ordinal,
                            content: part.content,
                            metadata: part.metadata,
                        )
                        try partRecord.insert(db)
                    }
                }

                // Update conversation metadata
                conversation.messageCount += 2
                conversation.lastMessageAt = now
                try conversation.update(db)

                // Build canonical text for the turn (user + assistant combined)
                let canonicalText = "User: \(message.text)\nAssistant: \(response.content)"
                let nodeId = Self.makeNodeId(from: canonicalText)
                let tokenCount = canonicalText.utf8.count / 4

                // Create depth-0 raw_turn node
                let node = LCMNodeRecord(
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: 0,
                    kind: NodeKind.rawTurn.rawValue,
                    tokenCount: tokenCount,
                    checksum: Self.sha256Hex(canonicalText),
                    salienceScore: 0,
                    hotness: 1.0,
                    isCold: 0,
                    canonicalText: canonicalText,
                    summaryText: nil,
                    expandFooter: nil,
                    earliestAt: now,
                    latestAt: now,
                    lastAccessedAt: now,
                    version: 1,
                    createdAt: now,
                )
                // Ignore duplicate nodeIds — same canonical text produces the same
                // hash, so the node already exists with identical content.
                try node.insert(db, onConflict: .ignore)

                // Index in FTS5 (also ignore duplicates)
                let ftsRecord = LCMFTSRecord(
                    content: canonicalText,
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: 0,
                    kind: NodeKind.rawTurn.rawValue,
                )
                try ftsRecord.insert(db, onConflict: .ignore)

                // Update frontier — append this node at the next ordinal
                let maxOrdinal = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(ordinal) FROM lcm_frontier WHERE conversationId = ?",
                    arguments: [conversationId],
                ) ?? -1

                let frontier = LCMFrontierRecord(
                    conversationId: conversationId,
                    nodeId: nodeId,
                    ordinal: maxOrdinal + 1,
                )
                try frontier.insert(db, onConflict: .ignore)
            }
        } catch {
            // Persistence errors are logged but don't crash the system.
            // The turn state machine handles this via timeout fallback.
            print("[MemoryStore] ingest error: \(error)")
        }
    }

    /// Persist a full turn with tool call history as structured message parts.
    ///
    /// Creates the conversation record if needed, then persists the complete tool loop:
    /// 1. User message with text parts
    /// 2. For each tool iteration: assistant message with toolCall parts, then tool-role messages with toolResult parts
    /// 3. Final assistant message with text parts
    /// 4. LCM node, FTS index, and frontier update
    ///
    /// The LCM node's `canonicalText` includes a summary of tool calls (tool names used)
    /// but NOT the full tool output, which is stored in `message_parts`.
    public func ingestTurn(
        userMessage: InboundMessage,
        toolHistory: [ToolTurnRecord],
        finalResponse: AssistantResponse,
        sessionKey: String,
        userKey: String,
    ) async {
        let now = Self.formatDate(Date())

        do {
            try await db.dbPool.write { db in
                // Find or create conversation
                var conversation: ConversationRecord
                if let existing = try ConversationRecord
                    .filter(Column("sessionKey") == sessionKey)
                    .fetchOne(db) {
                    conversation = existing
                } else {
                    conversation = ConversationRecord(
                        sessionKey: sessionKey,
                        userKey: userKey,
                        startedAt: now,
                        lastMessageAt: nil,
                        messageCount: 0,
                    )
                    try conversation.insert(db)
                }

                let conversationId = conversation.id!
                var messageCount = 0

                // 1. Insert user message
                let userTokenEstimate = userMessage.text.utf8.count / 4
                var userRecord = MessageRecord(
                    conversationId: conversationId,
                    role: MessageRole.user.rawValue,
                    content: userMessage.text,
                    tokenEstimate: userTokenEstimate,
                    salienceScore: nil,
                    createdAt: now,
                )
                try userRecord.insert(db)
                messageCount += 1

                // Insert user message parts
                for part in userMessage.parts {
                    var partRecord = MessagePartRecord(
                        messageId: userRecord.id!,
                        partKind: part.kind.rawValue,
                        ordinal: part.ordinal,
                        content: part.content,
                        metadata: part.metadata,
                    )
                    try partRecord.insert(db)
                }

                // 2. For each tool iteration, insert assistant + tool messages
                for turn in toolHistory {
                    // Assistant message with text (if any) + toolCall parts
                    let assistantTokenEstimate = turn.assistantText.utf8.count / 4
                    var assistantRecord = MessageRecord(
                        conversationId: conversationId,
                        role: MessageRole.assistant.rawValue,
                        content: turn.assistantText,
                        tokenEstimate: assistantTokenEstimate,
                        salienceScore: nil,
                        createdAt: Self.formatDate(Date()),
                    )
                    try assistantRecord.insert(db)
                    messageCount += 1

                    var ordinal = 0

                    // Text part (if non-empty)
                    if !turn.assistantText.isEmpty {
                        var textPart = MessagePartRecord(
                            messageId: assistantRecord.id!,
                            partKind: MessagePartKind.text.rawValue,
                            ordinal: ordinal,
                            content: turn.assistantText,
                            metadata: nil,
                        )
                        try textPart.insert(db)
                        ordinal += 1
                    }

                    // Tool call parts
                    for tc in turn.toolCalls {
                        let metadataJSON = "{\"id\":\"\(Self.escapeJSON(tc.id))\",\"name\":\"\(Self.escapeJSON(tc.name))\"}"
                        var tcPart = MessagePartRecord(
                            messageId: assistantRecord.id!,
                            partKind: MessagePartKind.toolCall.rawValue,
                            ordinal: ordinal,
                            content: tc.arguments,
                            metadata: metadataJSON,
                        )
                        try tcPart.insert(db)
                        ordinal += 1
                    }

                    // Tool result messages (role = "tool")
                    for result in turn.toolResults {
                        let resultTokenEstimate = result.content.utf8.count / 4
                        var toolRecord = MessageRecord(
                            conversationId: conversationId,
                            role: MessageRole.tool.rawValue,
                            content: result.content,
                            tokenEstimate: resultTokenEstimate,
                            salienceScore: nil,
                            createdAt: Self.formatDate(Date()),
                        )
                        try toolRecord.insert(db)
                        messageCount += 1

                        let resultMetadataJSON = "{\"toolUseId\":\"\(Self.escapeJSON(result.toolUseId))\",\"isError\":\(result.isError)}"
                        var resultPart = MessagePartRecord(
                            messageId: toolRecord.id!,
                            partKind: MessagePartKind.toolResult.rawValue,
                            ordinal: 0,
                            content: result.content,
                            metadata: resultMetadataJSON,
                        )
                        try resultPart.insert(db)
                    }
                }

                // 3. Insert final assistant message
                let finalTokenEstimate = finalResponse.content.utf8.count / 4
                var finalRecord = MessageRecord(
                    conversationId: conversationId,
                    role: MessageRole.assistant.rawValue,
                    content: finalResponse.content,
                    tokenEstimate: finalTokenEstimate,
                    salienceScore: nil,
                    createdAt: Self.formatDate(Date()),
                )
                try finalRecord.insert(db)
                messageCount += 1

                // Insert final assistant text parts
                for part in finalResponse.parts {
                    var partRecord = MessagePartRecord(
                        messageId: finalRecord.id!,
                        partKind: part.kind.rawValue,
                        ordinal: part.ordinal,
                        content: part.content,
                        metadata: part.metadata,
                    )
                    try partRecord.insert(db)
                }

                // 4. Update conversation metadata
                conversation.messageCount += messageCount
                conversation.lastMessageAt = now
                try conversation.update(db)

                // 5. Build canonical text for the LCM node
                // Include tool call summary (names only) but not full output
                let toolSummary: String
                if toolHistory.isEmpty {
                    toolSummary = ""
                } else {
                    let toolNames = Set(toolHistory.flatMap { $0.toolCalls.map(\.name) })
                    toolSummary = "\n[Used tools: \(toolNames.sorted().joined(separator: ", "))]"
                }

                let canonicalText = "User: \(userMessage.text)\(toolSummary)\nAssistant: \(finalResponse.content)"
                let nodeId = Self.makeNodeId(from: canonicalText)
                let tokenCount = canonicalText.utf8.count / 4

                // Create depth-0 raw_turn node
                let node = LCMNodeRecord(
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: 0,
                    kind: NodeKind.rawTurn.rawValue,
                    tokenCount: tokenCount,
                    checksum: Self.sha256Hex(canonicalText),
                    salienceScore: 0,
                    hotness: 1.0,
                    isCold: 0,
                    canonicalText: canonicalText,
                    summaryText: nil,
                    expandFooter: nil,
                    earliestAt: now,
                    latestAt: now,
                    lastAccessedAt: now,
                    version: 1,
                    createdAt: now,
                )
                try node.insert(db, onConflict: .ignore)

                // Index in FTS5
                let ftsRecord = LCMFTSRecord(
                    content: canonicalText,
                    nodeId: nodeId,
                    conversationId: conversationId,
                    depth: 0,
                    kind: NodeKind.rawTurn.rawValue,
                )
                try ftsRecord.insert(db, onConflict: .ignore)

                // Update frontier
                let maxOrdinal = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(ordinal) FROM lcm_frontier WHERE conversationId = ?",
                    arguments: [conversationId],
                ) ?? -1

                let frontier = LCMFrontierRecord(
                    conversationId: conversationId,
                    nodeId: nodeId,
                    ordinal: maxOrdinal + 1,
                )
                try frontier.insert(db, onConflict: .ignore)
            }
        } catch {
            print("[MemoryStore] ingestTurn error: \(error)")
        }
    }

    /// Batch-import pre-existing messages (e.g., during migration).
    ///
    /// Currently a no-op placeholder. Migration support will be added when needed.
    ///
    /// - Parameter messages: Messages to import, in chronological order.
    public func ingestBatch(_: [StoredMessage]) async {
        // Batch import for migration — implementation deferred
    }

    /// Persist a single tool result incrementally during a turn.
    ///
    /// Creates a tool-role message in the active conversation. Called by
    /// ``PersistingObserver`` between tool iterations so crash recovery
    /// preserves a truthful record.
    ///
    /// Best-effort: if no conversation exists for the session key, the write
    /// is silently skipped (the full turn persistence handles creation).
    ///
    /// - Parameters:
    ///   - toolUseId: The `tool_use` block ID this result corresponds to.
    ///   - content: The textual content of the tool result.
    ///   - isError: Whether the tool execution encountered an error.
    ///   - sessionKey: The session key identifying the active conversation.
    public func persistToolResult(
        toolUseId: String,
        content: String,
        isError: Bool,
        sessionKey: String,
    ) async {
        let now = Self.formatDate(Date())
        do {
            try await db.dbPool.write { db in
                guard let conversation = try ConversationRecord
                    .filter(Column("sessionKey") == sessionKey)
                    .order(Column("id").desc)
                    .fetchOne(db)
                else { return }

                let tokenEstimate = max(1, content.utf8.count / 4)
                var toolRecord = MessageRecord(
                    conversationId: conversation.id!,
                    role: MessageRole.tool.rawValue,
                    content: content,
                    tokenEstimate: tokenEstimate,
                    salienceScore: nil,
                    createdAt: now,
                )
                try toolRecord.insert(db)

                let metadataJSON = "{\"toolUseId\":\"\(Self.escapeJSON(toolUseId))\",\"isError\":\(isError)}"
                var resultPart = MessagePartRecord(
                    messageId: toolRecord.id!,
                    partKind: MessagePartKind.toolResult.rawValue,
                    ordinal: 0,
                    content: content,
                    metadata: metadataJSON,
                )
                try resultPart.insert(db)
            }
        } catch {
            print("[MemoryStore] persistToolResult error: \(error)")
        }
    }

    // MARK: - Retrieval

    /// Retrieve memory relevant to a query, ranked by FTS5 + DAG frontier proximity + salience boost.
    ///
    /// Performs an FTS5 keyword search, applies the salience envelope as an additive boost,
    /// and returns both ranked summary nodes and the fresh tail. If the FTS5 query fails
    /// (e.g., special characters), returns an empty result rather than crashing.
    ///
    /// - Parameters:
    ///   - query: The search query (typically the user's message text).
    ///   - salienceBoost: Salience envelope to additively boost identity-relevant results.
    ///   - limit: Maximum number of summary nodes to return.
    /// - Returns: Ranked summaries plus the fresh tail.
    public func retrieve(query: String, salienceBoost: SalienceEnvelope, limit: Int) async -> MemoryRetrievalResult {
        do {
            let result = try await db.dbPool.read { db in
                let escapedQuery = Self.escapeFTS5Query(query)

                // FTS5 keyword search for summary nodes (depth > 0)
                var summaries: [SummaryNode] = []
                if !escapedQuery.isEmpty {
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT n.*, fts.rank
                        FROM lcm_fts fts
                        JOIN lcm_nodes n ON n.nodeId = fts.nodeId
                        WHERE lcm_fts MATCH ?
                          AND n.depth > 0
                        ORDER BY fts.rank
                        LIMIT ?
                        """,
                        arguments: [escapedQuery, limit],
                    )

                    summaries = rows.map { row in
                        SummaryNode(
                            nodeId: row["nodeId"],
                            kind: NodeKind(rawValue: row["kind"]) ?? .rawTurn,
                            depth: row["depth"],
                            tokenCount: row["tokenCount"],
                            summaryText: row["summaryText"] ?? "",
                            expandFooter: row["expandFooter"],
                            earliestAt: MemoryStore.parseDate(row["earliestAt"]),
                            latestAt: MemoryStore.parseDate(row["latestAt"]),
                            salienceScore: Float(row["salienceScore"] as Double) + salienceBoost.composite * 0.2,
                            descendantCount: 0,
                            parentIds: [],
                        )
                    }
                }

                // Fresh tail: last N meaningful conversation messages plus their
                // associated tool results. Counts only user messages and non-empty
                // assistant messages — empty assistant turns (intermediate tool-use
                // steps with no text) don't consume the count.
                let cutoffId = try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM messages
                    WHERE (role = 'user')
                       OR (role = 'assistant' AND TRIM(content) != '')
                    ORDER BY id DESC
                    LIMIT 1 OFFSET ?
                    """,
                    arguments: [CIMSDefaults.protectedTailCount - 1],
                ) ?? 0

                // Fetch all messages (including tool) from that cutoff onward
                let tailRecords = try MessageRecord
                    .filter(Column("id") >= cutoffId)
                    .order(Column("id").asc)
                    .fetchAll(db)

                let tailMessages = try Self.buildStoredMessages(from: tailRecords, in: db)

                let totalTokens = summaries.reduce(0) { $0 + $1.tokenCount }
                    + tailMessages.reduce(0) { $0 + $1.tokenEstimate }

                return MemoryRetrievalResult(
                    summaries: summaries,
                    freshTail: tailMessages,
                    totalTokens: totalTokens,
                )
            }

            // Bump hotness for retrieved summary nodes
            let retrievedNodeIds = result.summaries.map(\.nodeId)
            await bumpHotness(for: retrievedNodeIds)

            return result
        } catch {
            print("[MemoryStore] retrieve error: \(error)")
            return MemoryRetrievalResult(summaries: [], freshTail: [], totalTokens: 0)
        }
    }

    /// Retrieve all frontier summaries plus the fresh tail for context estimation.
    ///
    /// Unlike ``retrieve(query:salienceBoost:limit:)`` which uses FTS5 keyword search,
    /// this loads ALL frontier nodes (the compacted DAG context) regardless of query relevance.
    /// Used for diagnostic context size estimation without running a real turn.
    public func retrieveFrontier() async -> MemoryRetrievalResult {
        do {
            return try await db.dbPool.read { db in
                // Load all frontier summary nodes ordered chronologically
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT n.*
                    FROM lcm_frontier f
                    JOIN lcm_nodes n ON f.nodeId = n.nodeId
                    ORDER BY n.earliestAt ASC
                    """,
                )

                let summaries = rows.map { row in
                    SummaryNode(
                        nodeId: row["nodeId"],
                        kind: NodeKind(rawValue: row["kind"]) ?? .rawTurn,
                        depth: row["depth"],
                        tokenCount: row["tokenCount"],
                        summaryText: row["summaryText"] ?? "",
                        expandFooter: row["expandFooter"],
                        earliestAt: MemoryStore.parseDate(row["earliestAt"]),
                        latestAt: MemoryStore.parseDate(row["latestAt"]),
                        salienceScore: row["salienceScore"],
                        descendantCount: 0,
                        parentIds: [],
                    )
                }

                // Fresh tail: last N meaningful conversation messages plus their
                // associated tool results. Counts only user messages and non-empty
                // assistant messages — empty assistant turns (intermediate tool-use
                // steps with no text) don't consume the count.
                let cutoffId = try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM messages
                    WHERE (role = 'user')
                       OR (role = 'assistant' AND TRIM(content) != '')
                    ORDER BY id DESC
                    LIMIT 1 OFFSET ?
                    """,
                    arguments: [CIMSDefaults.protectedTailCount - 1],
                ) ?? 0

                // Fetch all messages (including tool) from that cutoff onward
                let tailRecords = try MessageRecord
                    .filter(Column("id") >= cutoffId)
                    .order(Column("id").asc)
                    .fetchAll(db)

                let tailMessages = try Self.buildStoredMessages(from: tailRecords, in: db)

                let totalTokens = summaries.reduce(0) { $0 + $1.tokenCount }
                    + tailMessages.reduce(0) { $0 + $1.tokenEstimate }

                return MemoryRetrievalResult(
                    summaries: summaries,
                    freshTail: tailMessages,
                    totalTokens: totalTokens,
                )
            }
        } catch {
            print("[MemoryStore] retrieveFrontier error: \(error)")
            return MemoryRetrievalResult(summaries: [], freshTail: [], totalTokens: 0)
        }
    }

    /// Search memory by keyword (FTS5) or regex pattern.
    ///
    /// In `fullText` mode, escapes the pattern for FTS5 MATCH syntax and returns BM25-ranked
    /// results. In `regex` mode, performs a linear scan of canonical text using `NSRegularExpression`.
    /// Special characters in FTS5 queries are escaped to prevent syntax errors.
    ///
    /// - Parameters:
    ///   - pattern: The search pattern.
    ///   - mode: Whether to use full-text search or regex matching.
    ///   - scope: Which conversations to search.
    /// - Returns: Matching excerpts with scores.
    public func grep(pattern: String, mode: GrepMode, scope: GrepScope) async -> [GrepMatch] {
        do {
            return try await db.dbPool.read { db in
                switch mode {
                case .fullText:
                    let escaped = Self.escapeFTS5Query(pattern)
                    guard !escaped.isEmpty else { return [] }

                    var sql = """
                    SELECT fts.nodeId, snippet(lcm_fts, 0, '', '', '...', 32) AS excerpt, fts.rank
                    FROM lcm_fts fts
                    """
                    var arguments: [any DatabaseValueConvertible] = []

                    switch scope {
                    case let .conversation(id):
                        sql += " WHERE lcm_fts MATCH ? AND fts.conversationId = ?"
                        arguments = [escaped, id]
                    case let .conversations(ids):
                        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                        sql += " WHERE lcm_fts MATCH ? AND fts.conversationId IN (\(placeholders))"
                        arguments = [escaped] + ids
                    case .all:
                        sql += " WHERE lcm_fts MATCH ?"
                        arguments = [escaped]
                    }

                    sql += " ORDER BY fts.rank LIMIT 50"

                    let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                    return rows.map { row in
                        GrepMatch(
                            nodeId: row["nodeId"],
                            excerpt: row["excerpt"],
                            score: Float(abs(row["rank"] as Double)),
                        )
                    }

                case .regex:
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

                    var sql = "SELECT nodeId, canonicalText FROM lcm_nodes WHERE canonicalText IS NOT NULL"
                    var arguments: [any DatabaseValueConvertible] = []

                    switch scope {
                    case let .conversation(id):
                        sql += " AND conversationId = ?"
                        arguments = [id]
                    case let .conversations(ids):
                        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                        sql += " AND conversationId IN (\(placeholders))"
                        arguments = ids
                    case .all:
                        break
                    }

                    let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                    var matches: [GrepMatch] = []
                    for row in rows {
                        let text: String = row["canonicalText"]
                        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
                        if let match = regex.firstMatch(in: text, range: range) {
                            let matchRange = Range(match.range, in: text)!
                            let excerpt = String(text[matchRange])
                            matches.append(GrepMatch(
                                nodeId: row["nodeId"],
                                excerpt: excerpt,
                                score: 1.0,
                            ))
                        }
                    }
                    return matches
                }
            }
        } catch {
            print("[MemoryStore] grep error: \(error)")
            return []
        }
    }

    /// Fetch the full description of a DAG node or large file.
    ///
    /// For DAG nodes, returns canonical text, summary text, expand footer, and child node IDs.
    /// For large files, returns the exploration summary as canonical text.
    /// If the entity is not found, returns a description with empty fields.
    ///
    /// - Parameter id: The node or file ID to describe.
    /// - Returns: Full metadata and content for the referenced entity.
    public func describe(id: NodeOrFileID) async -> NodeDescription {
        do {
            let result = try await db.dbPool.read { db in
                // Try as a DAG node first
                if let node = try LCMNodeRecord.fetchOne(db, key: id) {
                    // Fetch child node IDs (nodes this one is a summary of)
                    let childIds = try String.fetchAll(
                        db,
                        sql: "SELECT toNodeId FROM lcm_edges WHERE fromNodeId = ? AND edgeKind = ?",
                        arguments: [id, EdgeKind.summaryOf.rawValue],
                    )

                    return NodeDescription(
                        nodeId: node.nodeId,
                        kind: NodeKind(rawValue: node.kind) ?? .rawTurn,
                        depth: node.depth,
                        tokenCount: node.tokenCount,
                        canonicalText: node.canonicalText,
                        summaryText: node.summaryText,
                        expandFooter: node.expandFooter,
                        earliestAt: MemoryStore.parseDate(node.earliestAt),
                        latestAt: MemoryStore.parseDate(node.latestAt),
                        childIds: childIds,
                    )
                }

                // Try as a large file
                if let file = try LargeFileRecord.fetchOne(db, key: id) {
                    return NodeDescription(
                        nodeId: file.fileId,
                        kind: .rawTurn,
                        depth: 0,
                        tokenCount: file.tokenEstimate,
                        canonicalText: file.explorationSummary,
                        summaryText: file.explorationSummary,
                        expandFooter: nil,
                        earliestAt: MemoryStore.parseDate(file.createdAt),
                        latestAt: MemoryStore.parseDate(file.createdAt),
                        childIds: [],
                    )
                }

                // Not found
                return NodeDescription(
                    nodeId: id,
                    kind: .rawTurn,
                    depth: 0,
                    tokenCount: 0,
                    canonicalText: nil,
                    summaryText: nil,
                    expandFooter: nil,
                    earliestAt: Date(),
                    latestAt: Date(),
                    childIds: [],
                )
            }

            // Bump hotness for the described node (only if it's a DAG node, not a file)
            if result.nodeId.hasPrefix("node_") {
                await bumpHotness(for: [result.nodeId])
            }

            return result
        } catch {
            print("[MemoryStore] describe error: \(error)")
            return NodeDescription(
                nodeId: id, kind: .rawTurn, depth: 0, tokenCount: 0,
                canonicalText: nil, summaryText: nil, expandFooter: nil,
                earliestAt: Date(), latestAt: Date(), childIds: [],
            )
        }
    }

    /// Expand compressed DAG nodes to retrieve their full content.
    ///
    /// Fetches `canonicalText` for the given node IDs, accumulating text until the token
    /// budget is exhausted. Nodes without canonical text (cold-demoted) are skipped.
    /// Each accessed node gets its `lastAccessedAt` updated and hotness bumped.
    ///
    /// - Parameters:
    ///   - nodeIds: Node IDs to expand.
    ///   - tokenBudget: Maximum total tokens for all expanded content.
    /// - Returns: Expanded content, possibly truncated if budget exceeded.
    public func expand(nodeIds: [NodeID], tokenBudget: Int) async -> ExpansionResult {
        do {
            return try await db.dbPool.write { db in
                var results: [(nodeId: NodeID, text: String)] = []
                var totalTokens = 0
                var truncated = false
                let now = MemoryStore.formatDate(Date())

                for nodeId in nodeIds {
                    guard let node = try LCMNodeRecord.fetchOne(db, key: nodeId),
                          let text = node.canonicalText
                    else {
                        continue
                    }

                    let tokens = text.utf8.count / 4
                    if totalTokens + tokens > tokenBudget {
                        truncated = true
                        break
                    }

                    results.append((nodeId: nodeId, text: text))
                    totalTokens += tokens

                    // Bump hotness and update last accessed time
                    try db.execute(
                        sql: """
                        UPDATE lcm_nodes
                        SET hotness = MIN(hotness + ?, 1.0),
                            lastAccessedAt = ?
                        WHERE nodeId = ?
                        """,
                        arguments: [CIMSDefaults.hotnessAccessBump, now, nodeId],
                    )
                }

                return ExpansionResult(
                    nodes: results,
                    totalTokens: totalTokens,
                    truncated: truncated,
                )
            }
        } catch {
            print("[MemoryStore] expand error: \(error)")
            return ExpansionResult(nodes: [], totalTokens: 0, truncated: false)
        }
    }

    // MARK: - Delegation

    /// Create a scoped, time-limited read grant for a worker.
    ///
    /// The grant expires after ``CIMSDefaults/delegationGrantTTL`` and restricts
    /// the worker to the specified conversations and operations. The grant ID is
    /// a UUID string.
    ///
    /// - Parameter scope: The scope and constraints for the grant.
    /// - Returns: The created delegation grant.
    public func createDelegationGrant(scope: DelegationScope) async -> DelegationGrant {
        let grantId = UUID().uuidString
        let now = Date()
        let expiresAt = now + TimeInterval(CIMSDefaults.delegationGrantTTL.components.seconds)
        let tokenCap = scope.tokenCap ?? CIMSDefaults.workerDefaultBudget

        let scopeJSON = switch scope.conversationScope {
        case .all:
            "\"*\""
        case let .conversations(ids):
            "[\(ids.map { "\($0)" }.joined(separator: ","))]"
        }

        let opsJSON = "[\(scope.operations.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]"
        let nowString = Self.formatDate(now)
        let expiresString = Self.formatDate(expiresAt)

        do {
            try await db.dbPool.write { db in
                let record = DelegationGrantRecord(
                    grantId: grantId,
                    conversationScope: scopeJSON,
                    tokenCap: tokenCap,
                    tokensUsed: 0,
                    operations: opsJSON,
                    createdAt: nowString,
                    expiresAt: expiresString,
                    revokedAt: nil,
                    workerRunId: nil,
                )
                try record.insert(db)
            }
        } catch {
            print("[MemoryStore] createDelegationGrant error: \(error)")
        }

        return DelegationGrant(
            grantId: grantId,
            conversationScope: scope.conversationScope,
            tokenCap: tokenCap,
            tokensUsed: 0,
            operations: scope.operations,
            createdAt: now,
            expiresAt: expiresAt,
            revokedAt: nil,
            workerRunId: nil,
        )
    }

    /// Revoke a delegation grant by setting its `revokedAt` timestamp.
    ///
    /// - Parameter grantId: The grant to revoke.
    public func revokeDelegationGrant(_ grantId: GrantID) async {
        let now = Self.formatDate(Date())
        do {
            try await db.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE delegation_grants SET revokedAt = ? WHERE grantId = ?",
                    arguments: [now, grantId],
                )
            }
        } catch {
            print("[MemoryStore] revokeDelegationGrant error: \(error)")
        }
    }

    // MARK: - Compaction

    /// Check if incremental compaction is needed and run a pressure-gated pass if so.
    ///
    /// Called after each turn. Checks frontier token count against ``CIMSDefaults/softThreshold``
    /// (300K tokens). If exceeded, delegates to ``DAGCompactor/pressureGatedCompaction(conversationId:targetTokens:protectedTailCount:maxPasses:)``
    /// which runs a leaf pass followed by depth-ascending condensed passes until below threshold.
    ///
    /// Does nothing if the compactor has not been injected via
    /// ``setOfflineComponents(compactor:coldStorage:bumpDetector:)``.
    public func compactIfNeeded() async {
        guard let compactor else { return }

        do {
            let softThreshold = await configStore?.getInt(.contextSoftThreshold) ?? CIMSDefaults.softThreshold
            let protectedTail = await configStore?.getInt(.protectedTailCount) ?? CIMSDefaults.protectedTailCount
            let maxPasses = await configStore?.getInt(.contextMaxPassesPerTurn) ?? 5

            let frontierTokens = try await compactor.frontierTokenCount(conversationId: 1)
            if frontierTokens <= softThreshold {
                Log.debug("memory", "Compaction check: \(frontierTokens) tok ≤ \(softThreshold) threshold — skipped")
                return
            }

            Log.info("memory", "Compaction triggered: \(frontierTokens) tok > \(softThreshold) threshold")
            let (leafResult, condensedCreated) = try await compactor.pressureGatedCompaction(
                conversationId: 1,
                targetTokens: softThreshold,
                protectedTailCount: protectedTail,
                maxPasses: maxPasses,
            )
            pendingPreCompressionProposals.append(contentsOf: leafResult.preCompressionProposals)

            if leafResult.summariesCreated > 0 || condensedCreated > 0 {
                Log.info("memory", "Compaction result: \(leafResult.summariesCreated) leaf, \(condensedCreated) condensed created")
            }
        } catch {
            Log.error("memory", "Compaction error: \(error)")
        }
    }

    /// Run a full compaction sweep using pressure-gated loops.
    ///
    /// Called during consolidation for thorough maintenance. Runs up to
    /// ``CIMSDefaults/maxCompactionSweeps`` pressure-gated passes, each performing
    /// leaf + depth-ascending condensed compaction. Stops early when the frontier
    /// drops below ``CIMSDefaults/softThreshold`` or no progress is made.
    ///
    /// Does nothing if the compactor has not been injected.
    public func compactFull() async {
        guard let compactor else { return }

        do {
            let softThreshold = await configStore?.getInt(.contextSoftThreshold) ?? CIMSDefaults.softThreshold
            let protectedTail = await configStore?.getInt(.protectedTailCount) ?? CIMSDefaults.protectedTailCount
            let maxPasses = await configStore?.getInt(.contextMaxPassesPerTurn) ?? 5

            for _ in 0 ..< CIMSDefaults.maxCompactionSweeps {
                let frontierTokens = try await compactor.frontierTokenCount(conversationId: 1)
                guard frontierTokens > softThreshold else { break }

                let (leafResult, condensedCreated) = try await compactor.pressureGatedCompaction(
                    conversationId: 1,
                    targetTokens: softThreshold,
                    protectedTailCount: protectedTail,
                    maxPasses: maxPasses,
                )
                pendingPreCompressionProposals.append(contentsOf: leafResult.preCompressionProposals)

                if leafResult.summariesCreated == 0, condensedCreated == 0 { break }
            }
        } catch {
            print("[MemoryStore] compactFull error: \(error)")
        }
    }

    // MARK: - Maintenance

    /// Apply exponential decay to DAG node hotness values based on time since last access.
    ///
    /// Uses the formula `hotness = hotness * exp(-lambda * daysSinceLastAccess)` where
    /// `lambda = ln(2) / halfLifeDays`. With a 30-day half-life, a node untouched for
    /// 30 days decays to half its hotness; after 60 days, to a quarter; and so on.
    ///
    /// A floor of ``CIMSDefaults/hotnessDecayFloor`` (0.01) prevents nodes from decaying
    /// to exactly zero, which would make cold storage eligibility checks degenerate.
    /// Only non-cold nodes (`isCold = 0`) are decayed — cold nodes are already archived.
    ///
    /// Operates directly on the database via SQLite math functions for efficiency —
    /// no per-node round-trips.
    public func decayHotness() async {
        let now = Self.formatDate(Date())
        let halfLife = CIMSDefaults.hotnessDecayHalfLifeDays
        let lambda = log(2.0) / halfLife
        let floor = CIMSDefaults.hotnessDecayFloor

        do {
            try await db.dbPool.write { db in
                // Compute days since last access using julianday difference,
                // then apply exponential decay with a floor.
                try db.execute(
                    sql: """
                    UPDATE lcm_nodes
                    SET hotness = MAX(
                            hotness * EXP(-? * (julianday(?) - julianday(lastAccessedAt))),
                            ?
                        )
                    WHERE isCold = 0
                      AND lastAccessedAt < ?
                    """,
                    arguments: [lambda, now, floor, now],
                )
            }
        } catch {
            print("[MemoryStore] decayHotness error: \(error)")
        }
    }

    /// Demote cold nodes to compressed storage.
    ///
    /// Delegates to ``ColdStorage/demoteEligibleNodes()`` which compresses `canonicalText`
    /// for nodes with `hotness < 0.1` and `lastAccessedAt` older than 30 days.
    ///
    /// Does nothing if cold storage has not been injected.
    public func demoteColdNodes() async {
        guard let coldStorage else { return }

        do {
            try await coldStorage.demoteEligibleNodes()
        } catch {
            print("[MemoryStore] demoteColdNodes error: \(error)")
        }
    }

    /// Scan for reminiscence bumps — moments where understanding shifted.
    ///
    /// Delegates to ``BumpDetector/scanForBumps(since:)`` which examines recent nodes
    /// for correction patterns, emotional intensity, novel entity introductions, and
    /// high-salience topic shifts.
    ///
    /// - Parameter since: Only scan nodes created after this date.
    /// - Returns: Nodes flagged for claim extraction, or an empty array if the bump
    ///   detector has not been injected.
    public func scanForBumps(since: Date) async -> [BumpCandidate] {
        guard let bumpDetector else { return [] }

        do {
            return try await bumpDetector.scanForBumps(since: since)
        } catch {
            print("[MemoryStore] scanForBumps error: \(error)")
            return []
        }
    }

    /// Consume and return all pending pre-compression consolidation proposals.
    ///
    /// Pre-compression proposals are extracted by ``DAGCompactor`` from high-salience
    /// nodes during leaf passes, before their content is summarized. This method drains
    /// the accumulated proposals so ``ConsolidationEngine`` can merge them into the
    /// identity and mirror stores.
    ///
    /// - Returns: All accumulated proposals since the last call. Returns an empty array
    ///   if no proposals have been collected.
    public func consumePreCompressionProposals() -> [ConsolidationProposal] {
        let proposals = pendingPreCompressionProposals
        pendingPreCompressionProposals = []
        return proposals
    }

    // MARK: - Assembly Support

    /// Fetch the last N raw messages for a conversation (the fresh tail).
    ///
    /// The fresh tail is a hard invariant: these messages are never compacted.
    /// Messages are returned ordered by creation time (oldest first).
    ///
    /// - Parameters:
    ///   - count: Number of messages to fetch.
    ///   - conversationId: The conversation to fetch from.
    /// - Returns: Messages ordered by creation time, oldest first.
    public func freshTail(count: Int, for conversationId: ConversationID) async -> [StoredMessage] {
        do {
            return try await db.dbPool.read { db in
                let records = try MessageRecord
                    .filter(Column("conversationId") == conversationId)
                    .order(Column("id").desc)
                    .limit(count)
                    .fetchAll(db)
                    .reversed()

                return try Self.buildStoredMessages(from: Array(records), in: db)
            }
        } catch {
            print("[MemoryStore] freshTail error: \(error)")
            return []
        }
    }

    /// Fetch summary nodes for context assembly, respecting a token budget.
    ///
    /// Returns summary nodes (depth > 0) ordered oldest to newest, accumulating
    /// until the token budget is reached. Oldest summaries are included first since
    /// they'll be dropped first if the context overflows.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation to fetch summaries for.
    ///   - tokenBudget: Maximum total tokens for summaries.
    /// - Returns: Summary nodes ordered oldest to newest.
    public func summaries(for conversationId: ConversationID, tokenBudget: Int) async -> [SummaryNode] {
        do {
            return try await db.dbPool.read { db in
                let records = try LCMNodeRecord
                    .filter(Column("conversationId") == conversationId)
                    .filter(Column("depth") > 0)
                    .order(Column("earliestAt").asc)
                    .fetchAll(db)

                var result: [SummaryNode] = []
                var tokens = 0

                for record in records {
                    if tokens + record.tokenCount > tokenBudget {
                        break
                    }
                    tokens += record.tokenCount

                    result.append(SummaryNode(
                        nodeId: record.nodeId,
                        kind: NodeKind(rawValue: record.kind) ?? .rawTurn,
                        depth: record.depth,
                        tokenCount: record.tokenCount,
                        summaryText: record.summaryText ?? "",
                        expandFooter: record.expandFooter,
                        earliestAt: MemoryStore.parseDate(record.earliestAt),
                        latestAt: MemoryStore.parseDate(record.latestAt),
                        salienceScore: Float(record.salienceScore),
                        descendantCount: 0,
                        parentIds: [],
                    ))
                }

                return result
            }
        } catch {
            print("[MemoryStore] summaries error: \(error)")
            return []
        }
    }

    // MARK: - Large File Retrieval

    /// Retrieve the full content of an intercepted large file by its file ID.
    ///
    /// Reads the content from the filesystem path stored in the ``LargeFileRecord``.
    /// Returns `nil` if the file ID doesn't exist in the database or the file cannot be read.
    ///
    /// - Parameter id: The file ID (e.g., `"file_<uuid>"`).
    /// - Returns: The original full content of the intercepted file, or `nil` if not found.
    public func retrieveLargeFile(id: String) async throws -> String? {
        try await db.dbPool.read { db in
            guard let record = try LargeFileRecord.fetchOne(db, key: id) else {
                return nil
            }
            return try String(contentsOfFile: record.storagePath, encoding: .utf8)
        }
    }

    // MARK: - Hotness Tracking

    /// Bump hotness for a set of node IDs, incrementing by ``CIMSDefaults/hotnessAccessBump``
    /// and capping at 1.0. Also updates `lastAccessedAt` to the current time.
    ///
    /// Operates as a single bulk SQL UPDATE for efficiency — no per-node round-trips.
    /// Silently ignores errors since hotness tracking is best-effort and should never
    /// block the caller's primary operation.
    ///
    /// - Parameter nodeIds: The node IDs whose hotness should be bumped.
    private func bumpHotness(for nodeIds: [NodeID]) async {
        guard !nodeIds.isEmpty else { return }

        let now = Self.formatDate(Date())
        let bump = CIMSDefaults.hotnessAccessBump
        let placeholders = nodeIds.map { _ in "?" }.joined(separator: ",")

        do {
            try await db.dbPool.write { db in
                var arguments: [any DatabaseValueConvertible] = [bump, now]
                arguments.append(contentsOf: nodeIds)

                try db.execute(
                    sql: """
                    UPDATE lcm_nodes
                    SET hotness = MIN(hotness + ?, 1.0),
                        lastAccessedAt = ?
                    WHERE nodeId IN (\(placeholders))
                    """,
                    arguments: StatementArguments(arguments),
                )
            }
        } catch {
            print("[MemoryStore] bumpHotness error: \(error)")
        }
    }

    // MARK: - Internal Helpers

    /// Compute a filesystem path for storing large file content.
    ///
    /// Files are stored in a `cims-large-files` subdirectory of the system's temporary directory,
    /// named by file ID. The directory is created if it doesn't exist.
    ///
    /// - Parameter fileId: The unique file identifier.
    /// - Returns: Absolute path where the file content should be written.
    nonisolated static func largeFileStoragePath(for fileId: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cims-large-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileId).path
    }

    /// Generate a brief summary of large file content for inline display.
    ///
    /// Takes the first ~200 characters and appends an ellipsis.
    ///
    /// - Parameter content: The full content to summarize.
    /// - Returns: A truncated summary string.
    nonisolated static func makeLargeFileSummary(_ content: String) -> String {
        if content.count <= 200 {
            return content
        }
        return String(content.prefix(200)) + "..."
    }

    /// Format a `Date` as an ISO 8601 string with fractional seconds.
    ///
    /// Uses a thread-local formatter to avoid allocation on every call while remaining
    /// safe for concurrent use from the GRDB writer/reader queues.
    nonisolated static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Convert message records to StoredMessages with their parts loaded.
    ///
    /// Loads all `message_parts` for the given records in a single batch query,
    /// then groups them by message ID. This is the canonical way to build
    /// `StoredMessage` arrays — avoids the `parts: []` anti-pattern that causes
    /// tool results to be invisible in the assembled context.
    nonisolated static func buildStoredMessages(
        from records: [MessageRecord],
        in db: Database,
    ) throws -> [StoredMessage] {
        let messageIds = records.compactMap(\.id)
        let allParts: [MessagePartRecord] = messageIds.isEmpty ? [] : try MessagePartRecord
            .filter(messageIds.contains(Column("messageId")))
            .order(Column("messageId").asc, Column("ordinal").asc)
            .fetchAll(db)

        var partsByMessageId: [Int64: [MessagePart]] = [:]
        for part in allParts {
            let mp = MessagePart(
                kind: MessagePartKind(rawValue: part.partKind) ?? .text,
                ordinal: part.ordinal,
                content: part.content,
                metadata: part.metadata,
            )
            partsByMessageId[part.messageId, default: []].append(mp)
        }

        return records.map { record in
            StoredMessage(
                id: record.id!,
                conversationId: record.conversationId,
                role: MessageRole(rawValue: record.role) ?? .user,
                content: record.content,
                tokenEstimate: record.tokenEstimate,
                salienceScore: record.salienceScore.map { Float($0) },
                createdAt: MemoryStore.parseDate(record.createdAt),
                parts: partsByMessageId[record.id!] ?? [],
            )
        }
    }

    /// Parse an ISO 8601 string back to a `Date`.
    nonisolated static func parseDate(_ string: String) -> Date {
        // ISO 8601 with fractional seconds (daemon-generated: 2026-03-15T19:08:02.349Z)
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: string) { return d }

        // ISO 8601 without fractional seconds
        if let d = ISO8601DateFormatter().date(from: string) { return d }

        // Plain format (migrated: 2026-03-15 16:35:25)
        let plain = DateFormatter()
        plain.dateFormat = "yyyy-MM-dd HH:mm:ss"
        plain.timeZone = TimeZone(identifier: "UTC")
        if let d = plain.date(from: string) { return d }

        return Date()
    }

    /// Generate a deterministic node ID from canonical text.
    ///
    /// Format: `"node_" + SHA-256(canonicalText).prefix(16)`.
    ///
    /// - Parameter text: The canonical text to hash.
    /// - Returns: A deterministic node ID string.
    nonisolated static func makeNodeId(from text: String) -> NodeID {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        let hexPrefix = digest.prefix(8).map { unsafe String(format: "%02x", $0) }.joined()
        return "node_\(hexPrefix)"
    }

    /// Compute the full SHA-256 hex string of the given text.
    ///
    /// - Parameter text: The text to hash.
    /// - Returns: Full hexadecimal SHA-256 digest.
    nonisolated static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { unsafe String(format: "%02x", $0) }.joined()
    }

    /// Escape a string for safe embedding in a JSON string literal.
    ///
    /// Handles backslashes, double quotes, and control characters.
    nonisolated static func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Escape a query string for safe use in FTS5 MATCH expressions.
    ///
    /// FTS5 has special syntax characters (`*`, `"`, `(`, `)`, `+`, `-`, `^`, `:`).
    /// This wraps each whitespace-separated token in double quotes to treat it as a literal.
    ///
    /// - Parameter query: The raw query string.
    /// - Returns: An escaped query safe for FTS5 MATCH.
    nonisolated static func escapeFTS5Query(_ query: String) -> String {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return "" }

        return tokens.map { token in
            let cleaned = token.replacingOccurrences(of: "\"", with: "")
            guard !cleaned.isEmpty else { return "" }
            return "\"\(cleaned)\""
        }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}
