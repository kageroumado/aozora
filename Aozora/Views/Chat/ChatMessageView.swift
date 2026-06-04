import AppKit
import SwiftUI

/// Single message bubble in the chat view.
///
/// Renders user messages right-aligned with accent background and
/// assistant messages left-aligned with neutral background. Content
/// blocks are rendered sequentially — text and tool calls interleaved
/// in arrival order.
///
/// -> Spec: Chat UI Design Chat System
struct ChatMessageView: View {
    /// The message to display.
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                ForEach(message.blocks) { block in
                    ContentBlockView(block: block, isUser: message.role == .user)
                }

                // Hold message
                if let hold = message.holdMessage {
                    Text(hold)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // Status line
                statusView
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .user ? "Your message" : "Assistant message")
    }

    /// Status indicator below the message bubble showing delivery state.
    @ViewBuilder
    private var statusView: some View {
        switch message.status {
        case .sending:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Sending...").font(.caption2).foregroundStyle(.secondary)
            }
        case .streaming:
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Streaming").font(.caption2).foregroundStyle(.secondary)
            }
        case .complete:
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case let .error(msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

// MARK: - Content Block View

/// Routes a single content block to the appropriate specialized view.
///
/// Extracted from the `ForEach` body in ``ChatMessageView`` so each block
/// gets its own observation scope, preventing unnecessary redraws.
private struct ContentBlockView: View {
    let block: ChatMessage.ContentBlock
    let isUser: Bool

    var body: some View {
        switch block.kind {
        case .text:
            TextBlockView(block: block, role: isUser ? .user : .assistant)
        case .toolCall:
            if let tool = block.toolCall {
                ToolCallRow(tool: tool)
            }
        case .image:
            ImageBlockView(block: block, role: isUser ? .user : .assistant)
        }
    }
}

// MARK: - Text Block View

/// Renders a single text content block with truncation support.
private struct TextBlockView: View {
    let block: ChatMessage.ContentBlock
    let role: ChatMessage.MessageRole

    /// Maximum characters before truncation.
    private static let truncationThreshold = 1_500

    /// Whether the full text is shown (for long blocks).
    @State private var isExpanded = false

    /// The text to display — truncated unless expanded.
    private var displayText: String {
        if isExpanded || block.text.count <= Self.truncationThreshold {
            return block.text
        }
        return String(block.text.prefix(Self.truncationThreshold))
    }

    /// Whether the block exceeds the truncation threshold.
    private var isTruncated: Bool {
        block.text.count > Self.truncationThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text: displayText)

            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Show less" : "Show more...")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            role == .user
                ? Color.accentColor.opacity(0.15)
                : Color.primary.opacity(0.06),
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Image Block View

/// Renders a single image content block with rounded corners.
private struct ImageBlockView: View {
    let block: ChatMessage.ContentBlock
    let role: ChatMessage.MessageRole

    var body: some View {
        if let data = block.imageData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 300, maxHeight: 250)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Tool Call Row

/// Compact inline display of a single tool call with expandable result.
struct ToolCallRow: View {
    let tool: ToolCallInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if tool.resultContent != nil {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 4) {
                    statusIcon
                    Text(tool.shortDescription)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if tool.resultContent != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded, let result = tool.resultContent {
                ToolResultView(content: result, isError: tool.isError)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch tool.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 10))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 10))
        case .backgrounded:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
                .font(.system(size: 10))
        }
    }
}

// MARK: - Tool Result View

/// Expandable code-formatted view for a tool result.
struct ToolResultView: View {
    let content: String
    let isError: Bool

    @State private var isExpanded = false

    /// Max characters to show in preview.
    private static let previewLength = 120

    private var isLong: Bool {
        content.count > Self.previewLength
    }

    private var displayText: String {
        if isExpanded || !isLong {
            return content
        }
        return String(content.prefix(Self.previewLength)) + "..."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(isError ? .red.opacity(0.8) : .secondary)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 4)

            if isLong {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Collapse" : "Show full output")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isError ? Color.red.opacity(0.06) : Color.primary.opacity(0.03)),
        )
    }
}
