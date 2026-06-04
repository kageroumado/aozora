# Aozora

## Architecture: CIMS

Aozora implements CIMS (Constructed Identity Memory System) — a two-tier cognitive architecture for AI identity construction. See `README.md` for an overview and `ARCHITECTURE.md` for system design.

### OAuth Auth Requirements
Claude subscription OAuth tokens (`sk-ant-oat01-*`) require:
1. `stream: true` always — the API rejects non-streaming requests from OAuth tokens
2. First system block must be: `"You are Claude Code, Anthropic's official CLI for Claude."` (no `cache_control` — only the LAST system block gets `cache_control`)
3. Headers: `anthropic-beta: claude-code-20250219,oauth-2025-04-20,prompt-caching-2024-07-31`, `anthropic-dangerous-direct-browser-access: true`

### Prompt Cache Architecture
The API hashes the entire `system` array as one unit — **any change in any system block invalidates all caches**. Therefore:
- System blocks contain ONLY stable content (summaries, system prompt). Single `cache_control` on the last block.
- Slow-changing state (identity, mirror, cognitive) goes in the first user message — before the stubbing boundary, cached by the message-level breakpoint.
- Per-turn state (chronoception, temporal grounding with timestamps) goes in the current (last) user message — after the stubbing boundary, never cached.

See `PromptBuilder.swift` for the full three-tier layout diagram.

### CLI Tools
The daemon includes ArgumentParser-based CLI tools:
- `aozora daemon` — launch the daemon (default)
- `aozora test-api` — minimal API test bypassing CIMS
- `aozora test-cache check` — cache health check (sends 2 identical requests, reports hit/miss)
- `aozora test-cache send "msg"` — full CIMS turn with isolated test DB
- `aozora test-cache reset` — clean up test DB
- `aozora dump-context` — dump assembled context without inference
- `aozora config` — manage runtime config
- `aozora status` — check daemon status

### Key Files
| File | Purpose |
|------|---------|
| `Daemon/AozoraDaemon.swift` | Entry point, Discord message loop, heartbeat |
| `AozoraCore/CIMS/Model/AnthropicProvider.swift` | API requests, OAuth streaming, cache_control blocks |
| `AozoraCore/CIMS/Context/ContextAssembler.swift` | Section ordering, tool result aging, temporal grounding |
| `AozoraCore/CIMS/Coordinator/CIMSCoordinator.swift` | Turn execution, tool loop, hard threshold |
| `AozoraCore/CIMS/Storage/MemoryStore.swift` | DB queries, compaction triggers, message part loading |
| `AozoraCore/CIMS/DAG/DAGCompactor.swift` | Leaf/condensed passes, dynamic summarization |
| `AozoraCore/CIMS/Domain/CIMSDefaults.swift` | All hardcoded constants (should become config) |
| `AozoraCore/CIMS/Tools/ContextDumpTool.swift` | Context dump (real pipeline intercept) |

## Project-Specific Settings

- **Strict memory safety** (SE-0458) is enabled. Unsafe constructs emit warnings; suppress by acknowledging with `unsafe`.
- **DistributedActor** support via the `Distributed` module — `distributed actor` with `distributed func` methods for remote invocation.

## Documentation Requirements

All types, protocols, functions, and properties must have **DocC-style documentation comments** (`///`). This applies to both `public` and `internal` visibility — everything gets documented.

### What to document

- **Types** (structs, enums, actors, classes, protocols): Purpose, architectural role, lifecycle, and relationship to other types.
- **Functions/methods**: What the function does, its behavioral contract, preconditions, postconditions, and any side effects. Use `- Parameter`, `- Returns`, `- Throws` markup for non-obvious signatures.
- **Properties**: What the value represents and its invariants. Trivial properties (e.g., `let id: Int64`) can use single-line `///` comments.
- **Enum cases**: What each case means and when it's used.
- **Protocol requirements**: The semantic contract — not just the type signature but what conformers must guarantee.

### Style

```swift
/// Scores inbound messages on identity/mirror relevance, urgency, and temporal signals.
///
/// The scorer is a pure function with no side effects or I/O. It produces a ``SalienceEnvelope``
/// that additively boosts retrieval ranking — a bad score degrades ranking slightly but never
/// blocks access to relevant memory.
///
/// Owned by ``CIMSCoordinator`` as a struct (no actor isolation of its own).
struct SalienceScorer { ... }
```

### What NOT to do

- Don't restate the type signature: `/// The id of the user` on `let userId: String` adds nothing.
- Don't use `@available` or deprecation annotations without actual deprecation.
- Don't document generated code or test helpers unless their behavior is non-obvious.

## Build & Test

```bash
swift build                    # SPM daemon build (primary — fast)
swift build --build-tests      # SPM build including tests
swift test                     # Run test suite
```

For the macOS app (Xcode target):
```bash
xcodebuild build -project Aozora.xcodeproj -scheme Aozora -configuration Debug -quiet
xcodebuild test -project Aozora.xcodeproj -scheme Aozora -quiet
```

**Note:** The AozoraCore Xcode target does not link `DequeModule`. Code in `AozoraCore/` must NOT import `DequeModule` — use `[T]` instead of `Deque<T>`. `DequeModule` is only available in the `Daemon/` directory (SPM target).

### Key Patterns

- **Actor topology**: CIMSCoordinator owns stateless structs (SalienceScorer, ChronoState, AllostasisState, ContextAssembler); talks to actor-isolated stores (MemoryStore, IdentityStore) and WorkerSupervisor
- **GRDB for persistence**: 19+ tables with FTS5. Records with autoincrement keys use `MutablePersistableRecord` (not `PersistableRecord`) so `didInsert` fires on the original, not a copy
- **Folder references**: Xcode uses filesystem-based organization. New files auto-include in the build — no need to edit the xcodeproj
