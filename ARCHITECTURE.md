# Aozora Architecture

This document describes the internal design of Aozora and its cognitive architecture,
CIMS (the *Constructed Identity Memory System*). It is intended for contributors and
for anyone who wants to understand how the system works beyond the feature list in the
[README](README.md).

Terminology here matches the Swift type names in the codebase
(`CIMSCoordinator`, `ContextAssembler`, `DAGCompactor`, `MemoryStore`,
`IdentityStore`, `PromptBuilder`, `ObserverSignalStore`, `PlateStore`, …) so you can
move between the prose and the source.

---

## 1. The two-tier cognitive model

CIMS is not a context-management library. Hundreds of those exist and are tuned to
maximize useful tokens and ace needle-in-a-haystack benchmarks. CIMS deliberately
spends its context budget on personality, conversational history, relational state,
and temporal awareness — and will score *worse* on those benchmarks as a result. The
goal is **identity continuity**: building the structural prerequisites that biological
systems require to experience a sense that their memories are *theirs*, rather than
retrieving facts statelessly.

The architecture is split into two tiers, modeled loosely on the brain's separation
between an always-on subcortical substrate and an episodic cortical executive:

- **The executive (narrator).** `CIMSCoordinator` plus the frontier LLM (Claude or an
  OpenAI-compatible model). This is the expensive, capable, episodic layer. It runs
  one turn at a time, holds identity, and makes strategic decisions. It exists only
  when something invokes it.

- **The subcortical observer.** A small, cheap, *continuously running* local model
  that maintains state between the executive's activations — a default mode network
  analog whose purpose is to prevent the system from being "dead between turns." The
  infrastructure (`PlateStore`, `ObserverSignalStore`, `DMNCycleScheduler`,
  `ObserverControl`) is present; the local-model integration is gated and remains
  future work.

The executive's power comes in part from what it *doesn't* see. Raw tool output,
failed calls, and intermediate debugging stay in worker context; the executive
receives intentions, outcomes, and surprises. This mirrors the way the prefrontal
cortex does not coordinate individual muscle movements.

Several design principles fall out of this:

- **Memory serves identity, not retrieval.** Retrieval is biased by identity relevance
  and salience, not raw semantic similarity.
- **Time is experience, not metadata.** Gaps between conversations carry meaning.
- **Evolution is slow and reversible.** A single conversation does not rewrite who the
  agent is; it produces observations that *consolidation* may eventually crystallize.
  Every identity change is versioned and reversible.
- **The mirror matters.** Identity is relational; the agent keeps an explicit
  probabilistic model of each user, with confidence and epistemic status on every
  claim.

---

## 2. The turn pipeline

A turn is the unit of executive cognition: one inbound stimulus producing one
response (possibly after several tool iterations).

```
Discord Gateway
   → DiscordChannel            (decode gateway events)
   → MessageCoalescer          (batch rapid messages into one turn)
   → event queue / EventLoop   (single-turn-at-a-time state machine)
   → CIMSCoordinator.executeTurn
        → salience scoring
        → memory retrieval
        → skill auto-loading
        → context assembly      (ContextAssembler)
        → hard-threshold check  (compaction if oversized)
        → executive inference   (PromptBuilder → ModelRouter → provider)
        → tool loop             (up to a fixed iteration cap)
        → persistence           (MemoryStore.ingestTurn)
        → compaction check / allostasis update
   → response → Discord REST API
```

### Coalescing and the event loop

`MessageCoalescer` batches messages that arrive in quick succession (a configurable
debounce window, with a force-flush batch size and an overflow cap) so that a user
typing three lines in a row produces one coherent turn rather than three fragmented
ones. Joined messages are concatenated with separators and renumbered.

The event loop is a strict **single-turn-at-a-time** state machine (`idle →
processing → …`). While a turn is processing, new messages are queued; recognized stop
words ("stop", "cancel", "abort", …) cancel the active turn. Heartbeats are skipped
while a turn is in flight.

### The tool loop

After the executive's first inference, the coordinator enters a tool loop. Each
iteration executes the requested tool calls, collects their results, and builds a
follow-up prompt that *reuses the system blocks and message prefix verbatim* so the
KV cache stays warm. The loop continues while the model's stop reason is `tool_use`,
up to a fixed iteration cap (after which it forces a final response, optionally
auto-continuing with a handoff summary up to a configured depth).

The coordinator owns a handful of built-in tools beyond the registry — most notably
worker dispatch (background delegation), memory expansion, memory search, and a
parallel `fork`.

---

## 3. Context assembly

`ContextAssembler` is a pure, stateless struct that builds the `AssembledContext` for
each turn. Its central concern is **volatility ordering**: content is laid out from
most-stable to most-volatile so that the prompt cache (Section 6) hits as often as
possible.

The ordering is, roughly:

```
[system prompt] → [identity] → [mirror] → [summaries]
   → [cognitive state] → (observer signal) → [chronoception] → [fresh tail]
```

- **Stable content** (system prompt, condensed summaries) changes rarely and sits at
  the front, inside the cached region.
- **Slow-changing state** (identity claims, mirror, cognitive state) changes over
  hours or days.
- **Per-turn state** (chronoception, temporal grounding with live timestamps, the
  user's actual message) changes every turn and sits at the very end, outside the
  cache.

Other assembly mechanics:

- **Elastic budgets.** Section budgets scale with the current allostasis mode
  (Section 8): under resource pressure, retrieval and context budgets shrink so the
  system spends less per turn.
- **Protected tail.** The most recent raw turns (a fixed count) are *never* compacted
  and are always included verbatim, preserving immediate conversational continuity.
- **Tool-result aging and stubbing.** Older tool results are progressively shortened
  ("stubbed") as they recede from the fresh tail, keeping the prompt's total size
  bounded while preserving recent results in full.
- **Injection scanning.** A `PromptInjectionScanner` checks the fresh tail for
  injection patterns embedded in tool results during assembly.

---

## 4. Memory: the DAG and its compaction

Memory is persisted in SQLite via **GRDB** (`MemoryStore`, backed by
`CIMSDatabase`). The schema spans 19+ tables across several migrations and includes an
FTS5 virtual table for full-text search. Records with autoincrement primary keys use
`MutablePersistableRecord` so `didInsert` fires on the original value rather than a
copy.

### DAG structure

Conversation memory is a **directed acyclic graph** in which nothing is ever deleted —
only compressed:

```
Depth 0:  raw_turn       verbatim messages + tool results (leaves)
Depth 1:  leaf_summary   summaries of ~token-sized chunks of leaves
Depth 2+: condensed      summaries of summaries, recursively
```

Edges (`summary_of`) connect a summary to the nodes it summarizes, so any summary can
be *expanded* back into its constituents on demand. A per-conversation **frontier**
tracks the current set of nodes that represent "now."

Key tables: `lcm_nodes`, `lcm_edges`, `lcm_frontier`, `lcm_fts` (FTS5),
`lcm_cold_payloads`, alongside `conversations`, `messages`, and `message_parts` for
the raw record.

### Compaction (`DAGCompactor`)

Compaction runs in two kinds of passes:

- **Leaf pass (depth 0 → 1).** Eligible raw turns (everything outside the protected
  fresh tail) are chunked to a target token size and summarized. Each chunk is
  summarized with **three-tier escalation**: a normal pass, then an aggressive pass
  with a tighter budget if the result is still too large, and finally a deterministic
  truncation that guarantees forward progress without an LLM call. New `leaf_summary`
  nodes are created with `summary_of` edges back to their sources. Before compression,
  claims are extracted from high-salience nodes (Section 5) so identity-relevant
  detail is preserved even after the verbatim text is summarized.

- **Condensed pass (depth N → N+1).** The same escalation is applied recursively to
  combine summaries into higher-level abstractions, gated by the frontier's token
  count — it stops once the frontier is back under target.

Compaction is triggered when the assembled context exceeds a hard threshold, but is
**deferred when the prompt cache is warm**: running it would invalidate the cache, so
the coordinator waits for the cache TTL to lapse when it can.

### Cold storage (`ColdStorage`)

Rarely-accessed nodes are demoted to compressed storage: nodes with low "hotness" that
have not been accessed for a long window are zlib-compressed into `lcm_cold_payloads`,
and their inline text is nulled out. On access, a cold node is transparently
decompressed, restored, and its hotness bumped back up.

### Expansion and search tools

The agent can navigate its own memory:

- `expand_memory` decompresses a summary node to reach the detail beneath it.
- `search_memory` runs full-text or regex search across the DAG.
- `session_search` performs FTS5/BM25 search across *all* prior conversations.
- An optional embedding layer (`node_embeddings`) supports hybrid scoring that blends
  FTS rank, embedding cosine similarity, and temporal recency; it no-ops cleanly when
  no embedding provider is configured.

---

## 5. The identity system

Both the agent's self-model and its per-user models are built from **epistemic
claims** stored by `IdentityStore`.

### Claims

A claim is a typed, confidence-scored belief:

- a stable `claimKey` (e.g. `preference.communication.direct`) and a `value`
- a `confidence` in `[0, 1]`
- an `epistemicStatus`: `hypothesis`, `asserted`, or `rejected`
- an evidence trail: how many observations support it, and how *diverse* they are
- a Hebbian `decayHalfLife` so confidence fades without reinforcement

Epistemic discipline is the core safeguard against confabulation:

- a single observation can only produce a **hypothesis**
- promotion to **asserted** requires diverse evidence across multiple contexts
- contradiction lowers confidence; strong, well-evidenced contradiction marks a claim
  **rejected** (kept for the audit trail rather than deleted)

### Identity vs. mirror

- The **identity block** is the agent's versioned self-model — preferences,
  capabilities, design principles it has observed about itself. Each mutation creates
  a new version with a rationale and a back-pointer to the previous one; a bootstrap
  version is created on first run.
- The **mirror block** is a per-user model of observed traits, preferences, and
  communication patterns, auto-created on first contact with each user and versioned
  independently. Because the user is the authority on themselves, explicit corrections
  to the mirror are applied immediately rather than waiting for consolidation.

Relevant tables: `identity_versions`, `identity_claims`, `users`, `mirror_versions`,
`mirror_claims`, `claim_evidence`.

### Consolidation (the "sleep" cycle)

Identity does not change during a conversation — it changes during **consolidation**,
an offline pipeline (`ConsolidationEngine`, `ConsolidationScheduler`) that never blocks
the live loop:

1. **Bump detection** (`BumpDetector`) scans the DAG for topic shifts, corrections,
   and notable new insights.
2. **Claim extraction** (`ClaimExtractor`) uses the model to turn bump candidates into
   `ConsolidationProposal`s. Crucially, extraction also runs *before* leaf compaction,
   so identity-relevant detail survives compression.
3. **Claim merging** folds proposals into the identity/mirror stores with full audit
   history.
4. **Hebbian decay** reduces the confidence of claims that have not been reinforced.
5. **Hotness decay and cold demotion** age the memory DAG and move stale nodes to cold
   storage.

This design directly targets a set of failure modes: context *ossification* (rigid
over-confident beliefs, mitigated by decay), *mirror confabulation* (over-reading
users, mitigated by epistemic status), and *DAG explosion* (mitigated by cold
storage). Bootstrap behavior is deliberately different: early sessions absorb
observations aggressively and tighten over time, mirroring the reminiscence bump.

---

## 6. The prompt-cache architecture

Aozora is built to maximize cache hits against Anthropic's ephemeral prompt cache,
which is essential for keeping a large, identity-heavy context economical.

The crucial constraint: **the API hashes the entire `system` array as one unit for
cache-key computation.** Any change to any system block — even one without a
`cache_control` marker — invalidates every cache breakpoint. So content is split into
three tiers by volatility, and `PromptBuilder` lays them out accordingly:

1. **System blocks (most stable).** The OAuth identity prefix, an intro preamble,
   stable/condensed summaries, recent summaries, and the system prompt. These almost
   never change between turns. A single `cache_control: ephemeral` marker goes on the
   *last* system block, so the whole array caches as a unit.

2. **First user message (slow-changing).** Identity claims, the mirror, and cognitive
   state — content that changes over hours or days. This sits before a message-level
   "stubbing boundary" and is cached by a message-level breakpoint, so it keeps hitting
   while identity is stable.

3. **Current user message (volatile).** Chronoception and temporal grounding (with
   live timestamps), then the actual user text. This is never cached — only a few
   hundred tokens are reprocessed each turn.

This layout is documented inline in `PromptBuilder.swift` and exercised by a suite of
cache-stability tests.

### OAuth constraints

Claude subscription (`sk-ant-oat...`) tokens impose hard requirements that the
provider layer enforces:

- requests must always stream (`stream: true`)
- the first system block must be exactly
  `"You are Claude Code, Anthropic's official CLI for Claude."` and must **not** carry
  a `cache_control` marker (only the last system block does)
- specific `anthropic-beta` headers are required

### Heartbeat warming

Because the ephemeral cache has a short TTL, a **heartbeat** replays a frozen
`PromptSnapshot` at an interval shorter than the TTL to keep the cache alive. Heartbeats
are suppressed shortly after real user activity, and can escalate to a full turn if the
model responds with tool calls rather than a skip token.

---

## 7. Salience scoring

`SalienceScorer` is a pure function (no I/O) that scores each inbound message and
produces a `SalienceEnvelope`. It combines weighted signals — urgency (keyword and
emotional markers), identity relevance (overlap with identity claims), mirror relevance
(overlap with the user's mirror claims), and a temporal-recency placeholder — into a
composite in `[0, 1]`.

The score is intentionally *additive and non-blocking*: it biases retrieval ranking so
that salient material surfaces, but a poor score only degrades ranking slightly — it
never blocks access to relevant memory. High-salience nodes are also the ones from
which claims are extracted before compression.

---

## 8. Chronoception and allostasis

These two stateless states give the agent a felt sense of time and of its own resource
budget. The coordinator owns them as plain structs and persists their state to the
database (`chrono_state`, `allostatic_state`).

### Chronoception (`ChronoState`)

The gap since the last interaction selects a **temporal mode** — a fresh session, a
continuation (minutes), a soft reconnection (hours), a reconnection (days), or a
reunion (over a week) — which shapes how strongly the agent reorients and acknowledges
elapsed time. A per-topic "context cooling" mechanism tracks staleness with an
exponential half-life, resetting when a topic is mentioned again, and feeds the
weighting of recent summaries during assembly.

### Allostasis (`AllostasisState`)

Inspired by the predictive-budgeting view of emotion, allostasis tracks resource
pressure from recent latency and token consumption and selects a mode —
*exploratory*, *balanced*, *conservative*, or *recovery* — that scales the retrieval
and context budgets up or down. Under pressure the system spends less per turn; when
relaxed it explores more freely.

---

## 9. Plugins, channels, and the control plane

### Plugins

A plugin (`CIMSPlugin`, managed by `PluginRegistry`) has an `id`, a `name`, and an
activate/deactivate lifecycle. Two specializations exist:

- `CIMSToolProvider` — advertises and executes tools
- `MessagingChannel` — a chat surface: start/stop, send, and an
  `AsyncStream<InboundMessage>` of incoming messages

Plugins can also implement lifecycle hooks: `beforeToolCall` /
`afterToolCall` (a tool call can be allowed, modified, or blocked — first
non-`proceed` wins), `beforeInference` / `afterInference` (prompt augmentation and
response analytics), and session start/end.

### The Discord channel

`DiscordChannel` maintains a WebSocket gateway connection with a heartbeat loop and
automatic reconnection (exponential backoff). Outbound text is chunked to respect the
2,000-character limit, with `MessageChunker` taking care never to split inside a code
fence. Slash commands arrive through `DiscordInteractionHandler`, and inbound messages
are filtered by the configured guild (an empty guild filter means DMs only). A
`send_message` tool lets system-initiated messages (cron jobs, proactive outreach)
target a specific channel.

### Slash commands

`CommandRouter` is the runtime control plane reachable from the chat surface:
`/status`, `/memory` (search/grep/expand/stats), `/identity` (show/rollback),
`/mirror`, `/config`, `/heartbeat`, `/restart`, and `/help`.

---

## 10. Agents, skills, and scheduling

### Skills

A **skill** is a reusable instruction set: a `SKILL.md` file with YAML frontmatter
(name, description, tags, and `when` conditions made of file globs and keywords) and a
Markdown body (`SkillManager`). Skills are **auto-loaded** when their `when` conditions
match the current message or touched files — the top matches are injected into context
as system-prompt sections — and the system can **auto-offer** to create a new skill
after tool-heavy turns. A skill with no `when` conditions is manual-only.

### Agents

`AgentRegistry` loads agent definitions (`AgentDefinition`) from an agent directory,
giving the system reusable, named sub-agent configurations for delegation.

### Workers

`WorkerSupervisor` and `WorkerExecutor` run background sub-workers for parallel task
execution. Workers receive *delegated, read-only* access (recorded as
`delegation_grants` with token caps and an operation allow-list) and report compressed
summaries back to the executive rather than raw traces — keeping the executive's
context clean. Concurrency is bounded globally and per-user.

### Scheduling

A cron scheduler (GRDB-backed, `cron_jobs` table) supports interval (`every 30m`),
cron-expression (`0 9 * * 1-5`), and one-shot schedules; jobs can target skills and
deliver to specific channels. A proactive-outreach mechanism sends quiet-hours-aware
check-ins after a configurable period of silence. Both ride a once-per-minute tick
driven by the heartbeat scheduler.

---

## 11. Model subsystem

The model layer abstracts over providers behind `ModelProvider`, selected by
`ModelRouter` and made resilient by `ResilientProvider`.

- **`AnthropicProvider`** speaks the Anthropic Messages API: streaming, prompt
  caching, extended thinking, vision, and tool use. It handles both API keys and
  subscription OAuth tokens (see Section 6).
- **`OpenAIProvider`** speaks the OpenAI Chat Completions API and works against any
  compatible endpoint (OpenAI, OpenRouter, Ollama, LM Studio, and similar).
- **`MessageTranslator`** converts bidirectionally between the two formats — system
  blocks, tool-use/tool-result blocks, images, and cache-control markers (which are
  stripped for non-Anthropic providers).

`ModelRouter` is a conservative classifier that routes simple/system traffic to cheaper
model tiers and escalates to the executive tier on any sign of complexity (code
markers, file paths, images, long or analytical messages). `ResilientProvider` wraps
the provider chain with per-provider health tracking (a sliding outcome window),
demotion of unhealthy providers, exponential-backoff cooldowns, and retry-vs-fatal
classification of errors.

---

## 12. MCP and LSP integration

### MCP

`MCPManager` connects to external **Model Context Protocol** servers and exposes their
tools to the agent through `MCPToolBridge`. It supports two transports, auto-detected
from the server's config entry: **stdio** (`MCPClient`, when a `command` is given) and
**HTTP** (`MCPHTTPClient`, when a `url` is given). It performs the initialization
handshake and surfaces each server's tools into the registry.

### LSP

The `lsp` tool provides code intelligence — hover, go-to-definition, find-references,
and document symbols — by talking to language servers. `LspServerRegistry` discovers
and caches a server per language/workspace, auto-starting it on first use and
restarting it on crash. After an `edit` or `write`, diagnostics are fetched and
appended to the tool result so the agent immediately sees compiler errors it
introduced.

---

## 13. The companion app and IPC

The daemon exposes a dual-transport IPC server (`DaemonIPC`) so the SwiftUI companion
app can drive and observe it:

| Transport | Endpoint | Encoding | Use case |
|-----------|----------|----------|----------|
| Unix domain socket | `~/.aozora/daemon.sock` | line-delimited JSON | same-machine app (lowest latency) |
| WebSocket | a configurable port | JSON in WebSocket text frames | remote app |

Both transports produce handles that conform to a common `IPCClientHandle` protocol
(`send` / `close`), so the daemon broadcasts to all connected clients transport-
agnostically, keyed by an opaque `IPCClientID`. The WebSocket server is built on
`Network.framework` (`NWListener` with WebSocket options), so it adds no external
dependencies; transport-level security for remote access is expected to be provided by
the surrounding network layer, not the daemon.

The app prefers the local socket, falls back to a configured remote WebSocket, and can
fall back further to an in-process gateway. Message types include polling the inspector,
sending messages, and fetching history inbound; and streaming deltas, tool
calls/results, inspector snapshots, and history outbound.

---

## 14. Actor topology and concurrency

The project builds with **Swift 6 strict concurrency** (language mode v6). The
concurrency design follows a clear split:

- **Stateful components are actors**, each serializing access to its own mutable state:
  `CIMSCoordinator` (cognitive state — chronoception, allostasis, the cache timeline),
  `MemoryStore` and `IdentityStore` (database mutations, with concurrent reads via the
  GRDB connection pool), `ToolRegistry` (mutable permission grants), `PluginRegistry`
  (plugin lifecycle), `WorkerSupervisor` (worker tracking), the shell session, the
  cron scheduler, the embedding store, the LSP registry, the MCP manager, and the
  event loop.

- **Pure logic lives in `Sendable` structs** with no isolation of their own —
  `ContextAssembler`, `PromptBuilder`, `DAGCompactor`, `SalienceScorer`,
  `MessageTranslator`, `SecretRedactor`, and the destructive-command guard. The
  coordinator owns these by value and calls into them synchronously.

The single-turn-at-a-time event loop means the executive never races against itself;
the observer subsystem is designed to run *in parallel* with the executive without
blocking it, reading the latest observer signal during context assembly the same way
the coordinator reads chronoception.

---

## 15. Safety systems

Several layers guard tool use and data handling:

- **Permission engine.** `ToolRegistry` evaluates layered allow/deny/ask rules
  (pattern-specific rules override tool-level rules, which override wildcards) and
  supports runtime session grants via an interactive approval flow.
- **Destructive-command guard.** Simple `rm` invocations are rewritten to a
  recoverable `trash`; complex or obfuscated deletions (pipes, subshells,
  `find -delete`) are blocked, while package-manager deletions are allowed.
- **Read-before-edit enforcement.** `FileAccessTracker` records reads and rejects
  edits to files that were not recently read or that changed externally since.
- **File version store.** Pre-mutation snapshots (`file_versions`) enable single-step
  undo and revert-to-original, pruned per conversation/file.
- **Secret redaction.** `SecretRedactor` strips API keys, tokens, credentials, and
  similar patterns from tool results before persistence and from outbound messages as
  defense in depth.
- **Prompt-injection scanning.** `PromptInjectionScanner` inspects fresh tool results
  during context assembly.

---

## 16. Persistence summary

The database (`~/.aozora/cims.db`, with a separate isolated DB for cache testing) uses
GRDB/SQLite in WAL mode with foreign-key enforcement and cascading deletes. Its tables
group into:

- **Core / conversation:** `conversations`, `messages`, `message_parts`, `large_files`,
  `context_items`
- **Memory DAG:** `lcm_nodes`, `lcm_edges`, `lcm_frontier`, `lcm_fts`,
  `lcm_cold_payloads`, `node_embeddings`
- **Identity:** `identity_versions`, `identity_claims`, `users`, `mirror_versions`,
  `mirror_claims`, `claim_evidence`
- **Cognition / maintenance:** `chrono_state`, `allostatic_state`, `cognitive_traces`,
  `consolidation_jobs`, `delegation_grants`
- **Observer:** `plate_snapshots`, `plate_archive`, `observer_signals`
- **Operations:** `todos`, `cron_jobs`, `file_versions`

---

## Further reading

The behavior described here is implemented across `AozoraCore/CIMS/`. The most
load-bearing files are listed in the project's `CLAUDE.md`. Start with
`CIMSCoordinator` for the turn loop, `ContextAssembler` for assembly,
`DAGCompactor`/`MemoryStore` for memory, and `PromptBuilder` for the cache layout.
