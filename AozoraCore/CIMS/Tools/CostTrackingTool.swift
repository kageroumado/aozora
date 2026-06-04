import Foundation

/// Reports token usage and estimated API costs for the current session.
///
/// `CostTrackingTool` queries ``InsightsEngine`` for aggregate token counts,
/// looks up the currently-configured executive model via ``ConfigStore``, and
/// passes both to ``ModelCatalog`` to produce a USD cost estimate.
///
/// The tool is read-only and has no side effects. It is safe to call at any time
/// during a session without affecting state.
///
/// Registered in ``CIMSGateway`` when a ``ConfigStore`` is provided.
public nonisolated struct CostTrackingTool: ToolExecutable {
    /// The CIMS database used to query usage statistics.
    public let db: CIMSDatabase

    /// The config store used to look up the active executive model name.
    public let configStore: ConfigStore

    public let name = "costs"

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "costs",
            description: "Show token usage and estimated costs for the current session",
            parameters: [],
        )
    }

    /// Creates a cost tracking tool.
    ///
    /// - Parameters:
    ///   - db: The ``CIMSDatabase`` to query for usage data.
    ///   - configStore: The ``ConfigStore`` providing the active model name.
    public init(db: CIMSDatabase, configStore: ConfigStore) {
        self.db = db
        self.configStore = configStore
    }

    public func execute(parameters _: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let insights = InsightsEngine(db: db)
        let usage = try await insights.computeInsights()

        let model = await configStore.get(.executiveModel)
        let estimatedCost = ModelCatalog.estimateCost(
            model: model,
            inputTokens: usage.totalTokensEstimated,
            outputTokens: 0,
        )

        let pricing = ModelCatalog.pricing(for: model)
        let knownNote = pricing.isKnown ? "" : " (pricing unknown — using $0)"

        let report = """
        Token Usage & Cost Estimate
        ===========================
        Model:        \(model)\(knownNote)
        Turns:        \(usage.totalTurns)
        Conversations:\(usage.totalConversations)
        Tokens (est): \(formatTokens(usage.totalTokensEstimated))
        Avg/turn:     \(formatTokens(usage.averageTokensPerTurn))
        
        Cost Estimate (input only)
        --------------------------
        Input rate:   $\(String(format: "%.4f", pricing.inputPerMillion)) / 1M tokens
        Estimated:    $\(String(format: "%.4f", estimatedCost))
        
        Note: Output token count is not tracked separately.
              Actual cost may differ based on output volume and cache hits.
        """

        return .success(report)
    }

    // MARK: - Formatting

    /// Format a token count with comma separators for readability.
    ///
    /// - Parameter count: Token count to format.
    /// - Returns: A human-readable string (e.g., "1,234,567").
    private func formatTokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
