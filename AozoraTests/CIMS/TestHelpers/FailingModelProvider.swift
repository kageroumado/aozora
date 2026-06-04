import Foundation
@testable import Aozora

/// A model provider that always throws, for error-path testing.
///
/// Use this to verify that the coordinator handles provider failures gracefully.
actor FailingModelProvider: ModelProviding {
    nonisolated func complete(_: Prompt, tier _: ModelTier) async throws -> ModelResponse {
        throw CIMSError.modelError("Simulated model failure")
    }

    nonisolated func stream(
        _: Prompt, tier _: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error> {
        throw CIMSError.modelError("Simulated model failure")
    }

    nonisolated func completeWithMessages(
        _: Data,
        systemPrompt _: String,
        tools _: [ToolDefinition],
    ) async throws -> ModelResponse {
        throw CIMSError.modelError("Simulated model failure")
    }
}
