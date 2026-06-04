# Aozora

> [!IMPORTANT]
> **This project is no longer maintained.** The repository is archived and published
> as-is for reference and study. Issues and pull requests are not monitored.

**An open-source cognitive architecture daemon for persistent AI agents on macOS.**

Aozora is a long-running macOS daemon that gives a large language model persistent
memory, a constructed sense of identity, temporal awareness, and autonomous tool use.
It connects to chat surfaces (Discord), maintains conversations across sessions, and
evolves a model of itself and of the people it talks to over time.

It implements **CIMS** — the *Constructed Identity Memory System* — a two-tier
cognitive architecture inspired by how biological minds construct continuity of
identity rather than merely retrieving facts. The goal is not better context
management; it is identity construction. See [`ARCHITECTURE.md`](ARCHITECTURE.md)
for the full systems documentation.

> **Status: archived research project.** Aozora was an exploration of identity
> continuity in AI systems, not a polished product. It is single-user,
> single-machine, and assumes you are comfortable building and running a daemon
> from source. Run it at your own risk.

---

## What it does

- **Persistent hierarchical memory.** Conversation history is stored as a directed
  acyclic graph (DAG) in SQLite. Nothing is deleted — old material is compressed into
  higher-level summaries through repeated summarization passes, while raw turns remain
  recoverable on demand. Full-text search (FTS5/BM25) and optional embedding-based
  semantic search retrieve relevant memory into each turn.

- **Constructed identity and per-user "mirror" models.** The agent maintains an
  explicit, versioned, confidence-scored set of *epistemic claims* about itself (the
  identity model) and a separate model of each user it talks to (the mirror model).
  Claims start as hypotheses, are promoted to assertions only with diverse supporting
  evidence, and decay over time without reinforcement.

- **Consolidation ("sleep") cycles.** Offline maintenance passes extract claims from
  recent conversation, merge them into the identity/mirror stores with a full audit
  trail, apply Hebbian decay, and demote rarely-accessed memory to compressed cold
  storage — all without blocking the live conversational loop.

- **Temporal awareness.** The agent perceives the passage of time: resuming after five
  minutes feels different from reconnecting after a week. Gaps in conversation change
  how it reorients.

- **Salience scoring.** Inbound messages are scored for urgency and identity/mirror
  relevance, biasing memory retrieval *before* the model begins reasoning.

- **Heartbeats and proactive outreach.** A periodic heartbeat keeps the prompt cache
  warm and can surface spontaneous activity; quiet-hours-aware check-ins allow the
  agent to reach out on its own.

- **A rich tool suite.** Shell (with a persistent session and destructive-command
  guards), file read/write/edit/patch with read-before-edit safety and undo, ripgrep
  and glob search, code intelligence via LSP, scheduled jobs (cron), reusable skills,
  background sub-workers for parallel tasks, and even self-redeploy (rebuild, sign,
  and restart itself).

- **Multi-provider model routing.** First-class support for the Anthropic Messages
  API — including Claude subscription OAuth tokens — with automatic failover to
  OpenAI-compatible endpoints (OpenAI, OpenRouter, Ollama, LM Studio, and similar).

- **MCP support.** Connects to external Model Context Protocol servers over stdio or
  HTTP, exposing their tools to the agent.

- **Slash commands.** A control plane for inspecting and steering the agent at runtime
  (memory, identity, config, heartbeat, status) from the chat surface.

- **A subcortical observer (experimental).** Infrastructure for a continuously-running
  local "observer" model that maintains state between conversational turns — a default
  mode network analog. The plumbing is present and gated; the local-model integration
  is future work.

- **A SwiftUI companion app.** An optional macOS app providing a chat UI and a live
  inspector into the agent's context, memory, and identity claims. It talks to the
  daemon over IPC (a local Unix domain socket, or a WebSocket for remote access).

---

## Architecture at a glance

```
                  ┌─────────────────────────────────────────────┐
                  │                 AozoraDaemon                │
                  │ chat gateway · CLI · IPC server · heartbeat │
                  └──────────────────────┬──────────────────────┘
                                         │
                  ┌──────────────────────▼──────────────────────┐
                  │                 CIMSGateway                 │
                  │              (facade / wiring)              │
                  └──────────────────────┬──────────────────────┘
                                         │
          ┌───────────────────┬──────────┴──────────┬─────────────────────┐
          │                   │                     │                     │
  ┌───────▼──────┐   ┌────────▼────────┐   ┌────────▼───────┐   ┌─────────▼────────┐
  │ ToolRegistry │   │ CIMSCoordinator │   │ PluginRegistry │   │ WorkerSupervisor │
  │   (tools +   │   │   (turn loop,   │   │   (channels,   │   │   (background    │
  │ permission)  │   │     context,    │   │     hooks)     │   │   delegation)    │
  └──────────────┘   │    salience)    │   └────────────────┘   └──────────────────┘
                     └────────┬────────┘
                              │
           ┌──────────────────┼───────────────────┐
           │                  │                   │
    ┌──────▼──────┐   ┌───────▼───────┐   ┌───────▼───────┐
    │ MemoryStore │   │ IdentityStore │   │ Consolidation │
    │ (DAG, FTS5, │   │    (claims,   │   │     Engine    │
    │  retrieval) │   │    mirrors)   │   │ (decay, cold) │
    └──────┬──────┘   └───────────────┘   └───────────────┘
           │
   ┌───────▼────────┐
   │  DAGCompactor  │ hierarchical summarization
   │  ColdStorage   │ tiered demotion
   └────────────────┘
```

The executive layer (`CIMSCoordinator` and the Anthropic/OpenAI model) runs one turn
at a time. An optional subcortical observer is designed to run continuously alongside
it. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full picture: the turn pipeline,
context assembly, memory DAG, identity system, prompt-cache layout, and concurrency
model.

---

## Requirements

- **macOS 15 or later**
- **Swift 6** toolchain (the daemon builds with the Swift Package Manager)
- **Xcode** — only required to build the optional SwiftUI companion app
- An **Anthropic API key** or **Claude subscription OAuth token**, and/or an
  OpenAI-compatible endpoint
- A **Discord bot token** if you want to connect to Discord
- Optional: `ripgrep`, language servers (`sourcekit-lsp`, `pyright`, `gopls`, …),
  and Docker for sandboxed code execution — each enables a corresponding feature when
  present and is gracefully skipped when absent

---

## Quick start

### 1. Build

```bash
swift build                                  # debug build of the daemon
swift build -c release --product Aozora      # release build
```

This produces the `aozora` binary under `.build/`. All daemon functionality —
including the CLI subcommands below — lives in this single executable.

### 2. Add credentials

Credentials are stored in the macOS Keychain (and can also be supplied via
environment variables). Use the `credential` subcommand:

```bash
# Anthropic API key (auto-detected as api-key)
aozora credential add anthropic main
# ... paste the key when prompted (input is hidden)

# Claude subscription OAuth token (prefix sk-ant-oat...) — auto-detected as oauth
aozora credential add anthropic claude-max

# Discord bot token
aozora credential add discord bot
```

Alternatively, export them in the daemon's environment:

```bash
export DISCORD_BOT_TOKEN="..."
export ANTHROPIC_API_KEY="..."
```

Credential resolution follows a priority chain: explicit config → environment
variable → Keychain entries (ordered by priority). For OAuth, `aozora auth login`
runs a browser-based PKCE flow.

### 3. Configure

Runtime settings live in `~/.aozora/config.json` and are managed with the `config`
subcommand:

```bash
aozora config show                           # list all keys and current values
aozora config set daemon.discordUserId 123456789012345678
aozora config set daemon.guildId 987654321098765432
```

Two keys are required for Discord to function:

- **`daemon.discordUserId`** — the Discord user ID of the primary user (the operator).
- **`daemon.guildId`** — the guild (server) to listen in. **Leave this empty to run in
  DMs only** — with an empty guild filter, the agent responds only to direct messages.

Many other keys are available (model selection, context budgets, heartbeat interval,
consolidation timeout, proactive-outreach quiet hours, coalescer tuning). See
`aozora config show` for the full list.

### 4. Run

```bash
aozora daemon         # or simply: aozora   (daemon is the default subcommand)
```

The daemon opens its database at `~/.aozora/cims.db`, starts the IPC server, connects
to Discord, and begins processing messages.

### 5. Deploy as a background service (optional)

A deploy script builds a release binary, code-signs it, installs it to
`~/.aozora/bin/aozora`, and (re)loads a `launchd` service so the daemon runs in the
background and restarts on crash or login:

```bash
scripts/deploy.sh
```

Code signing is optional. If you set `AOZORA_SIGNING_IDENTITY` it will sign with that
identity; otherwise it falls back to ad-hoc signing.

```bash
export AOZORA_SIGNING_IDENTITY="Apple Development: you@example.com (TEAMID)"
scripts/deploy.sh
```

---

## CLI subcommands

The `aozora` binary is an `ArgumentParser`-based CLI. Running it with no subcommand
launches the daemon.

| Subcommand | Purpose |
|------------|---------|
| `aozora daemon` | Launch the daemon (default). Connects to Discord, serves IPC, runs the cognitive loop. |
| `aozora status` | Report the daemon's current activity and state. |
| `aozora test-api` | Minimal API connectivity test that bypasses the CIMS pipeline. |
| `aozora test-cache check` | Send two identical requests and report whether the prompt cache hit. |
| `aozora test-cache send "msg"` | Run a full CIMS turn against an isolated test database. |
| `aozora test-cache reset` | Clean up the isolated test database. |
| `aozora dump-context` | Assemble and print the full context for a turn without running inference. |
| `aozora config show/get/set/reset` | Manage runtime configuration. |
| `aozora auth login/logout/status` | Manage Claude subscription OAuth (browser PKCE). |
| `aozora credential add/list/remove/active` | Manage Keychain credentials. |

---

## The workspace concept

The agent's personality and operating context are not hard-coded. On startup the
daemon reads a set of Markdown files from **`~/Workspace/`** and assembles them into
the system prompt:

- **`INTRO.md`** — brief grounding for who the participants are
- **`SOUL.md`** — the agent's philosophical identity and values
- **`IDENTITY.md`** — concrete identity facts
- **`USER.md`** — context about the operator
- additional voice/task/board documents as you add them

This makes the agent's character fully user-authored and version-controllable: edit
the files in `~/Workspace/`, restart the daemon, and the agent's grounding changes.
If the workspace is absent, a minimal default system prompt is used.

These workspace documents are the *static* layer of identity. The *dynamic* layer —
the claims the agent forms about itself and others through conversation — lives in the
database and evolves through consolidation (see [`ARCHITECTURE.md`](ARCHITECTURE.md)).

---

## The companion app

`Aozora.xcodeproj` contains an optional SwiftUI macOS app that connects to the running
daemon over IPC. It provides:

- a chat interface with streaming responses and tool-call visualization
- a live **inspector** showing the assembled context, memory DAG statistics, and
  identity/mirror claims
- credential and configuration management

It connects to a same-machine daemon over a Unix domain socket, or to a remote daemon
over WebSocket. Build it from Xcode:

```bash
xcodebuild build -project Aozora.xcodeproj -scheme Aozora -configuration Debug
```

---

## Building and testing

```bash
swift build                    # build the daemon (fast)
swift build --build-tests      # build including the test suite
swift test                     # run tests
```

> **Note:** the `DequeModule` dependency is linked only in the `Daemon/` SPM target.
> Code under `AozoraCore/` must not import it (use `[T]` instead of `Deque<T>`), so
> that the core library remains buildable under the Xcode app target.

---

## License

MIT — see [LICENSE](LICENSE).
