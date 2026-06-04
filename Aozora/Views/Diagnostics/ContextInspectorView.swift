import AozoraCore
import SwiftUI

/// Real-time diagnostic view for the CIMS context window.
///
/// Displays the assembled context broken down by section, with token counts, utilization
/// bars, and expandable content previews. Also shows coordinator state (allostasis,
/// chronoception, queue depth) and memory statistics.
///
/// Intended for development and debugging — helps verify that context assembly is working
/// correctly and that budget allocation is reasonable.
///
/// **Usage:**
/// ```swift
/// ContextInspectorView(gateway: cimsGateway)
/// ```
struct ContextInspectorView: View {
    /// The CIMS gateway to inspect.
    let gateway: CIMSGateway

    /// The user key to inspect mirror claims for.
    var userKey: UserKey = "default"

    /// The current snapshot being displayed.
    @State private var snapshot: ContextSnapshot = .empty

    /// Whether a refresh is in progress.
    @State private var isRefreshing = false

    /// Auto-refresh timer interval in seconds. 0 = disabled.
    @State private var autoRefreshInterval: Double = 0

    /// The currently expanded section (for content preview).
    @State private var expandedSection: ContextSectionKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                coordinatorStateSection
                contextBudgetSection
                sectionBreakdownList
                memoryStatsSection
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 500)
        .task {
            await refresh()
        }
        .task(id: autoRefreshInterval) {
            guard autoRefreshInterval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(autoRefreshInterval))
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Context Inspector")
                    .font(.title2.bold())

                Text("Captured \(snapshot.capturedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Picker("Auto", selection: $autoRefreshInterval) {
                    Text("Off").tag(0.0)
                    Text("1s").tag(1.0)
                    Text("5s").tag(5.0)
                    Text("10s").tag(10.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        }
    }

    // MARK: - Coordinator State

    private var coordinatorStateSection: some View {
        GroupBox("Coordinator State") {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                stateCard(
                    title: "Allostasis",
                    value: snapshot.allostasisMode.rawValue.capitalized,
                    color: allostasisColor(snapshot.allostasisMode),
                )

                stateCard(
                    title: "Temporal Mode",
                    value: snapshot.temporalMode.rawValue
                        .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                        .capitalized,
                    color: .blue,
                )

                stateCard(
                    title: "Pressure",
                    value: "\(Int(snapshot.pressure * 100))%",
                    color: pressureColor(snapshot.pressure),
                )

                stateCard(
                    title: "Queue Depth",
                    value: "\(snapshot.queueDepth)",
                    color: snapshot.queueDepth > 0 ? .orange : .green,
                )

                stateCard(
                    title: "Active Turns",
                    value: "\(snapshot.activeTurns)",
                    color: snapshot.activeTurns > 0 ? .blue : .secondary,
                )

                stateCard(
                    title: "Context Budget",
                    value: formatTokenCount(snapshot.tokenBudget),
                    color: .purple,
                )
            }
        }
    }

    // MARK: - Context Budget

    private var contextBudgetSection: some View {
        GroupBox("Token Budget") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(formatTokenCount(snapshot.totalTokens)) / \(formatTokenCount(snapshot.tokenBudget))")
                        .font(.headline.monospacedDigit())

                    Spacer()

                    Text("\(Int(snapshot.utilization * 100))% utilized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(utilizationGradient)
                            .frame(width: geometry.size.width * min(snapshot.utilization, 1.0))
                    }
                }
                .frame(height: 8)

                // Section breakdown bar
                if !snapshot.sections.isEmpty {
                    GeometryReader { geometry in
                        HStack(spacing: 1) {
                            ForEach(snapshot.sections) { section in
                                let fraction = snapshot.totalTokens > 0
                                    ? CGFloat(section.tokenCount) / CGFloat(snapshot.totalTokens)
                                    : 0

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(sectionColor(section.kind))
                                    .frame(width: max(2, geometry.size.width * fraction))
                                    .help("\(section.displayName): \(formatTokenCount(section.tokenCount))")
                            }
                        }
                    }
                    .frame(height: 16)
                }
            }
        }
    }

    // MARK: - Section Breakdown

    private var sectionBreakdownList: some View {
        GroupBox("Context Sections") {
            VStack(spacing: 0) {
                ForEach(snapshot.sections) { section in
                    sectionRow(section)

                    if section.id != snapshot.sections.last?.id {
                        Divider()
                    }
                }

                if snapshot.sections.isEmpty {
                    Text("No context assembled yet")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
    }

    private func sectionRow(_ section: ContextSnapshot.SectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedSection == section.kind {
                        expandedSection = nil
                    } else {
                        expandedSection = section.kind
                    }
                }
            } label: {
                HStack {
                    Circle()
                        .fill(sectionColor(section.kind))
                        .frame(width: 8, height: 8)

                    Text(section.displayName)
                        .font(.body.weight(.medium))

                    if section.isTruncated {
                        Image(systemName: "scissors")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Text(formatTokenCount(section.tokenCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: expandedSection == section.kind ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expandedSection == section.kind {
                ScrollView {
                    Text(section.content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    // MARK: - Memory Stats

    private var memoryStatsSection: some View {
        GroupBox("Memory") {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                statCard(title: "Fresh Tail", value: "\(snapshot.freshTailCount)")
                statCard(title: "Summaries", value: "\(snapshot.summaryCount)")
                statCard(title: "Identity Claims", value: "\(snapshot.identityClaimCount)")
                statCard(title: "Mirror Claims", value: "\(snapshot.mirrorClaimCount)")
            }
        }
    }

    // MARK: - Helpers

    private func refresh() async {
        isRefreshing = true
        snapshot = await gateway.diagnosticSnapshot(for: userKey)
        isRefreshing = false
    }

    private func stateCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold().monospacedDigit())

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    // MARK: - Colors

    private func sectionColor(_ kind: ContextSectionKind) -> Color {
        switch kind {
        case .systemPrompt: .purple
        case .identity: .blue
        case .mirror: .cyan
        case .summaries: .green
        case .cognitiveState: .orange
        case .chronoception: .yellow
        case .bridgedContext: .indigo
        case .freshTail: .pink
        case .currentMessage: .red
        case .stableSummaries: .green
        case .recentSummaries: .mint
        case .temporalGrounding: .yellow
        }
    }

    private func allostasisColor(_ mode: AllostasisMode) -> Color {
        switch mode {
        case .exploratory: .green
        case .balanced: .blue
        case .conservative: .orange
        case .recovery: .red
        }
    }

    private func pressureColor(_ pressure: Float) -> Color {
        switch pressure {
        case ..<0.3: .green
        case ..<0.6: .yellow
        case ..<0.8: .orange
        default: .red
        }
    }

    private var utilizationGradient: AnyShapeStyle {
        let utilization = snapshot.utilization
        if utilization < 0.6 {
            return AnyShapeStyle(.green.gradient)
        } else if utilization < 0.8 {
            return AnyShapeStyle(.yellow.gradient)
        } else if utilization < 0.95 {
            return AnyShapeStyle(.orange.gradient)
        } else {
            return AnyShapeStyle(.red.gradient)
        }
    }
}
