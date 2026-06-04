import Foundation

/// Entry point for initializing and accessing the full CIMS cognitive architecture.
///
/// `CIMSGateway` wires together all CIMS components — database, stores, scorers, assemblers,
/// coordinator, workers, and offline maintenance — into a ready-to-use system. It owns the
/// lifecycle of the entire stack and provides access to the coordinator for running turns.
///
/// **Initialization** is async because:
/// - The database must be opened and migrated.
/// - The identity store bootstraps (creates version 1 if none exists).
///
/// **Usage:**
/// ```swift
/// let gateway = try await CIMSGateway(databasePath: path)
/// let stream = try await gateway.coordinator.runTurn(request)
/// for try await event in stream { ... }
/// ```
///
/// For testing, use ``CIMSGateway/inMemory()`` which creates an ephemeral database and a
/// mock model provider.
public final nonisolated class CIMSGateway: Sendable {
    /// The shared CIMS database instance.
    public let database: CIMSDatabase

    /// The coordinator actor — the main entry point for running cognitive turns.
    public let coordinator: CIMSCoordinator

    /// The memory store actor for direct LCM access (diagnostics, tools).
    public let memoryStore: MemoryStore

    /// The identity store actor for direct claim access (diagnostics, tools).
    public let identityStore: IdentityStore

    /// The consolidation engine for offline maintenance.
    public let consolidationEngine: ConsolidationEngine

    /// The consolidation scheduler that triggers the engine on idle timeout and session end.
    public let consolidationScheduler: ConsolidationScheduler

    /// The worker supervisor for monitoring active workers.
    public let workerSupervisor: WorkerSupervisor

    /// The plugin registry for tool providers and messaging channels.
    public let pluginRegistry: PluginRegistry

    /// The agent tool registry for bash, read, write, edit, and context management tools.
    public let toolRegistry: ToolRegistry

    /// The context pruner for selective context compaction.
    public let contextPruner: ContextPruner

    /// Persistent named text blocks for agent self-knowledge.
    public let memoryBlockStore: MemoryBlockStore

    /// The current prompt snapshot for heartbeat replay, if available.
    public var promptSnapshot: PromptSnapshot? {
        get async { await coordinator.promptSnapshot }
    }

    /// Runtime configuration store for tunable thresholds.
    public let configStore: ConfigStore?

    /// The process monitor for tracking background bash processes.
    public let processMonitor: ProcessMonitor

    /// The cron scheduler for managing periodic jobs.
    public let cronScheduler: CronScheduler

    /// The LSP server registry for managing language server lifecycles.
    public let lspRegistry: LspServerRegistry

    /// The agent registry for resolving named agent configurations.
    public let agentRegistry: AgentRegistry

    /// The file version store for tracking pre-mutation file snapshots.
    public let fileVersionStore: FileVersionStore

    /// The permission engine for tool call authorization.
    public let permissionEngine: PermissionEngine

    /// The provider registry for resolving model providers from model identifiers.
    public let providerRegistry: ProviderRegistry

    /// Initialize the full CIMS stack with a persistent database.
    ///
    /// Opens (or creates) the database at the given path, runs migrations, bootstraps
    /// the identity store, and wires all components together.
    ///
    /// - Parameters:
    ///   - databasePath: Absolute path to the SQLite database file.
    ///   - modelProvider: The LLM inference provider. Defaults to a mock for development.
    ///   - systemPrompt: System prompt for the executive model.
    /// - Throws: GRDB errors if the database can't be opened or migrated.
    public init(
        databasePath: String,
        modelProvider: any ModelProviding = MockModelProvider(),
        systemPrompt: String = "You are a helpful assistant.",
        credentialKind: CredentialKind = .apiKey,
        configStore: ConfigStore? = nil,
    ) async throws {
        self.database = try CIMSDatabase(path: databasePath)

        let memory = MemoryStore(database: database)
        let identity = try await IdentityStore(database: database)
        let supervisor = WorkerSupervisor()
        let registry = PluginRegistry()

        self.memoryStore = memory
        self.identityStore = identity
        self.workerSupervisor = supervisor
        self.pluginRegistry = registry

        let pruner = ContextPruner(database: database)
        self.contextPruner = pruner

        let memBlocks = MemoryBlockStore()
        self.memoryBlockStore = memBlocks
        self.configStore = configStore

        let processMonitor = ProcessMonitor()
        self.processMonitor = processMonitor

        let shellSession = ShellSession(workdir: FileManager.default.currentDirectoryPath)

        let fileTracker = FileAccessTracker()
        let fileVersions = FileVersionStore(database: database)
        self.fileVersionStore = fileVersions

        let lspRegistry = LspServerRegistry()

        let tools = ToolRegistry()
        await tools.register(BashTool(processMonitor: processMonitor, shellSession: shellSession))
        await tools.register(ReadTool(tracker: fileTracker))
        await tools.register(WriteTool(tracker: fileTracker, versionStore: fileVersions, lspRegistry: lspRegistry))
        await tools.register(EditTool(tracker: fileTracker, versionStore: fileVersions, lspRegistry: lspRegistry))
        await tools.register(UndoTool(versionStore: fileVersions))
        await tools.register(WorkerManagementTool(supervisor: supervisor))
        await tools.register(MemoryBlockTool(store: memBlocks))
        await tools.register(CheckProcessTool(monitor: processMonitor))
        await tools.register(KillProcessTool(monitor: processMonitor))
        await tools.register(ListProcessesTool(monitor: processMonitor))
        await tools.register(GlobTool())
        await tools.register(GrepTool())
        await tools.register(PatchTool())
        await tools.register(TodoTool(db: database))
        await tools.register(SkillTool(manager: SkillManager()))
        if let configStore {
            await tools.register(CostTrackingTool(db: database, configStore: configStore))
        }

        let cronScheduler = CronScheduler(db: database)
        await tools.register(CronTool(scheduler: cronScheduler))
        self.cronScheduler = cronScheduler

        await tools.register(LspTool(registry: lspRegistry))
        self.lspRegistry = lspRegistry

        let agentDir = await configStore?.get(.agentDirectory) ?? ConfigKey.agentDirectory.defaultValue
        let expandedDir = (agentDir as NSString).expandingTildeInPath
        self.agentRegistry = AgentRegistry(directory: expandedDir)

        let permissionEngine = PermissionEngine()
        await permissionEngine.loadRules(PermissionEngine.defaultRules)
        await tools.setPermissionEngine(permissionEngine)
        self.permissionEngine = permissionEngine

        self.providerRegistry = ProviderRegistry(fallbackProvider: modelProvider)

        self.toolRegistry = tools

        let coord = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: modelProvider,
            workerSupervisor: supervisor,
            pluginRegistry: registry,
            toolRegistry: tools,
            systemPrompt: systemPrompt,
            credentialKind: credentialKind,
            memoryBlockStore: memBlocks,
            configStore: configStore,
        )
        self.coordinator = coord

        // Register tools that need the coordinator reference
        await tools.register(ContextStatusTool(pruner: pruner, coordinator: coord))
        await tools.register(CompactContextTool(pruner: pruner, coordinator: coord))
        await tools.register(ContextDumpTool(coordinator: coord, memoryStore: memory))

        let engine = ConsolidationEngine(
            database: database,
            identityStore: identity,
            model: modelProvider,
            memoryStore: memory,
        )
        self.consolidationEngine = engine
        self.consolidationScheduler = ConsolidationScheduler(engine: engine)

        // Inject offline components into the memory store.
        // The ClaimExtractor is shared with the compactor for pre-compression claim extraction.
        let claimExtractor = ClaimExtractor(model: modelProvider)
        await memory.setOfflineComponents(
            compactor: DAGCompactor(database: database, model: modelProvider, claimExtractor: claimExtractor),
            coldStorage: ColdStorage(database: database),
            bumpDetector: BumpDetector(database: database),
            configStore: configStore,
        )

        // Wire fork dispatcher so forks flow through the same pipeline.
        // Must be after all stored properties are initialized since the closure captures self.
        await coord.setForkDispatcher { [weak self] request, observer in
            guard let self else { return }
            try await runTurn(request, observer: observer)
        }
    }

    /// Create an in-memory gateway for testing.
    ///
    /// Uses an ephemeral database and a ``MockModelProvider``. Each call produces
    /// an independent system with no shared state.
    ///
    /// - Parameter systemPrompt: System prompt for the executive model.
    /// - Returns: A fully initialized gateway backed by an ephemeral database.
    /// - Throws: GRDB errors if schema creation fails.
    public static func inMemory(
        systemPrompt: String = "You are a helpful assistant.",
    ) async throws -> CIMSGateway {
        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider()

        let memory = MemoryStore(database: db)
        let identity = try await IdentityStore(database: db)
        let supervisor = WorkerSupervisor()
        let registry = PluginRegistry()

        let pruner = ContextPruner(database: db)

        let memBlocks = MemoryBlockStore()

        let processMonitor = ProcessMonitor()

        let shellSession = ShellSession(workdir: FileManager.default.currentDirectoryPath)

        let fileTracker = FileAccessTracker()
        let fileVersions = FileVersionStore(database: db)

        let lspRegistry = LspServerRegistry()

        let tools = ToolRegistry()
        await tools.register(BashTool(processMonitor: processMonitor, shellSession: shellSession))
        await tools.register(ReadTool(tracker: fileTracker))
        await tools.register(WriteTool(tracker: fileTracker, versionStore: fileVersions, lspRegistry: lspRegistry))
        await tools.register(EditTool(tracker: fileTracker, versionStore: fileVersions, lspRegistry: lspRegistry))
        await tools.register(UndoTool(versionStore: fileVersions))
        await tools.register(WorkerManagementTool(supervisor: supervisor))
        await tools.register(MemoryBlockTool(store: memBlocks))
        await tools.register(CheckProcessTool(monitor: processMonitor))
        await tools.register(KillProcessTool(monitor: processMonitor))
        await tools.register(ListProcessesTool(monitor: processMonitor))
        await tools.register(GlobTool())
        await tools.register(GrepTool())
        await tools.register(PatchTool())
        await tools.register(TodoTool(db: db))
        await tools.register(SkillTool(manager: SkillManager()))

        let cronScheduler = CronScheduler(db: db)
        await tools.register(CronTool(scheduler: cronScheduler))

        await tools.register(LspTool(registry: lspRegistry))

        let permissionEngine = PermissionEngine()
        await permissionEngine.loadRules(PermissionEngine.defaultRules)
        await tools.setPermissionEngine(permissionEngine)

        let coordinator = CIMSCoordinator(
            memoryStore: memory,
            identityStore: identity,
            modelProvider: model,
            workerSupervisor: supervisor,
            pluginRegistry: registry,
            toolRegistry: tools,
            systemPrompt: systemPrompt,
            memoryBlockStore: memBlocks,
        )
        await tools.register(ContextStatusTool(pruner: pruner, coordinator: coordinator))
        await tools.register(CompactContextTool(pruner: pruner, coordinator: coordinator))
        await tools.register(ContextDumpTool(coordinator: coordinator, memoryStore: memory))

        let engine = ConsolidationEngine(
            database: db,
            identityStore: identity,
            model: model,
            memoryStore: memory,
        )

        // Inject offline components into the memory store.
        // The ClaimExtractor is shared with the compactor for pre-compression claim extraction.
        let claimExtractor = ClaimExtractor(model: model)
        await memory.setOfflineComponents(
            compactor: DAGCompactor(database: db, model: model, claimExtractor: claimExtractor),
            coldStorage: ColdStorage(database: db),
            bumpDetector: BumpDetector(database: db),
        )

        return CIMSGateway(
            database: db,
            coordinator: coordinator,
            memoryStore: memory,
            identityStore: identity,
            consolidationEngine: engine,
            consolidationScheduler: ConsolidationScheduler(engine: engine),
            workerSupervisor: supervisor,
            pluginRegistry: registry,
            toolRegistry: tools,
            contextPruner: pruner,
            memoryBlockStore: memBlocks,
            configStore: nil,
            processMonitor: processMonitor,
            cronScheduler: cronScheduler,
            lspRegistry: lspRegistry,
            agentRegistry: AgentRegistry(agents: []),
            fileVersionStore: fileVersions,
            permissionEngine: permissionEngine,
            providerRegistry: ProviderRegistry(fallbackProvider: model),
        )
    }

    // MARK: - Turn Execution

    /// Run a cognitive turn through the coordinator, with automatic consolidation scheduling.
    ///
    /// Wraps ``CIMSCoordinator/runTurn(_:)`` to intercept ``TurnEvent/responseCompleted``
    /// Run a turn, wrapping the observer with consolidation scheduling.
    ///
    /// Delegates to the coordinator's ``CIMSCoordinator/runTurn(_:observer:)`` with a
    /// wrapping observer that triggers consolidation on response completion.
    ///
    /// - Parameters:
    ///   - request: The turn request containing the user's message and metadata.
    ///   - observer: Receives turn lifecycle events.
    /// - Throws: ``CIMSError/queueFull`` if the turn queue exceeds ``CIMSDefaults/maxQueuedTurns``.
    public func runTurn(_ request: TurnRequest, observer: some TurnObserver) async throws {
        let isFork = request.sessionKey.hasPrefix("fork:")

        // Incremental persistence for non-fork turns
        let persistingLayer: any TurnObserver = isFork
            ? observer
            : PersistingObserver(
                inner: observer,
                memoryStore: memoryStore,
                sessionKey: request.sessionKey,
            )

        // Only real user turns record activity for consolidation scheduling.
        // System turns (active heartbeats, continuations) don't reset the idle timer.
        let isSystemTurn = request.userKey == "system"
        let wrapping = ConsolidatingObserver(
            inner: persistingLayer,
            scheduler: consolidationScheduler,
            recordActivity: !isSystemTurn,
        )
        try await coordinator.runTurn(request, observer: wrapping)
    }

    /// Wraps a TurnObserver to trigger consolidation scheduling on response completion.
    ///
    /// Only records activity (resetting the idle timer) for user turns, not heartbeats.
    /// Heartbeats should not prevent consolidation from running during idle periods.
    private struct ConsolidatingObserver: TurnObserver {
        let inner: any TurnObserver
        let scheduler: ConsolidationScheduler
        let recordActivity: Bool

        func handleEvent(_ event: TurnEvent) async {
            await inner.handleEvent(event)
            if case .responseCompleted = event, recordActivity {
                await scheduler.recordActivity()
            }
        }
    }

    /// Private memberwise initializer for the `inMemory()` factory.
    private init(
        database: CIMSDatabase,
        coordinator: CIMSCoordinator,
        memoryStore: MemoryStore,
        identityStore: IdentityStore,
        consolidationEngine: ConsolidationEngine,
        consolidationScheduler: ConsolidationScheduler,
        workerSupervisor: WorkerSupervisor,
        pluginRegistry: PluginRegistry,
        toolRegistry: ToolRegistry,
        contextPruner: ContextPruner,
        memoryBlockStore: MemoryBlockStore,
        configStore: ConfigStore?,
        processMonitor: ProcessMonitor,
        cronScheduler: CronScheduler,
        lspRegistry: LspServerRegistry,
        agentRegistry: AgentRegistry,
        fileVersionStore: FileVersionStore,
        permissionEngine: PermissionEngine,
        providerRegistry: ProviderRegistry,
    ) {
        self.database = database
        self.coordinator = coordinator
        self.memoryStore = memoryStore
        self.identityStore = identityStore
        self.consolidationEngine = consolidationEngine
        self.consolidationScheduler = consolidationScheduler
        self.workerSupervisor = workerSupervisor
        self.pluginRegistry = pluginRegistry
        self.toolRegistry = toolRegistry
        self.contextPruner = contextPruner
        self.memoryBlockStore = memoryBlockStore
        self.configStore = configStore
        self.processMonitor = processMonitor
        self.cronScheduler = cronScheduler
        self.lspRegistry = lspRegistry
        self.agentRegistry = agentRegistry
        self.fileVersionStore = fileVersionStore
        self.permissionEngine = permissionEngine
        self.providerRegistry = providerRegistry
    }
}
