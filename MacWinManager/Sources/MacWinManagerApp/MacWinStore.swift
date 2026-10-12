import AppKit
import CryptoKit
import Darwin
import Foundation
import MacWinCore

enum SidebarSection: CaseIterable, Identifiable {
    case desktop
    case home
    case market
    case bottles
    case diagnostics
    case settings

    var id: String { "\(self)" }

    var titleKey: TextKey {
        switch self {
        case .desktop: .applications
        case .home: .home
        case .market: .market
        case .bottles: .bottles
        case .diagnostics: .diagnostics
        case .settings: .settings
        }
    }

    var symbolName: String {
        switch self {
        case .desktop: "square.grid.2x2"
        case .home: "house"
        case .market: "shippingbox"
        case .bottles: "folder"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case apps
    case desktop

    var id: String { rawValue }
}

struct RunningDesktopItem: Identifiable, Equatable {
    var id: String
    var title: String
    var bottleId: String
    var engineId: String
    var bottleName: String
    var processIdentifier: Int32
    var logName: String
    var launchKey: String?
    var startedAt: Date
}

struct ExternalExecutableRequest: Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var displayName: String
    var architecture: WindowsExecutableArchitecture
    var iconURL: URL?
}

private struct BackgroundReportRefresh: Sendable {
    var recentLogs: [LogFileItem]
    var logIssueReport: LogIssueReport
    var logMaintenanceReport: LogMaintenanceReport
    var diagnosticArtifactIndexReport: DiagnosticArtifactIndexReport
    var capabilityReport: CapabilityReport
    var foundationStatusSnapshot: FoundationStatusSnapshot
}

@MainActor
final class MacWinStore: ObservableObject {
    static let shared = MacWinStore()

    @Published var selection: SidebarSection = .desktop
    @Published var workspaceMode: WorkspaceMode = .apps
    @Published var language: AppLanguage = AppLanguage.load()
    @Published var preventScreenLockWhileRunning = UserDefaults.standard.bool(forKey: "MacWinPreventScreenLockWhileRunning")
    @Published var engines: [EngineManifest] = []
    @Published var bottles: [BottleManifest] = []
    @Published var recipes: [RecipeManifest] = []
    @Published var selectedBottleId: String?
    @Published var statusMessage = AppText.text(.ready, language: AppLanguage.load())
    @Published var isBusy = false
    @Published var diagnosticReport: DiagnosticReport?
    @Published var diagnosticHistoryReport = DiagnosticHistoryReport(
        rootPath: MacWinPaths().root.path,
        recordsPath: MacWinPaths().logsDirectory.appendingPathComponent("DiagnosticRecords", isDirectory: true).path,
        records: []
    )
    @Published var nativeUIProbeArtifactReport = NativeUIProbeService().artifactReport()
    @Published var nativeUIProbeHistoryReport = NativeUIProbeHistoryService().report()
    @Published var nativeUIProbeLastRunReport: NativeUIProbeRunReport?
    @Published var hostGUISessionReport = HostGUISessionService().report()
    @Published var nativeUIBridgeHealthReport = NativeUIBridgeHealthReport.empty
    @Published var nativeUIApplicationMatrixReport = NativeUIApplicationMatrixReport.empty(rootPath: MacWinPaths().root.path)
    @Published var representativeAcceptanceReport = RepresentativeSoftwareAcceptanceReport.empty(rootPath: MacWinPaths().root.path)
    @Published var lastError: String?
    @Published var windowControlWarning: String?
    @Published var windowControlRequestID: UUID?
    @Published var runningItems: [RunningDesktopItem] = []
    @Published var recentLogs: [LogFileItem] = []
    @Published var logIssueReport = LogIssueReport(logs: [], topIssues: [], recentFailures: [])
    @Published var logMaintenanceReport: LogMaintenanceReport?
    @Published var diagnosticArtifactIndexReport = DiagnosticArtifactIndexReport.empty()
    @Published var pendingExternalExecutable: ExternalExecutableRequest?
    @Published var supportTriageReport = SupportTriageReport(
        generatedAt: Date(),
        rootPath: MacWinPaths().root.path,
        items: []
    )
    @Published var testAssetReport = TestAssetService().report()
    @Published var testCoverageReport = TestCoverageReport(categories: [])
    @Published var testExecutionPlanReport: TestExecutionPlan?
    @Published var softwareTestPlanReport: SoftwareTestPlanReport?
    @Published var softwareSmokeMatrixReport = SoftwareSmokeMatrixReport(rootPath: MacWinPaths().root.path, rows: [])
    @Published var softwareSampleCatalogReport = SoftwareSampleCatalogService().report(recipes: [])
    @Published var softwareSamplePreparationReport = SoftwareSampleCatalogService().preparationReport(
        catalog: SoftwareSampleCatalogService().report(recipes: [])
    )
    @Published var softwareSampleLogCorrelationReport = SoftwareSampleLogCorrelationReport(
        generatedAt: Date(),
        rootPath: MacWinPaths().root.path,
        entries: []
    )
    @Published var softwareCollectionReport = SoftwareCollectionReport(
        generatedAt: Date(),
        rootPath: MacWinPaths().root.path,
        collections: SoftwareCollectionService.defaultCollections,
        missingRecipeIds: [],
        entries: []
    )
    @Published var softwareCollectionAcceptanceReport = SoftwareCollectionAcceptanceReport(
        generatedAt: Date(),
        rootPath: MacWinPaths().root.path,
        collection: SoftwareCollectionReport(
            generatedAt: Date(),
            rootPath: MacWinPaths().root.path,
            collections: SoftwareCollectionService.defaultCollections,
            missingRecipeIds: [],
            entries: []
        ),
        smokeMatrix: nil,
        testExecutionPlan: nil,
        logIssues: LogIssueReport(logs: [], topIssues: [], recentFailures: []),
        actions: []
    )
    @Published var installerAssetReport: InstallerAssetReport?
    @Published var installerPreparationReport = InstallerPreparationReport(
        rootPath: MacWinPaths().root.path,
        downloadsPath: MacWinPaths().downloadsDirectory.path,
        actions: []
    )
    @Published var installerDownloadHistoryReport: InstallerDownloadHistoryReport?
    @Published var activityTimelineReport = ActivityTimelineReport(generatedAt: Date(), events: [])
    @Published var compatibilityRepairAuditReport = CompatibilityRepairAuditService.report(records: [])
    @Published var bottleHealthReport = BottleHealthAuditReport(rootPath: MacWinPaths().root.path, bottles: [])
    @Published var runtimeProcessAuditReport = RuntimeProcessAuditReport(
        observedProcessCount: 0,
        auditedProcessCount: 0,
        staleRenderingProcessCount: 0,
        entries: [],
        findings: []
    )
    @Published var bottleRuntimeReports: [String: BottleRuntimeReport] = [:]
    @Published var foundationStatusSnapshot: FoundationStatusSnapshot?

    let paths: MacWinPaths
    private let registry: EngineRegistry
    private let bottleService: BottleService
    private let runner: WineRunner
    private let installService: InstallService
    private let installHistoryService: InstallHistoryService
    private let diagnosticsService: DiagnosticsService
    private let diagnosticsHistoryService: DiagnosticsHistoryService
    private let hostGUISessionService: HostGUISessionService
    private let nativeUIBridgeHealthService: NativeUIBridgeHealthService
    private let nativeUIProbeService: NativeUIProbeService
    private let nativeUIProbeHistoryService: NativeUIProbeHistoryService
    private let nativeUIApplicationMatrixService: NativeUIApplicationMatrixService
    private let diagnosticArtifactIndexService: DiagnosticArtifactIndexService
    private let logService: LogService
    private let capabilityReportService: CapabilityReportService
    private let foundationStatusSnapshotService: FoundationStatusSnapshotService
    private let runtimeProcessAuditService: RuntimeProcessAuditService
    private let runtimeProcessTerminator: RuntimeProcessTerminator
    private let testAssetService: TestAssetService
    private let installerAssetService: InstallerAssetService
    private let softwareSampleCatalogService: SoftwareSampleCatalogService
    private let softwareCollectionHistoryService: SoftwareCollectionHistoryService
    private let supportBundleService: SupportBundleService
    private let testSessionArchiveService: TestSessionArchiveService
    private let screenAwakeController = ScreenAwakeController()
    private var didCompleteInitialBootstrap = false
    private var isBootstrapping = false
    private var suppressFoundationStatusSnapshot = false
    private var softwareActionRecipeIdsInFlight = Set<String>()
    private var installRecipeIdsInFlight = Set<String>()
    private var launchKeysInFlight = Set<String>()
    private var queuedExternalExecutables: [ExternalExecutableRequest] = []
    private var externalExecutableOpenQueueWatcherTask: Task<Void, Never>?
    private var bottleRuntimeCleanupTask: Task<Void, Never>?
    private var reportRefreshTask: Task<Void, Never>?

    init(paths: MacWinPaths = MacWinPaths()) {
        self.paths = paths
        self.registry = EngineRegistry(paths: paths)
        self.bottleService = BottleService(paths: paths)
        self.runner = WineRunner(paths: paths)
        self.installService = InstallService(paths: paths)
        self.installHistoryService = InstallHistoryService(paths: paths)
        let hostGUISessionService = HostGUISessionService()
        self.hostGUISessionService = hostGUISessionService
        self.diagnosticsService = DiagnosticsService(
            paths: paths,
            hostGUISessionService: hostGUISessionService
        )
        self.diagnosticsHistoryService = DiagnosticsHistoryService(paths: paths)
        self.nativeUIBridgeHealthService = NativeUIBridgeHealthService()
        self.nativeUIProbeService = NativeUIProbeService(paths: paths)
        self.nativeUIProbeHistoryService = NativeUIProbeHistoryService(paths: paths)
        self.nativeUIApplicationMatrixService = NativeUIApplicationMatrixService(paths: paths)
        self.diagnosticArtifactIndexService = DiagnosticArtifactIndexService(paths: paths)
        self.logService = LogService(paths: paths)
        self.runtimeProcessAuditService = RuntimeProcessAuditService()
        self.runtimeProcessTerminator = RuntimeProcessTerminator()
        self.testAssetService = TestAssetService()
        self.installerAssetService = InstallerAssetService(paths: paths)
        self.softwareSampleCatalogService = SoftwareSampleCatalogService(paths: paths)
        self.softwareCollectionHistoryService = SoftwareCollectionHistoryService(paths: paths)
        self.capabilityReportService = CapabilityReportService(paths: paths, testAssetService: testAssetService)
        self.foundationStatusSnapshotService = FoundationStatusSnapshotService(paths: paths)
        self.supportBundleService = SupportBundleService(paths: paths, capabilityReportService: capabilityReportService)
        self.testSessionArchiveService = TestSessionArchiveService(paths: paths)
    }

    var selectedBottle: BottleManifest? {
        guard let selectedBottleId else { return bottles.first }
        return bottles.first { $0.id == selectedBottleId }
    }

    var defaultPerformanceBottle: BottleManifest? {
        bottles.first { $0.id == BottleService.highPerformanceBottleId }
    }

    var homeLaunchers: [(BottleManifest, LauncherManifest)] {
        bottles.flatMap { bottle in
            bottle.installedApps.filter(\.showInHome).map { (bottle, $0) }
        }
    }

    func text(_ key: TextKey) -> String {
        AppText.text(key, language: language)
    }

    func text(_ key: TextKey, _ values: CVarArg...) -> String {
        String(format: AppText.text(key, language: language), arguments: values)
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        language.save()
        if lastError == nil {
            statusMessage = text(.ready)
        }
    }

    func setPreventScreenLockWhileRunning(_ enabled: Bool) {
        preventScreenLockWhileRunning = enabled
        UserDefaults.standard.set(enabled, forKey: "MacWinPreventScreenLockWhileRunning")
        if !enabled {
            screenAwakeController.endSession()
        }
    }

    private func runWithScreenAwake<T: Sendable>(reason: String, _ operation: () async throws -> T) async throws -> T {
        let shouldHoldAwake = preventScreenLockWhileRunning
        if shouldHoldAwake {
            screenAwakeController.beginSession(for: reason)
        }
        defer {
            if shouldHoldAwake {
                screenAwakeController.endSession()
            }
        }

        return try await operation()
    }

    func graphicsPreset(for bottle: BottleManifest) -> GraphicsPreset {
        GraphicsPreset.current(in: bottle)
    }

    func graphicsPresetAvailable(_ preset: GraphicsPreset, for bottle: BottleManifest) -> Bool {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            return false
        }
        return preset.isAvailable(engine: engine)
    }

    func nativeUIIntegrationPreset(for bottle: BottleManifest) -> NativeUIIntegrationPreset {
        NativeUIIntegrationPreset.current(in: bottle)
    }

    func compatibilityProfile(for launcher: LauncherManifest) -> ApplicationCompatibilityProfile? {
        ApplicationCompatibilityProfile.current(in: launcher)
    }

    func applyGraphicsPreset(_ preset: GraphicsPreset, to bottle: BottleManifest) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        guard preset.isAvailable(engine: engine) else {
            fail(MacWinError.missingFile(GraphicsPreset.gptkPaths(engine: engine).compatibilityMarkerPath))
            return
        }
        setBusy(text(.applyingGraphicsPreset))
        do {
            let updated = try bottleService.applyGraphicsPreset(preset, to: bottle, engine: engine)
            try reloadLocalState()
            selectedBottleId = updated.id
            finish(text(.appliedGraphicsPreset, AppText.graphicsPresetName(preset, language: language)))
        } catch {
            fail(error)
        }
    }

    func applyNativeUIIntegrationPreset(_ preset: NativeUIIntegrationPreset, to bottle: BottleManifest) async {
        setBusy(text(.applyingNativeUIIntegration))
        do {
            let updated = try bottleService.applyNativeUIIntegrationPreset(preset, to: bottle)
            try reloadLocalState()
            selectedBottleId = updated.id
            finish(text(.appliedNativeUIIntegration, AppText.nativeUIIntegrationPresetName(preset, language: language)))
        } catch {
            fail(error)
        }
    }

    func bootstrapIfNeeded() async {
        guard !didCompleteInitialBootstrap, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        await bootstrap()
    }

    func bootstrap() async {
        setBusy(text(.importingEngine))
        await Task.yield()
        suppressFoundationStatusSnapshot = true
        do {
            try loadBundledCatalog(refreshReports: false)
            let engine = try registry.importCurrentGameEngine()
            statusMessage = text(.preparingDefaultBottle)
            await Task.yield()
            _ = try ensureDefaultPerformanceBottle(engine: engine, runWineboot: false)
            let historicalLogCleanup = try logService.archiveHistoricalFailures()
            if historicalLogCleanup.archivedCount > 0 {
                NSLog("MacWin archived historical failure logs count=\(historicalLogCleanup.archivedCount)")
            }
            try reloadLocalState(refreshReports: false)
            suppressFoundationStatusSnapshot = false
            if !didCompleteInitialBootstrap {
                selection = .desktop
                didCompleteInitialBootstrap = true
            }
            finish(text(.ready))
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.refreshDiagnosticHistory()
                self.refreshRecentLogs()
            }
        } catch {
            suppressFoundationStatusSnapshot = false
            fail(error)
        }
    }

    func startExternalExecutableOpenQueueWatcher() {
        guard externalExecutableOpenQueueWatcherTask == nil else { return }
        externalExecutableOpenQueueWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drainQueuedExternalExecutableOpens()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func startBottleRuntimeCleanupWatcher() {
        guard bottleRuntimeCleanupTask == nil else { return }
        bottleRuntimeCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.cleanupOrphanedBottleProcesses()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func cleanupOrphanedBottleProcesses() async {
        guard !isBusy else { return }
        let currentBottles = bottles
        guard !currentBottles.isEmpty else { return }
        let paths = paths
        let results = await Task.detached(priority: .utility) {
            currentBottles.map { bottle in
                BottleRuntimeService(paths: paths).cleanupOrphans(in: bottle)
            }
        }.value
        let cleanedCount = results.map(\.stoppedCount).reduce(0, +)
        guard cleanedCount > 0 else { return }
        runtimeProcessAuditReport = runtimeProcessAuditService.makeReport()
        bottleRuntimeReports = Dictionary(uniqueKeysWithValues: currentBottles.map { bottle in
            (bottle.id, BottleRuntimeService(paths: paths).report(for: bottle))
        })
        refreshRunningItems()
        refreshRecentLogs()
        statusMessage = text(.cleanedOrphanedProcesses, cleanedCount)
        lastError = nil
    }

    func drainQueuedExternalExecutableOpens() async {
        let urls = MacWinExternalOpenQueue.drain()
        for url in urls {
            await handleExternalExecutableOpen(url)
        }
    }

    func reloadLocalState(refreshReports: Bool = true) throws {
        engines = try registry.listEngines()
        bottles = try bottleService.listBottles()
        testAssetReport = testAssetService.report()
        refreshNativeUIProbeState()
        if refreshReports {
            refreshDiagnosticHistory()
            refreshRecentLogs()
        }
        if selectedBottleId == nil {
            selectedBottleId = bottles.first?.id
        }
    }

    func refreshNativeUIProbeState() {
        hostGUISessionReport = hostGUISessionService.report()
        nativeUIBridgeHealthReport = nativeUIBridgeHealthService.report(engines: engines)
        nativeUIProbeArtifactReport = nativeUIProbeService.artifactReport()
        nativeUIProbeHistoryReport = nativeUIProbeHistoryService.report()
        nativeUIProbeLastRunReport = nativeUIProbeHistoryReport.records.first
    }

    func stopBottleProcesses(_ bottle: BottleManifest) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        setBusy(text(.stoppingBottleProcesses, bottle.name))
        do {
            let paths = paths
            let result = try await Task.detached(priority: .userInitiated) {
                try BottleRuntimeService(paths: paths).stopAll(in: bottle, engine: engine)
            }.value
            try reloadLocalState(refreshReports: false)
            refreshRecentLogs()
            bottleRuntimeReports[bottle.id] = BottleRuntimeService(paths: paths).report(for: bottle)
            runningItems.removeAll { $0.bottleId == bottle.id }
            if result.succeeded {
                finish(text(.stoppedBottleProcesses, bottle.name, result.stoppedCount))
            } else {
                statusMessage = text(.stoppedBottleProcessesPartial, bottle.name, result.stoppedCount, result.remainingProcessCount)
                lastError = nil
                isBusy = false
            }
        } catch {
            fail(error)
        }
    }

    func restartBottle(_ bottle: BottleManifest) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        setBusy(text(.restartingBottle, bottle.name))
        do {
            let paths = paths
            let result = try await Task.detached(priority: .userInitiated) {
                try BottleRuntimeService(paths: paths).restart(bottle: bottle, engine: engine)
            }.value
            try reloadLocalState(refreshReports: false)
            refreshRecentLogs()
            bottleRuntimeReports[bottle.id] = BottleRuntimeService(paths: paths).report(for: bottle)
            runningItems.removeAll { $0.bottleId == bottle.id }
            if result.restarted {
                finish(text(.restartedBottle, bottle.name))
            } else {
                statusMessage = text(.restartBottleIncomplete, bottle.name, result.remainingProcessCount)
                lastError = nil
                isBusy = false
            }
        } catch {
            fail(error)
        }
    }

    func cleanupAllBottleRuntimeProcessesForShutdown() {
        for bottle in bottles {
            guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else { continue }
            do {
                _ = try BottleRuntimeService(paths: paths).stopAll(in: bottle, engine: engine)
            } catch {
                NSLog("MacWin bottle shutdown cleanup failed bottle=\(bottle.id) error=\(error.localizedDescription)")
            }
        }
    }

    func runNativeUIApplication(_ entry: NativeUIApplicationMatrixEntry, withDiagnostics: Bool = false) async {
        guard let bottleId = entry.bottleId,
              let launcherId = entry.launcherId,
              let bottle = bottles.first(where: { $0.id == bottleId }),
              let launcher = bottle.installedApps.first(where: { $0.id == launcherId }) else {
            statusMessage = text(.nativeUIApplicationNeedsInstall, entry.name)
            lastError = nil
            return
        }
        if withDiagnostics {
            await runLauncherWithDiagnostics(launcher, in: bottle)
        } else {
            await runLauncher(launcher, in: bottle)
        }
    }

    func runRepresentativeSoftwareAcceptance() async {
        guard !isBusy else { return }
        setBusy(text(.runningRepresentativeAcceptance))
        let targets = nativeUIApplicationMatrixReport.entries.filter {
            RepresentativeSoftwareAcceptanceService.targetSampleIds.contains($0.sampleId)
        }
        for target in targets {
            if let bottleId = target.bottleId,
               let launcherId = target.launcherId,
               let bottle = bottles.first(where: { $0.id == bottleId }),
               let launcher = bottle.installedApps.first(where: { $0.id == launcherId }) {
                await runLauncherWithDiagnostics(launcher, in: bottle)
                refreshRepresentativeAcceptanceReport()
                continue
            }

            guard let recipeId = target.recipeId,
                  let recipe = recipes.first(where: { $0.id == recipeId }),
                  recipe.disabledReason == nil,
                  target.recipeAvailable,
                  recipe.installer.mode != .localFile || target.installerPath != nil else {
                continue
            }
            let localInstaller = target.installerPath.map(URL.init(fileURLWithPath:))
            await install(recipe: recipe, localInstaller: localInstaller)
            refreshRepresentativeAcceptanceReport()
            guard let refreshed = nativeUIApplicationMatrixReport.entries.first(where: { $0.sampleId == target.sampleId }),
                  let bottleId = refreshed.bottleId,
                  let launcherId = refreshed.launcherId,
                  let bottle = bottles.first(where: { $0.id == bottleId }),
                  let launcher = bottle.installedApps.first(where: { $0.id == launcherId }) else {
                continue
            }
            await runLauncherWithDiagnostics(launcher, in: bottle)
            refreshRepresentativeAcceptanceReport()
        }
        refreshRepresentativeAcceptanceReport()
        finish(text(.representativeAcceptanceFinished, representativeAcceptanceReport.passedCount, representativeAcceptanceReport.targetCount))
    }

    private func refreshRepresentativeAcceptanceReport() {
        let launchHistory = LaunchHistoryService(paths: paths).report(limit: 120)
        let smokeReports = (try? SoftwareSmokeRunReportService(paths: paths).reports(limit: 120)) ?? []
        nativeUIApplicationMatrixReport = nativeUIApplicationMatrixService.report(
            bottles: bottles,
            recipes: recipes,
            launchHistory: launchHistory,
            smokeReports: smokeReports
        )
        let service = RepresentativeSoftwareAcceptanceService(paths: paths)
        representativeAcceptanceReport = service.report(matrix: nativeUIApplicationMatrixReport)
        _ = try? service.save(representativeAcceptanceReport)
    }

    func loadBundledCatalog(refreshReports: Bool = true) throws {
        guard let indexURL = bundledCatalogIndexURL() ?? cachedCatalogIndexURL() else {
            throw MacWinError.missingFile("Bundled or cached Catalog/catalog.index.json resource")
        }
        let catalogRoot = indexURL.deletingLastPathComponent()
        let keyData = Data(base64Encoded: CatalogTrust.developmentPublicKeyBase64)!
        let publicKey = try P256.Signing.PublicKey(rawRepresentation: keyData)
        let source = CatalogSource(root: catalogRoot)
        let catalog = try CatalogService(
            source: source,
            trustedPublicKeys: [CatalogTrust.developmentKeyId: publicKey]
        ).refresh()
        if catalogRoot.standardizedFileURL.path != paths.catalogDirectory.standardizedFileURL.path {
            _ = try CatalogCacheService(paths: paths).syncVerifiedCatalog(from: source, snapshot: catalog)
        }
        recipes = catalog.recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if refreshReports {
            refreshSoftwareTestPlan()
        }
        if catalog.isExpired {
            statusMessage = text(.catalogExpired)
        }
    }

    private func bundledCatalogIndexURL() -> URL? {
        let resourceBundleName = "MacWinManager_MacWinManagerApp.bundle"
        let relativePath = "Catalog/catalog.index.json"
        let appBundleCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName, isDirectory: true),
            Bundle.main.bundleURL.appendingPathComponent(resourceBundleName, isDirectory: true)
        ]
        for bundleURL in appBundleCandidates.compactMap(\.self) {
            let indexURL = bundleURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                return indexURL
            }
        }
        return Bundle.module.url(forResource: "catalog.index", withExtension: "json", subdirectory: "Catalog")
    }

    private func cachedCatalogIndexURL() -> URL? {
        let indexURL = paths.catalogDirectory.appendingPathComponent("catalog.index.json")
        return FileManager.default.fileExists(atPath: indexURL.path) ? indexURL : nil
    }

    func createBottle(named name: String) async {
        guard let engine = preferredEngine() else {
            fail(MacWinError.unsupportedEngine(text(.noEngineRegistered)))
            return
        }
        setBusy(text(.creatingBottle))
        do {
            let bottle = try bottleService.createBottle(
                name: name,
                template: BottleTemplate(windowsVersion: "win11", arch: .win64),
                engine: engine
            )
            try reloadLocalState()
            selectedBottleId = bottle.id
            selection = .bottles
            finish(text(.created, bottle.name))
        } catch {
            fail(error)
        }
    }

    func repairBottle(_ bottle: BottleManifest) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        setBusy(text(.repairingBottle, bottle.name))
        do {
            try bottleService.repairBottleCompatibility(bottle, engine: engine)
            try reloadLocalState()
            selectedBottleId = bottle.id
            finish(text(.repairedBottle, bottle.name))
        } catch {
            fail(error)
        }
    }

    func scanInstalledApps(in bottle: BottleManifest) async {
        setBusy(text(.scanningInstalledApps, bottle.name))
        do {
            let detectedBottle = try bottleService.registerDetectedInstalledApps(in: bottle)
            let updatedBottle = try bottleService.migrateLauncherCompatibility(in: detectedBottle)
            try reloadLocalState()
            selectedBottleId = updatedBottle.id
            refreshRecentLogs()
            finish(text(.scannedInstalledApps, updatedBottle.name, updatedBottle.installedApps.count))
        } catch {
            fail(error)
        }
    }

    func applyCompatibilityProfile(
        _ profile: ApplicationCompatibilityProfile,
        to launcher: LauncherManifest,
        in bottle: BottleManifest
    ) async {
        setBusy(text(.applyingCompatibilityProfile))
        do {
            _ = try bottleService.applyCompatibilityProfile(profile, to: launcher, in: bottle)
            try reloadLocalState()
            selectedBottleId = bottle.id
            finish(text(
                .appliedCompatibilityProfile,
                launcher.displayName,
                AppText.compatibilityProfileName(profile, language: language)
            ))
        } catch {
            fail(error)
        }
    }

    func clearCompatibilityProfile(from launcher: LauncherManifest, in bottle: BottleManifest) async {
        setBusy(text(.applyingCompatibilityProfile))
        do {
            _ = try bottleService.clearCompatibilityProfile(from: launcher, in: bottle)
            try reloadLocalState()
            selectedBottleId = bottle.id
            finish(text(.clearedCompatibilityProfile, launcher.displayName))
        } catch {
            fail(error)
        }
    }

    func install(recipe: RecipeManifest, localInstaller: URL? = nil) async {
        guard let engine = preferredEngine(for: recipe) else {
            fail(MacWinError.unsupportedEngine(text(.noEngineRegistered)))
            return
        }
        guard !installRecipeIdsInFlight.contains(recipe.id) else {
            statusMessage = text(.actionAlreadyInProgress, recipe.name)
            lastError = nil
            return
        }
        installRecipeIdsInFlight.insert(recipe.id)
        defer { installRecipeIdsInFlight.remove(recipe.id) }
        setBusy(text(.installing, recipe.name))
        do {
            try await runWithScreenAwake(reason: "MacWin install recipe: \(recipe.name)") {
                let bottle = try ensureDefaultPerformanceBottle(engine: engine)
                let source = localInstaller.map(InstallerSource.localFile)
                    ?? (recipe.installer.mode == .alreadyInstalled ? .existingInstallation : nil)
                let installPaths = paths
                let task = try await Task.detached(priority: .userInitiated) {
                    try InstallService(paths: installPaths).install(
                        recipe: recipe,
                        bottle: bottle,
                        engine: engine,
                        installerSource: source
                    )
                }.value
                try reloadLocalState()
                selectedBottleId = bottle.id
                selection = .bottles
                if task.state == .succeeded, task.progressText.hasPrefix("Already installed") {
                    finish(task.progressText)
                } else {
                    finish(task.state == .succeeded ? text(.installedIntoDefaultBottle, recipe.name) : task.progressText)
                }
            }
        } catch {
            fail(error)
        }
    }

    func runLauncher(_ launcher: LauncherManifest, in bottle: BottleManifest) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        let launchKey = Self.launcherLaunchKey(bottleId: bottle.id, launcherId: launcher.id)
        guard beginLaunchIfNeeded(launchKey: launchKey, displayName: launcher.displayName) else {
            return
        }
        defer { endLaunch(launchKey: launchKey) }
        let logName = "\(bottle.id)-\(launcher.id).log"
        setBusy(text(.launching, launcher.displayName))
        do {
            try await runWithScreenAwake(reason: "MacWin run launcher: \(launcher.displayName)") {
                if finishIfRuntimeAlreadyRunning(executable: launcher.exePath, displayName: launcher.displayName) {
                    return
                }
                let launchPaths = paths
                let launch = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareAndLaunchLauncher(
                        paths: launchPaths,
                        bottle: bottle,
                        engine: engine,
                        launcher: launcher,
                        logName: logName
                    )
                }.value
                try reloadLocalState()
                trackRunningItem(
                    title: launch.launcher.displayName,
                    bottle: launch.bottle,
                    processIdentifier: launch.result.processIdentifier,
                    logName: logName,
                    launchKey: launchKey
                )
                refreshRecentLogs()
                finish(text(.launchedPid, launch.launcher.displayName, "\(launch.result.processIdentifier)"))
            }
        } catch {
            fail(error)
        }
    }

    func runLauncherWithDiagnostics(_ launcher: LauncherManifest, in bottle: BottleManifest) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        let launchKey = Self.launcherLaunchKey(bottleId: bottle.id, launcherId: launcher.id)
        guard beginLaunchIfNeeded(launchKey: launchKey, displayName: launcher.displayName) else {
            return
        }
        defer { endLaunch(launchKey: launchKey) }
        let logName = "\(bottle.id)-\(launcher.id)-diagnostic-\(UUID().uuidString.prefix(8)).log"
        let diagnosticEnvOverrides = [
            "MACWIN_DIAGNOSTIC_LAUNCH": "1",
            "WINEDEBUG": Self.diagnosticWineDebug
        ]
        setBusy(text(.launchingWithDiagnostics, launcher.displayName))
        do {
            try await runWithScreenAwake(reason: "MacWin run diagnostic launcher: \(launcher.displayName)") {
                if finishIfRuntimeAlreadyRunning(executable: launcher.exePath, displayName: launcher.displayName) {
                    return
                }
                let launchPaths = paths
                let launch = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareAndLaunchLauncher(
                        paths: launchPaths,
                        bottle: bottle,
                        engine: engine,
                        launcher: launcher,
                        logName: logName,
                        additionalEnvOverrides: diagnosticEnvOverrides
                    )
                }.value
                try reloadLocalState()
                trackRunningItem(
                    title: text(.diagnosticLaunchTitle, launch.launcher.displayName),
                    bottle: launch.bottle,
                    processIdentifier: launch.result.processIdentifier,
                    logName: logName,
                    launchKey: launchKey
                )
                refreshRecentLogs()
                finish(text(.launchedPid, text(.diagnosticLaunchTitle, launch.launcher.displayName), "\(launch.result.processIdentifier)"))
            }
        } catch {
            fail(error)
        }
    }

    func handleExternalExecutableOpen(_ url: URL) async {
        guard url.pathExtension.lowercased() == "exe" else {
            fail(MacWinError.unsupportedInstallerMode(text(.unsupportedInstallerFile, url.lastPathComponent)))
            return
        }

        do {
            if engines.isEmpty || bottles.isEmpty {
                await bootstrap()
            }
            try paths.ensureBaseDirectories()
            let architecture = try WindowsExecutableInspector.architecture(of: url) ?? .unknown
            let iconURL = try cacheIconIfAvailable(for: url)
            let request = ExternalExecutableRequest(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                architecture: architecture,
                iconURL: iconURL
            )
            enqueueExternalExecutableRequest(request)
            if selectedBottleId == nil {
                selectedBottleId = defaultPerformanceBottle?.id ?? bottles.first?.id
            }
            selection = .bottles
            lastError = nil
            statusMessage = text(.openWindowsExecutable)
        } catch {
            fail(error)
        }
    }

    func dismissPendingExternalExecutable() {
        pendingExternalExecutable = nil
        showNextQueuedExternalExecutable()
    }

    func runExternalExecutable(_ request: ExternalExecutableRequest, in bottle: BottleManifest, diagnostics: Bool = false) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        if request.architecture.is32Bit && !engine.supportsWin32 {
            fail(MacWinError.unsupportedEngine("32-bit Windows executable requires a WoW64-capable engine: \(request.url.lastPathComponent)"))
            return
        }

        let launchKey = Self.externalExecutableLaunchKey(bottleId: bottle.id, url: request.url)
        guard beginLaunchIfNeeded(launchKey: launchKey, displayName: request.displayName) else {
            return
        }
        defer { endLaunch(launchKey: launchKey) }
        let logName = "\(bottle.id)-external-\(Self.logSafeName(request.url.lastPathComponent))\(diagnostics ? "-diagnostic" : "").log"
        var externalLauncher = LauncherManifest(
            id: "external-\(Self.logSafeName(request.url.lastPathComponent))",
            appId: "external-executable",
            bottleId: bottle.id,
            displayName: request.displayName,
            exePath: request.url.path
        )
        if let profile = ApplicationCompatibilityProfile.matched(
            displayName: request.displayName,
            exePath: request.url.path
        ) {
            externalLauncher = profile.applied(to: externalLauncher)
        }
        var env = externalLauncher.envOverrides
        if diagnostics {
            env["MACWIN_DIAGNOSTIC_LAUNCH"] = "1"
            env["WINEDEBUG"] = Self.diagnosticWineDebug
        }
        setBusy(diagnostics ? text(.launchingWithDiagnostics, request.displayName) : text(.launching, request.displayName))
        do {
            try await runWithScreenAwake(reason: "MacWin run external executable: \(request.displayName)") {
                let preparedBottle = try prepareBottle(bottle, for: engine)
                try resetRenderingCachesIfNeeded(for: externalLauncher, in: preparedBottle)
                try reloadLocalState()
                if finishIfRuntimeAlreadyRunning(executable: request.url.path, displayName: request.displayName) {
                    return
                }
                let result = try runner.launchDetached(
                    WineRunRequest(
                        exe: request.url.path,
                        args: externalLauncher.args,
                        bottle: preparedBottle,
                        engine: engine,
                        envOverrides: env,
                        logName: logName
                    )
                )
                trackRunningItem(
                    title: diagnostics ? text(.diagnosticLaunchTitle, request.displayName) : request.displayName,
                    bottle: preparedBottle,
                    processIdentifier: result.processIdentifier,
                    logName: logName,
                    launchKey: launchKey
                )
                dismissPendingExternalExecutable()
                refreshRecentLogs()
                finish(text(.launchedPid, request.displayName, "\(result.processIdentifier)"))
            }
        } catch {
            fail(error)
        }
    }

    func runCommand(_ exe: String, args: [String], in bottle: BottleManifest) async {
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        let launchKey = Self.commandLaunchKey(bottleId: bottle.id, exe: exe, args: args)
        guard beginLaunchIfNeeded(launchKey: launchKey, displayName: exe) else {
            return
        }
        defer { endLaunch(launchKey: launchKey) }
        let logName = "\(bottle.id)-run-command.log"
        setBusy(text(.runningCommand))
        do {
            try await runWithScreenAwake(reason: "MacWin run command: \(exe)") {
                let preparedBottle = try prepareBottle(bottle, for: engine)
                let commandLauncher = profiledCommandLauncher(exe: exe, args: args, in: preparedBottle)
                try resetRenderingCachesIfNeeded(for: commandLauncher, in: preparedBottle)
                try reloadLocalState()
                if finishIfRuntimeAlreadyRunning(executable: commandLauncher.exePath, displayName: commandLauncher.displayName) {
                    return
                }
                let result = try runner.launchDetached(
                    WineRunRequest(
                        exe: commandLauncher.exePath,
                        args: commandLauncher.args,
                        bottle: preparedBottle,
                        engine: engine,
                        envOverrides: commandLauncher.envOverrides,
                        logName: logName
                    )
                )
                trackRunningItem(
                    title: commandLauncher.displayName,
                    bottle: preparedBottle,
                    processIdentifier: result.processIdentifier,
                    logName: logName,
                    launchKey: launchKey
                )
                refreshRecentLogs()
                finish(text(.startedPid, "\(result.processIdentifier)"))
            }
        } catch {
            fail(error)
        }
    }

    private func profiledCommandLauncher(exe: String, args: [String], in bottle: BottleManifest) -> LauncherManifest {
        let displayName = URL(fileURLWithPath: exe.replacingOccurrences(of: "\\", with: "/"))
            .deletingPathExtension()
            .lastPathComponent
        var launcher = LauncherManifest(
            id: "run-command-\(Self.logSafeName(exe))",
            appId: "run-command",
            bottleId: bottle.id,
            displayName: displayName.isEmpty ? exe : displayName,
            exePath: exe,
            args: args
        )
        if let profile = ApplicationCompatibilityProfile.matched(
            launcherId: launcher.id,
            displayName: launcher.displayName,
            exePath: exe
        ) {
            launcher = profile.applied(to: launcher)
        }
        return launcher
    }

    func installDroppedInstaller(_ installerURL: URL, in bottle: BottleManifest) async {
        let fileName = installerURL.lastPathComponent
        let fileExtension = installerURL.pathExtension.lowercased()
        guard fileExtension == "exe" || fileExtension == "msi" else {
            fail(MacWinError.unsupportedInstallerMode(text(.unsupportedInstallerFile, fileName)))
            return
        }

        let accessGranted = installerURL.startAccessingSecurityScopedResource()
        let cachedInstallerURL: URL
        do {
            cachedInstallerURL = try cacheDroppedInstaller(installerURL)
        } catch {
            if accessGranted {
                installerURL.stopAccessingSecurityScopedResource()
            }
            fail(error)
            return
        }
        if accessGranted {
            installerURL.stopAccessingSecurityScopedResource()
        }

        let requiresWin32 = (try? installService.installerRequiresWin32(cachedInstallerURL)) == true
        guard let engine = preferredEngine(requiresWin32: requiresWin32) else {
            let reason = requiresWin32
                ? "没有可用的 WoW64 engine，无法运行 32 位安装器 \(fileName)"
                : text(.noEngineForBottle, bottle.name)
            fail(MacWinError.unsupportedEngine(reason))
            return
        }

        let command: String
        let arguments: [String]
        switch fileExtension {
        case "exe":
            command = cachedInstallerURL.path
            arguments = []
        case "msi":
            command = "msiexec"
            arguments = ["/i", cachedInstallerURL.path]
        default:
            fail(MacWinError.unsupportedInstallerMode(text(.unsupportedInstallerFile, fileName)))
            return
        }

        let logName = "\(bottle.id)-dropped-installer-\(Self.logSafeName(fileName)).log"
        let launchKey = Self.externalExecutableLaunchKey(bottleId: bottle.id, url: installerURL)
        guard beginLaunchIfNeeded(launchKey: launchKey, displayName: fileName) else {
            return
        }
        defer { endLaunch(launchKey: launchKey) }
        setBusy(text(.installingDroppedInstaller, fileName))
        do {
            try await runWithScreenAwake(reason: "MacWin run dropped installer: \(fileName)") {
                let preparedBottle = try prepareBottle(bottle, for: engine)
                try reloadLocalState()
                if finishIfRuntimeAlreadyRunning(executable: command, displayName: fileName) {
                    return
                }
                let result = try runner.launchDetached(
                    WineRunRequest(
                        exe: command,
                        args: arguments,
                        bottle: preparedBottle,
                        engine: engine,
                        logName: logName
                    )
                )
                recordLocalInstallerLaunch(
                    fileName: fileName,
                    sourceURL: cachedInstallerURL,
                    bottle: preparedBottle,
                    logName: logName,
                    processIdentifier: result.processIdentifier
                )
                trackRunningItem(
                    title: fileName,
                    bottle: preparedBottle,
                    processIdentifier: result.processIdentifier,
                    logName: logName,
                    launchKey: launchKey
                )
                refreshRecentLogs()
                finish(text(.droppedInstallerStarted, fileName, "\(result.processIdentifier)"))
            }
        } catch {
            fail(error)
        }
    }

    func installCachedInstallerCandidate(_ candidate: DownloadCacheFileStatus) async {
        let installerURL = URL(fileURLWithPath: candidate.path)
        let fileName = installerURL.lastPathComponent
        let fileExtension = installerURL.pathExtension.lowercased()
        guard fileExtension == "exe" || fileExtension == "msi" else {
            fail(MacWinError.unsupportedInstallerMode(text(.unsupportedInstallerFile, fileName)))
            return
        }

        let requiresWin32 = candidate.architecture?.is32Bit == true
            || ((try? installService.installerRequiresWin32(installerURL)) == true)
        guard let engine = preferredEngine(requiresWin32: requiresWin32) else {
            let reason = requiresWin32
                ? "没有可用的 WoW64 engine，无法运行 32 位安装器 \(fileName)"
                : text(.noEngineRegistered)
            fail(MacWinError.unsupportedEngine(reason))
            return
        }

        let command: String
        let arguments: [String]
        switch fileExtension {
        case "exe":
            command = installerURL.path
            arguments = []
        case "msi":
            command = "msiexec"
            arguments = ["/i", installerURL.path]
        default:
            fail(MacWinError.unsupportedInstallerMode(text(.unsupportedInstallerFile, fileName)))
            return
        }

        let logName = "\(BottleService.highPerformanceBottleId)-local-candidate-\(Self.logSafeName(fileName)).log"
        let launchKey = Self.externalExecutableLaunchKey(bottleId: BottleService.highPerformanceBottleId, url: installerURL)
        guard beginLaunchIfNeeded(launchKey: launchKey, displayName: fileName) else {
            return
        }
        defer { endLaunch(launchKey: launchKey) }
        setBusy(text(.installingDroppedInstaller, fileName))
        do {
            try await runWithScreenAwake(reason: "MacWin run cached installer: \(fileName)") {
                let bottle = try ensureDefaultPerformanceBottle(engine: engine)
                let preparedBottle = try prepareBottle(bottle, for: engine)
                try reloadLocalState()
                selectedBottleId = preparedBottle.id
                if finishIfRuntimeAlreadyRunning(executable: command, displayName: fileName) {
                    return
                }
                let result = try runner.launchDetached(
                    WineRunRequest(
                        exe: command,
                        args: arguments,
                        bottle: preparedBottle,
                        engine: engine,
                        logName: logName
                    )
                )
                recordLocalInstallerLaunch(
                    fileName: fileName,
                    sourceURL: installerURL,
                    bottle: preparedBottle,
                    logName: logName,
                    processIdentifier: result.processIdentifier
                )
                trackRunningItem(
                    title: fileName,
                    bottle: preparedBottle,
                    processIdentifier: result.processIdentifier,
                    logName: logName,
                    launchKey: launchKey
                )
                refreshRecentLogs()
                finish(text(.droppedInstallerStarted, fileName, "\(result.processIdentifier)"))
            }
        } catch {
            fail(error)
        }
    }

    func launchWindows11Desktop(for bottle: BottleManifest) async {
        guard bottle.windowsVersion == "win11" else {
            fail(MacWinError.unsupportedInstallerMode(text(.windowsDesktopOnlyWin11)))
            return
        }
        let launchKey = Self.commandLaunchKey(
            bottleId: bottle.id,
            exe: "C:\\windows\\system32\\explorer.exe",
            args: ["windows11-desktop"]
        )
        guard beginLaunchIfNeeded(launchKey: launchKey, displayName: text(.windows11Desktop)) else {
            return
        }
        defer { endLaunch(launchKey: launchKey) }
        guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
            fail(MacWinError.unsupportedEngine(text(.noEngineForBottle, bottle.name)))
            return
        }
        setBusy(text(.preparingDesktop))
        do {
            try await runWithScreenAwake(reason: "MacWin launch Windows 11 desktop") {
                let preparedBottle = try bottleService.bootstrapWinePrefixIfNeeded(bottle: bottle, engine: engine)
                try reloadLocalState()
                selectedBottleId = preparedBottle.id
                statusMessage = text(.launching, text(.windows11Desktop))
                if finishIfRuntimeAlreadyRunning(executable: "C:\\windows\\system32\\explorer.exe", displayName: text(.windows11Desktop)) {
                    return
                }
                let result = try runner.launchDetached(
                    runner.windows11DesktopRequest(bottle: preparedBottle, engine: engine)
                )
                trackRunningItem(
                    title: text(.windows11Desktop),
                    bottle: preparedBottle,
                    processIdentifier: result.processIdentifier,
                    logName: "\(preparedBottle.id)-windows11-desktop.log",
                    launchKey: launchKey
                )
                refreshRecentLogs()
                finish(text(.launchedPid, text(.windows11Desktop), "\(result.processIdentifier)"))
            }
        } catch {
            fail(error)
        }
    }

    func refreshRunningItems() {
        runningItems.removeAll { !Self.isProcessAlive($0.processIdentifier) }
    }

    func terminateRunningItem(_ item: RunningDesktopItem) {
        if let bottle = bottles.first(where: { $0.id == item.bottleId }) {
            Task { await stopBottleProcesses(bottle) }
            return
        }

        _ = kill(item.processIdentifier, SIGTERM)
        runningItems.removeAll { $0.id == item.id }
        statusMessage = text(.terminatedPid, item.title, "\(item.processIdentifier)")
        lastError = nil
    }

    func openLog(for item: RunningDesktopItem) {
        let url = paths.logsDirectory.appendingPathComponent(item.logName)
        NSWorkspace.shared.open(url)
    }

    func deleteBottle(_ bottle: BottleManifest) async {
        setBusy(text(.deleting, bottle.name))
        do {
            if let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first {
                let paths = paths
                let stopResult = try await Task.detached(priority: .userInitiated) {
                    try BottleRuntimeService(paths: paths).stopAll(in: bottle, engine: engine)
                }.value
                guard stopResult.succeeded else {
                    statusMessage = text(.stoppedBottleProcessesPartial, bottle.name, stopResult.stoppedCount, stopResult.remainingProcessCount)
                    lastError = nil
                    isBusy = false
                    return
                }
                runningItems.removeAll { $0.bottleId == bottle.id }
            }
            try bottleService.deleteBottle(bottle)
            try reloadLocalState()
            selectedBottleId = bottles.first?.id
            finish(text(.deleted, bottle.name))
        } catch {
            fail(error)
        }
    }

    func runDiagnostics() async {
        guard let engine = preferredEngine() else {
            fail(MacWinError.unsupportedEngine(text(.noEngineRegistered)))
            return
        }
        setBusy(text(.runningDiagnostics))
        do {
            let paths = paths
            let existingBottle = bottles.first(where: { $0.name == "Diagnostics" })
            let run = try await Task.detached(priority: .userInitiated) {
                let bottleService = BottleService(paths: paths)
                let bottle = try existingBottle ?? bottleService.createBottle(
                    name: "Diagnostics",
                    template: BottleTemplate(windowsVersion: "win11", arch: .win64),
                    engine: engine,
                    runWineboot: true
                )
                let preparedBottle = try bottleService.bootstrapWinePrefixIfNeeded(
                    bottle: bottle,
                    engine: engine
                )
                let report = try DiagnosticsService(paths: paths).runProbeSuite(
                    engine: engine,
                    bottle: preparedBottle
                )
                _ = try DiagnosticsHistoryService(paths: paths).save(
                    report: report,
                    scope: .suite,
                    engine: engine,
                    bottle: preparedBottle
                )
                return DetachedDiagnosticsRun(bottle: preparedBottle, report: report)
            }.value

            diagnosticReport = run.report
            try reloadLocalState(refreshReports: false)
            refreshDiagnosticHistory()
            refreshRecentLogs()
            finish(diagnosticReport?.exitCode == 0 ? text(.diagnosticsPassed) : text(.diagnosticsFinishedWithFailures))
        } catch {
            fail(error)
        }
    }

    func canRunNativeUIProbe(
        mode _: NativeUIProbeMode,
        architecture: WindowsExecutableArchitecture = .x86_64
    ) -> Bool {
        guard hostGUISessionReport.isInteractive else { return false }
        guard nativeUIProbeService.executable(for: architecture) != nil else { return false }
        let targetEngine = selectedBottle
            .flatMap { bottle in engines.first(where: { $0.id == bottle.engineId }) }
            ?? preferredEngine()
        if architecture == .i386 {
            return targetEngine?.supportsWin32 == true
        }
        return targetEngine != nil
    }

    func runNativeUIProbe(
        mode: NativeUIProbeMode,
        architecture: WindowsExecutableArchitecture = .x86_64
    ) async {
        refreshNativeUIProbeState()
        guard hostGUISessionReport.isInteractive else {
            statusMessage = text(.nativeUIProbeSessionLocked)
            lastError = nil
            return
        }
        guard canRunNativeUIProbe(mode: mode, architecture: architecture) else {
            fail(MacWinError.missingFile("Native UI probe or compatible engine is unavailable."))
            return
        }
        guard let fallbackEngine = preferredEngine() else {
            fail(MacWinError.unsupportedEngine(text(.noEngineRegistered)))
            return
        }

        let targetBottle: BottleManifest
        let targetEngine: EngineManifest
        do {
            if let selectedBottle,
               let selectedEngine = engines.first(where: { $0.id == selectedBottle.engineId }) {
                targetBottle = try bottleService.bootstrapWinePrefixIfNeeded(
                    bottle: selectedBottle,
                    engine: selectedEngine
                )
                targetEngine = selectedEngine
            } else {
                targetBottle = try bottleService.bootstrapWinePrefixIfNeeded(
                    bottle: ensureDiagnosticsBottle(engine: fallbackEngine),
                    engine: fallbackEngine
                )
                targetEngine = fallbackEngine
            }
        } catch {
            fail(error)
            return
        }

        setBusy(text(.runningNativeUIProbe, AppText.nativeUIProbeModeName(mode, language: language)))
        do {
            let report = try diagnosticsService.runNativeUIProbe(
                mode: mode,
                architecture: architecture,
                engine: targetEngine,
                bottle: targetBottle,
                probeService: nativeUIProbeService
            )
            _ = try nativeUIProbeHistoryService.save(report)
            nativeUIProbeLastRunReport = report
            refreshNativeUIProbeState()
            try reloadLocalState()
            switch report.status {
            case .passed:
                finish(text(.nativeUIProbePassed, AppText.nativeUIProbeModeName(mode, language: language)))
            case .cancelled:
                finish(text(.nativeUIProbeCancelled, AppText.nativeUIProbeModeName(mode, language: language)))
            case .failed:
                finish(text(.diagnosticsFinishedWithFailures))
            }
        } catch {
            fail(error)
        }
    }

    func canRunProbe(assetId: String) -> Bool {
        guard let probe = testAssetService.runCommand(forAssetId: assetId) else { return false }
        return probe.exists && probe.command != nil
    }

    func runProbe(assetId: String) async {
        guard canRunProbe(assetId: assetId) else {
            fail(MacWinError.unsupportedEngine("Probe \(assetId) cannot be run individually."))
            return
        }
        guard let engine = preferredEngine() else {
            fail(MacWinError.unsupportedEngine(text(.noEngineRegistered)))
            return
        }
        setBusy(text(.runningProbe, assetId))
        do {
            let bottle = try bottleService.bootstrapWinePrefixIfNeeded(
                bottle: ensureDiagnosticsBottle(engine: engine),
                engine: engine
            )
            let report = try diagnosticsService.runProbe(
                assetId: assetId,
                engine: engine,
                bottle: bottle,
                testAssetService: testAssetService
            )
            _ = try diagnosticsHistoryService.save(
                report: report,
                scope: .probe,
                engine: engine,
                bottle: bottle,
                assetId: assetId
            )
            diagnosticReport = report
            try reloadLocalState()
            let succeeded = diagnosticReport?.exitCode == 0
            finish(succeeded ? text(.probeFinished, assetId) : text(.diagnosticsFinishedWithFailures))
        } catch {
            fail(error)
        }
    }

    func runProbes(assetIds: [String]) async {
        let runnable = orderedUnique(assetIds).filter { canRunProbe(assetId: $0) }
        guard !runnable.isEmpty else {
            fail(MacWinError.unsupportedEngine("No runnable probes in selection."))
            return
        }
        guard let engine = preferredEngine() else {
            fail(MacWinError.unsupportedEngine(text(.noEngineRegistered)))
            return
        }
        setBusy(text(.runningProbeBatch, runnable.count))
        do {
            let bottle = try bottleService.bootstrapWinePrefixIfNeeded(
                bottle: ensureDiagnosticsBottle(engine: engine),
                engine: engine
            )
            var lastReport: DiagnosticReport?
            var failedCount = 0
            for assetId in runnable {
                statusMessage = text(.runningProbe, assetId)
                let report = try diagnosticsService.runProbe(
                    assetId: assetId,
                    engine: engine,
                    bottle: bottle,
                    testAssetService: testAssetService
                )
                _ = try diagnosticsHistoryService.save(
                    report: report,
                    scope: .batch,
                    engine: engine,
                    bottle: bottle,
                    assetId: assetId,
                    assetIds: runnable
                )
                lastReport = report
                if report.exitCode != 0 {
                    failedCount += 1
                }
            }
            diagnosticReport = lastReport
            try reloadLocalState()
            finish(failedCount == 0 ? text(.probeBatchFinished, runnable.count) : text(.diagnosticsFinishedWithFailures))
        } catch {
            fail(error)
        }
    }

    func openDriveC(for bottle: BottleManifest) {
        let url = paths.bottleDriveCURL(id: bottle.id)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openLogs() {
        refreshRecentLogs()
        NSWorkspace.shared.open(paths.logsDirectory)
    }

    func refreshDiagnosticHistory() {
        diagnosticHistoryReport = diagnosticsHistoryService.report(limit: 40)
    }

    func openDiagnosticRunLog(_ record: DiagnosticRunRecord) {
        guard !record.logPath.isEmpty else { return }
        let url = URL(fileURLWithPath: record.logPath)
        NSWorkspace.shared.open(url)
    }

    func revealDiagnosticRunLog(_ record: DiagnosticRunRecord) {
        guard !record.logPath.isEmpty else { return }
        let url = URL(fileURLWithPath: record.logPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openNativeUIProbeLog(_ report: NativeUIProbeRunReport) {
        guard !report.logPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: report.logPath))
    }

    func revealNativeUIProbeLog(_ report: NativeUIProbeRunReport) {
        guard !report.logPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.logPath)])
    }

    func openDiagnosticArtifact(_ artifact: DiagnosticArtifactItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: artifact.path))
    }

    func revealDiagnosticArtifact(_ artifact: DiagnosticArtifactItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
    }

    func openDownloads() {
        try? FileManager.default.createDirectory(at: paths.downloadsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.downloadsDirectory)
    }

    func downloadInstaller(recipeId: String) async {
        guard let recipe = recipes.first(where: { $0.id == recipeId }) else {
            fail(MacWinError.invalidManifest("Unknown recipe id: \(recipeId)"))
            return
        }
        setBusy(text(.downloadingInstaller, recipe.name))
        do {
            let result = try installerAssetService.cacheInstaller(for: recipe)
            refreshRecentLogs()
            finish(text(.installerDownloaded, result.fileName))
        } catch {
            fail(error)
        }
    }

    func downloadInstallers(recipeIds: [String]) async {
        let ids = orderedUnique(recipeIds)
        let selectedRecipes = ids.compactMap { id in
            recipes.first { $0.id == id }
        }
        guard !selectedRecipes.isEmpty else {
            fail(MacWinError.invalidManifest("No downloadable recipes selected."))
            return
        }
        setBusy(text(.downloadingInstallerBatch, selectedRecipes.count))
        do {
            var completed = 0
            for recipe in selectedRecipes {
                statusMessage = text(.downloadingInstaller, recipe.name)
                _ = try installerAssetService.cacheInstaller(for: recipe)
                completed += 1
            }
            refreshRecentLogs()
            finish(text(.installerDownloadBatchFinished, completed))
        } catch {
            refreshSoftwareTestPlan()
            fail(error)
        }
    }

    func runSoftwareAction(recipeId: String) async {
        let report = softwareTestPlanReport ?? capabilityReportService.makeReport(
            engines: engines,
            bottles: bottles,
            recipes: recipes,
            diagnosticReport: diagnosticReport
        ).softwareTestPlan
        guard let entry = report.entries.first(where: { $0.recipeId == recipeId }),
              let recipe = recipes.first(where: { $0.id == recipeId }) else {
            fail(MacWinError.invalidManifest("Unknown software action recipe id: \(recipeId)"))
            return
        }
        guard !isBusy, !softwareActionRecipeIdsInFlight.contains(recipeId) else {
            statusMessage = text(.actionAlreadyInProgress, recipe.name)
            lastError = nil
            return
        }

        softwareActionRecipeIdsInFlight.insert(recipeId)
        defer { softwareActionRecipeIdsInFlight.remove(recipeId) }

        switch entry.state {
        case .missingInstaller, .hashMismatch:
            await downloadInstaller(recipeId: recipeId)
        case .readyToInstall, .installFailed:
            guard recipe.installer.mode != .localFile else {
                fail(MacWinError.installerRequired(recipe.id))
                return
            }
            await install(recipe: recipe)
        case .installerLaunched:
            guard let bottle = defaultPerformanceBottle ?? selectedBottle ?? bottles.first else {
                fail(MacWinError.unsupportedEngine(text(.noEngineRegistered)))
                return
            }
            await scanInstalledApps(in: bottle)
        case .installedNotLaunched:
            guard let pair = launcherPair(forRecipeId: recipeId) else {
                fail(MacWinError.missingFile("No launcher generated for \(recipe.name)"))
                return
            }
            await runLauncher(pair.launcher, in: pair.bottle)
        case .launchFailed, .needsReview:
            guard let pair = launcherPair(forRecipeId: recipeId) else {
                if let path = entry.latestLaunchLogPath ?? entry.latestInstallLogPath, !path.isEmpty {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    return
                }
                fail(MacWinError.missingFile("No launcher or log available for \(recipe.name)"))
                return
            }
            await runLauncherWithDiagnostics(pair.launcher, in: pair.bottle)
        case .blocked, .localInstallerRequired, .existingInstallMissing, .disabled, .verified:
            statusMessage = AppText.softwareTestPlanAction(entry, language: language)
            lastError = nil
        }
    }

    func refreshRecentLogs() {
        reportRefreshTask?.cancel()
        let paths = paths
        let engines = engines
        let bottles = bottles
        let recipes = recipes
        let diagnosticReport = diagnosticReport
        let testAssetRoot = testAssetService.root
        reportRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                let logService = LogService(paths: paths, fileManager: fileManager)
                let recentLogs = logService.recentLogs()
                let capabilityReport = CapabilityReportService(
                    paths: paths,
                    fileManager: fileManager,
                    testAssetService: TestAssetService(root: testAssetRoot, fileManager: fileManager)
                ).makeReport(
                    engines: engines,
                    bottles: bottles,
                    recipes: recipes,
                    diagnosticReport: diagnosticReport
                )
                let foundationStatusSnapshotService = FoundationStatusSnapshotService(
                    paths: paths,
                    fileManager: fileManager
                )
                let foundationStatusSnapshot = foundationStatusSnapshotService.makeSnapshot(report: capabilityReport)
                do {
                    _ = try foundationStatusSnapshotService.exportSnapshot(report: capabilityReport)
                } catch {
                    // A failed background snapshot must not block the live report refresh.
                }
                return BackgroundReportRefresh(
                    recentLogs: recentLogs,
                    logIssueReport: LogService.issueReport(logs: recentLogs),
                    logMaintenanceReport: logService.maintenanceReport(),
                    diagnosticArtifactIndexReport: DiagnosticArtifactIndexService(
                        paths: paths,
                        fileManager: fileManager
                    ).report(limit: 80),
                    capabilityReport: capabilityReport,
                    foundationStatusSnapshot: foundationStatusSnapshot
                )
            }.value

            guard !Task.isCancelled, let self else { return }
            self.recentLogs = result.recentLogs
            self.logIssueReport = result.logIssueReport
            self.logMaintenanceReport = result.logMaintenanceReport
            self.diagnosticArtifactIndexReport = result.diagnosticArtifactIndexReport
            self.applyCapabilityReport(result.capabilityReport)
            self.foundationStatusSnapshot = result.foundationStatusSnapshot
        }
    }

    func refreshDiagnosticsPage() {
        refreshDiagnosticHistory()
        refreshRecentLogs()
    }

    func refreshDiagnosticArtifacts() {
        diagnosticArtifactIndexReport = diagnosticArtifactIndexService.report(limit: 80)
        statusMessage = text(.diagnosticArtifactsSummary, diagnosticArtifactIndexReport.artifactCount, Double(diagnosticArtifactIndexReport.totalBytes) / 1_048_576.0)
        lastError = nil
    }

    func openLogIssueSample(_ sample: LogIssueSample) {
        NSWorkspace.shared.open(URL(fileURLWithPath: sample.path))
    }

    func revealLogIssueSample(_ sample: LogIssueSample) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sample.path)])
    }

    func openTestRunLog(_ run: TestCoverageRunSummary) {
        guard !run.logPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: run.logPath))
    }

    func revealTestRunLog(_ run: TestCoverageRunSummary) {
        guard !run.logPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.logPath)])
    }

    func refreshSoftwareTestPlan() {
        let report = capabilityReportService.makeReport(
            engines: engines,
            bottles: bottles,
            recipes: recipes,
            diagnosticReport: diagnosticReport
        )
        applyCapabilityReport(report)
        refreshFoundationStatusSnapshot(from: report)
    }

    private func applyCapabilityReport(_ report: CapabilityReport) {
        softwareTestPlanReport = report.softwareTestPlan
        softwareSmokeMatrixReport = report.softwareSmokeMatrix
        softwareSampleCatalogReport = report.softwareSampleCatalog
        softwareSamplePreparationReport = softwareSampleCatalogService.preparationReport(
            catalog: report.softwareSampleCatalog,
            generatedAt: report.generatedAt
        )
        softwareSampleLogCorrelationReport = report.softwareSampleLogCorrelation
        nativeUIBridgeHealthReport = report.nativeUIBridgeHealth ?? nativeUIBridgeHealthService.report(
            engines: engines,
            generatedAt: report.generatedAt
        )
        nativeUIApplicationMatrixReport = report.nativeUIApplicationMatrix ?? nativeUIApplicationMatrixService.report(
            bottles: bottles,
            recipes: recipes,
            launchHistory: report.launchHistory,
            smokeReports: report.softwareSmokeRuns?.reports ?? [],
            generatedAt: report.generatedAt
        )
        let representativeAcceptanceService = RepresentativeSoftwareAcceptanceService(paths: paths)
        representativeAcceptanceReport = representativeAcceptanceService.report(
            matrix: nativeUIApplicationMatrixReport,
            generatedAt: report.generatedAt
        )
        _ = try? representativeAcceptanceService.save(representativeAcceptanceReport)
        softwareCollectionReport = makeSoftwareCollectionReport(from: report)
        softwareCollectionAcceptanceReport = SoftwareCollectionAcceptanceService().report(
            collection: softwareCollectionReport,
            smokeMatrix: report.softwareSmokeMatrix,
            testExecutionPlan: report.testExecutionPlan,
            logIssues: report.logs.issueReport,
            generatedAt: report.generatedAt
        )
        supportTriageReport = makeSupportTriageReport(from: report)
        installerAssetReport = report.installerAssets
        installerPreparationReport = InstallerAssetService.preparationReport(for: report.installerAssets)
        installerDownloadHistoryReport = report.installerDownloadHistory
        activityTimelineReport = report.activityTimeline
        compatibilityRepairAuditReport = report.compatibilityRepairAudit
        bottleHealthReport = report.bottleHealth
        runtimeProcessAuditReport = report.runtimeProcesses ?? RuntimeProcessAuditReport(
            observedProcessCount: 0,
            auditedProcessCount: 0,
            staleRenderingProcessCount: 0,
            entries: [],
            findings: []
        )
        testCoverageReport = report.testCoverage
        testExecutionPlanReport = report.testExecutionPlan
    }

    private func refreshFoundationStatusSnapshot(from report: CapabilityReport? = nil) {
        guard !suppressFoundationStatusSnapshot else { return }
        let capability = report ?? capabilityReportService.makeReport(
            engines: engines,
            bottles: bottles,
            recipes: recipes,
            diagnosticReport: diagnosticReport
        )
        foundationStatusSnapshot = foundationStatusSnapshotService.makeSnapshot(report: capability)
        do {
            let result = try foundationStatusSnapshotService.exportSnapshot(report: capability)
            NSLog("MacWin foundation status snapshot exported path=\(result.latestSnapshotURL.path)")
        } catch {
            NSLog("MacWin foundation status snapshot export failed: \(error.localizedDescription)")
        }
    }

    func refreshSupportTriage() {
        refreshSoftwareTestPlan()
        statusMessage = text(.supportTriageRefreshed, supportTriageReport.itemCount)
        lastError = nil
    }

    func refreshRuntimeProcesses() {
        runtimeProcessAuditReport = runtimeProcessAuditService.makeReport()
        statusMessage = text(.runtimeProcessesRefreshed, runtimeProcessAuditReport.auditedProcessCount)
        lastError = nil
    }

    func exportRuntimeProcessSnapshot() {
        setBusy(text(.exportingRuntimeSnapshot))
        do {
            let report = runtimeProcessAuditService.makeReport()
            runtimeProcessAuditReport = report
            let artifact = try RuntimeProcessSnapshotService(paths: paths).writeSnapshot(report: report)
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([artifact.logURL])
            finish(text(.runtimeSnapshotExported, artifact.logURL.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportRuntimeProcessesCSV() {
        setBusy(text(.exportingRuntimeProcessesCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = runtimeProcessAuditService.makeReport()
            runtimeProcessAuditReport = report
            let url = paths.logsDirectory.appendingPathComponent("runtime-processes.csv")
            try Data(RuntimeProcessAuditReport.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.runtimeProcessesCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func terminateRuntimeProcess(_ entry: RuntimeProcessEntry) {
        let result = runtimeProcessTerminator.terminate(entries: [entry])
        if result.failedCount == 0 {
            refreshRunningItems()
            runtimeProcessAuditReport = runtimeProcessAuditService.makeReport()
            statusMessage = text(.terminatedRuntimeProcess, entry.executableName, "\(entry.processIdentifier)")
            lastError = nil
        } else {
            let message = "PID \(entry.processIdentifier)"
            lastError = text(.processFailed, entry.executableName, message)
            statusMessage = text(.runtimeProcesses)
        }
    }

    func terminateAllRuntimeProcesses() {
        let report = runtimeProcessAuditService.makeReport()
        let entries = report.entries
        guard !entries.isEmpty else {
            runtimeProcessAuditReport = report
            statusMessage = text(.noRuntimeProcessesToStop)
            lastError = nil
            return
        }

        let result = runtimeProcessTerminator.terminateAllRuntimeProcesses(in: report)
        refreshRunningItems()
        runtimeProcessAuditReport = runtimeProcessAuditService.makeReport()
        if result.failedCount == 0 {
            statusMessage = text(.terminatedRuntimeProcesses, result.stoppedCount)
            lastError = nil
        } else {
            statusMessage = text(.runtimeProcesses)
            lastError = text(.terminatedRuntimeProcessesPartial, result.stoppedCount, result.failedCount)
        }
    }

    func terminateWineVirtualDesktopProcesses() {
        let report = runtimeProcessAuditService.makeReport()
        let entries = report.entries.filter { $0.isWineVirtualDesktop || $0.isWineDeviceService }
        guard !entries.isEmpty else {
            runtimeProcessAuditReport = report
            statusMessage = text(.noRuntimeProcessesToStop)
            lastError = nil
            return
        }

        let result = runtimeProcessTerminator.terminateWineVirtualDesktopProcesses(in: report)
        refreshRunningItems()
        runtimeProcessAuditReport = runtimeProcessAuditService.makeReport()
        if result.failedCount == 0 {
            statusMessage = text(.terminatedWineVirtualDesktops, result.stoppedCount)
            lastError = nil
        } else {
            statusMessage = text(.runtimeProcesses)
            lastError = text(.terminatedRuntimeProcessesPartial, result.stoppedCount, result.failedCount)
        }
    }

    func terminateDetachedWineSystemProcesses() {
        let report = runtimeProcessAuditService.makeReport()
        guard !report.detachedWineSystemEntries.isEmpty else {
            runtimeProcessAuditReport = report
            statusMessage = text(.noRuntimeProcessesToStop)
            lastError = nil
            return
        }

        let result = runtimeProcessTerminator.terminateDetachedWineSystemProcesses(in: report)
        refreshRunningItems()
        runtimeProcessAuditReport = runtimeProcessAuditService.makeReport()
        if result.failedCount == 0 {
            statusMessage = text(.terminatedDetachedWineSystemProcesses, result.stoppedCount)
            lastError = nil
        } else {
            statusMessage = text(.runtimeProcesses)
            lastError = text(.terminatedRuntimeProcessesPartial, result.stoppedCount, result.failedCount)
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private func launcherPair(forRecipeId recipeId: String) -> (bottle: BottleManifest, launcher: LauncherManifest)? {
        for bottle in bottles {
            if let launcher = bottle.installedApps.first(where: { $0.appId == recipeId }) {
                return (bottle, launcher)
            }
        }
        guard let recipe = recipes.first(where: { $0.id == recipeId }) else { return nil }
        let expectedPaths = Set(recipe.launchers.map { normalizeWindowsPath($0.exePath) })
        let expectedIds = Set(recipe.launchers.map(\.id))
        for bottle in bottles {
            if let launcher = bottle.installedApps.first(where: {
                expectedIds.contains($0.id) || expectedPaths.contains(normalizeWindowsPath($0.exePath))
            }) {
                return (bottle, launcher)
            }
        }
        return nil
    }

    private func normalizeWindowsPath(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "\\")
            .lowercased()
    }

    private func currentSoftwareCollectionReport() -> SoftwareCollectionReport {
        let report = capabilityReportService.makeReport(
            engines: engines,
            bottles: bottles,
            recipes: recipes,
            diagnosticReport: diagnosticReport
        )
        let collection = makeSoftwareCollectionReport(from: report)
        softwareCollectionReport = collection
        return collection
    }

    private func makeSoftwareCollectionReport(from report: CapabilityReport) -> SoftwareCollectionReport {
        let adaptationQueue = SoftwareAdaptationQueueService(paths: paths).report(
            softwareTestPlan: report.softwareTestPlan,
            softwareSmokeMatrix: report.softwareSmokeMatrix,
            logIssues: report.logs.issueReport,
            testAssets: report.testAssets
        )
        return SoftwareCollectionService(paths: paths).report(
            recipes: recipes,
            readiness: report.recipeReadiness,
            installerAssets: report.installerAssets,
            softwareTestPlan: report.softwareTestPlan,
            softwareSmokeMatrix: report.softwareSmokeMatrix,
            adaptationQueue: adaptationQueue
        )
    }

    private func makeSupportTriageReport(from report: CapabilityReport) -> SupportTriageReport {
        let samplePreparation = softwareSampleCatalogService.preparationReport(
            catalog: report.softwareSampleCatalog,
            generatedAt: report.generatedAt
        )
        let softwareAcquisition = SoftwareAcquisitionService().report(
            collection: softwareCollectionReport,
            samplePreparation: samplePreparation,
            generatedAt: report.generatedAt
        )
        let launchHealth = LaunchHealthService(paths: paths).report(
            launchHistory: report.launchHistory,
            logs: report.logs,
            smokeReports: report.softwareSmokeRuns?.reports ?? [],
            generatedAt: report.generatedAt
        )
        let externalOpenQueue = ExternalExecutableOpenQueueService(paths: paths).report(
            generatedAt: report.generatedAt
        )
        return SupportTriageService().report(
            generatedAt: report.generatedAt,
            capability: report,
            logRemediation: LogService.remediationPlan(report: report.logs.issueReport, generatedAt: report.generatedAt),
            softwareAcceptance: softwareCollectionAcceptanceReport,
            softwareAcquisition: softwareAcquisition,
            launchHealth: launchHealth,
            externalOpenQueue: externalOpenQueue
        )
    }

    private func makeSoftwareAdaptationQueueReport(
        generatedAt: Date = Date(),
        logLimit: Int = 80
    ) -> SoftwareAdaptationQueueReport {
        let capability = capabilityReportService.makeReport(
            generatedAt: generatedAt,
            engines: engines,
            bottles: bottles,
            recipes: recipes,
            diagnosticReport: diagnosticReport,
            logLimit: logLimit
        )
        softwareTestPlanReport = capability.softwareTestPlan
        softwareSmokeMatrixReport = capability.softwareSmokeMatrix
        testAssetReport = capability.testAssets
        logIssueReport = capability.logs.issueReport
        return SoftwareAdaptationQueueService(paths: paths).report(
            softwareTestPlan: capability.softwareTestPlan,
            softwareSmokeMatrix: capability.softwareSmokeMatrix,
            logIssues: capability.logs.issueReport,
            testAssets: capability.testAssets,
            generatedAt: generatedAt
        )
    }

    private func saveSoftwareCollectionAction(
        action: SoftwareCollectionAction,
        state: SoftwareCollectionActionState,
        collection: SoftwareCollectionReport,
        startedAt: Date,
        recipeIds: [String]? = nil,
        completedRecipeIds: [String] = [],
        outputPath: String? = nil,
        errorMessage: String? = nil
    ) {
        let record = SoftwareCollectionHistoryService.record(
            action: action,
            state: state,
            collection: collection,
            startedAt: startedAt,
            endedAt: Date(),
            recipeIds: recipeIds,
            completedRecipeIds: completedRecipeIds,
            outputPath: outputPath,
            errorMessage: errorMessage
        )
        try? softwareCollectionHistoryService.save(record)
    }

    func exportInstallerDownloadScript() {
        setBusy(text(.exportingInstallerDownloadScript))
        do {
            try paths.ensureBaseDirectories()
            let report = installerAssetReport ?? capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).installerAssets
            let url = paths.logsDirectory.appendingPathComponent("download-installers.sh")
            try Data(InstallerAssetService.shellScript(for: report).utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.installerDownloadScriptExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportInstallerAssetCSV() {
        setBusy(text(.exportingInstallerAssetCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = installerAssetReport ?? capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).installerAssets
            let url = paths.logsDirectory.appendingPathComponent("installer-assets.csv")
            try Data(InstallerAssetService.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.installerAssetCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportInstallerPreparationCSV() {
        setBusy(text(.exportingInstallerPreparationCSV))
        do {
            try paths.ensureBaseDirectories()
            let assetReport = installerAssetReport ?? capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).installerAssets
            let report = InstallerAssetService.preparationReport(for: assetReport)
            installerPreparationReport = report
            let url = paths.logsDirectory.appendingPathComponent("installer-preparation.csv")
            try Data(InstallerAssetService.preparationCSV(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.installerPreparationCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportInstallerDownloadHistoryCSV() {
        setBusy(text(.exportingInstallerDownloadHistoryCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = installerDownloadHistoryReport ?? InstallerDownloadHistoryService(paths: paths).report()
            let url = paths.logsDirectory.appendingPathComponent("installer-download-history.csv")
            try Data(InstallerDownloadHistoryService.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.installerDownloadHistoryCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareTestPlanCSV() {
        setBusy(text(.exportingSoftwareTestPlanCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = softwareTestPlanReport ?? capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).softwareTestPlan
            let url = paths.logsDirectory.appendingPathComponent("software-test-plan.csv")
            try Data(SoftwareTestPlanService.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareTestPlanCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareAdaptationQueueCSV() {
        setBusy(text(.exportingSoftwareAdaptationQueueCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = makeSoftwareAdaptationQueueReport()
            let url = paths.logsDirectory.appendingPathComponent("software-adaptation-queue.csv")
            try Data(SoftwareAdaptationQueueService.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareAdaptationQueueCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareAdaptationProbeScript() {
        setBusy(text(.exportingSoftwareAdaptationProbeScript))
        do {
            try paths.ensureBaseDirectories()
            let report = makeSoftwareAdaptationQueueReport()
            let url = paths.logsDirectory.appendingPathComponent("software-adaptation-probes.sh")
            try Data(SoftwareAdaptationQueueService.shellScript(report: report).utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareAdaptationProbeScriptExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareSampleCatalogCSV() {
        setBusy(text(.exportingSoftwareSampleCatalogCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = softwareSampleCatalogService.report(recipes: recipes)
            softwareSampleCatalogReport = report
            let url = paths.logsDirectory.appendingPathComponent("software-sample-catalog.csv")
            try Data(SoftwareSampleCatalogService.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareSampleCatalogCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareSampleCatalogRunbook() {
        setBusy(text(.exportingSoftwareSampleCatalogRunbook))
        do {
            try paths.ensureBaseDirectories()
            let report = softwareSampleCatalogService.report(recipes: recipes)
            softwareSampleCatalogReport = report
            let url = paths.logsDirectory.appendingPathComponent("software-sample-catalog-runbook.md")
            try Data(SoftwareSampleCatalogService.runbookMarkdown(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareSampleCatalogRunbookExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareSamplePreparationSnapshot() {
        setBusy(text(.exportingSoftwareSamplePreparationSnapshot))
        do {
            try paths.ensureBaseDirectories()
            let catalog = softwareSampleCatalogService.report(recipes: recipes)
            softwareSampleCatalogReport = catalog
            let result = try softwareSampleCatalogService.exportPreparationSnapshot(catalog: catalog)
            softwareSamplePreparationReport = result.report
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([result.directoryURL])
            finish(text(.softwareSamplePreparationSnapshotExported, result.directoryURL.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareCollectionCSV() {
        setBusy(text(.exportingSoftwareCollectionCSV))
        let startedAt = Date()
        do {
            try paths.ensureBaseDirectories()
            let report = currentSoftwareCollectionReport()
            let url = paths.logsDirectory.appendingPathComponent("software-collection.csv")
            try Data(SoftwareCollectionService.csv(report: report).utf8).write(to: url, options: [.atomic])
            saveSoftwareCollectionAction(
                action: .exportCSV,
                state: .succeeded,
                collection: report,
                startedAt: startedAt,
                outputPath: url.path
            )
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareCollectionCSVExported, url.lastPathComponent))
        } catch {
            let report = softwareCollectionReport
            saveSoftwareCollectionAction(
                action: .exportCSV,
                state: .failed,
                collection: report,
                startedAt: startedAt,
                errorMessage: error.localizedDescription
            )
            fail(error)
        }
    }

    func exportSoftwareCollectionDownloadScript() {
        setBusy(text(.exportingSoftwareCollectionDownloadScript))
        let startedAt = Date()
        do {
            try paths.ensureBaseDirectories()
            let report = currentSoftwareCollectionReport()
            let url = paths.logsDirectory.appendingPathComponent("software-collection-downloads.sh")
            try Data(SoftwareCollectionService.downloadScript(report: report).utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            saveSoftwareCollectionAction(
                action: .exportDownloadScript,
                state: .succeeded,
                collection: report,
                startedAt: startedAt,
                outputPath: url.path
            )
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareCollectionDownloadScriptExported, url.lastPathComponent))
        } catch {
            let report = softwareCollectionReport
            saveSoftwareCollectionAction(
                action: .exportDownloadScript,
                state: .failed,
                collection: report,
                startedAt: startedAt,
                errorMessage: error.localizedDescription
            )
            fail(error)
        }
    }

    func exportSoftwareCollectionBundle() {
        setBusy(text(.exportingSoftwareCollectionBundle))
        let startedAt = Date()
        do {
            try paths.ensureBaseDirectories()
            let capability = capabilityReportService.makeReport(
                generatedAt: startedAt,
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport,
                logLimit: 80
            )
            let collection = makeSoftwareCollectionReport(from: capability)
            softwareCollectionReport = collection
            let acceptance = SoftwareCollectionAcceptanceService().report(
                collection: collection,
                smokeMatrix: capability.softwareSmokeMatrix,
                testExecutionPlan: capability.testExecutionPlan,
                logIssues: capability.logs.issueReport,
                generatedAt: startedAt
            )
            softwareCollectionAcceptanceReport = acceptance
            let samplePreparation = softwareSampleCatalogService.preparationReport(
                catalog: capability.softwareSampleCatalog,
                generatedAt: startedAt
            )
            _ = try softwareSampleCatalogService.exportPreparationSnapshot(
                report: samplePreparation,
                generatedAt: startedAt
            )
            softwareSamplePreparationReport = samplePreparation
            let softwareAcquisition = SoftwareAcquisitionService().report(
                collection: collection,
                samplePreparation: samplePreparation,
                generatedAt: startedAt
            )
            let launchHealth = LaunchHealthService(paths: paths).report(
                launchHistory: capability.launchHistory,
                logs: capability.logs,
                smokeReports: capability.softwareSmokeRuns?.reports ?? [],
                generatedAt: startedAt
            )
            let externalOpenQueue = ExternalExecutableOpenQueueService(paths: paths).report(
                generatedAt: startedAt
            )
            let supportTriage = SupportTriageService().report(
                generatedAt: startedAt,
                capability: capability,
                logRemediation: LogService.remediationPlan(report: capability.logs.issueReport, generatedAt: startedAt),
                softwareAcceptance: acceptance,
                softwareAcquisition: softwareAcquisition,
                launchHealth: launchHealth,
                externalOpenQueue: externalOpenQueue
            )
            supportTriageReport = supportTriage
            let history = softwareCollectionHistoryService.report(limit: 200)
            let result = try SoftwareCollectionBundleService(paths: paths).exportBundle(
                collection: collection,
                history: history,
                logIssues: capability.logs.issueReport,
                smokeMatrix: capability.softwareSmokeMatrix,
                testExecutionPlan: capability.testExecutionPlan,
                softwareAcquisition: softwareAcquisition,
                softwareSamplePreparation: samplePreparation,
                launchHealth: launchHealth,
                externalOpenQueue: externalOpenQueue,
                supportTriage: supportTriage,
                generatedAt: startedAt
            )
            saveSoftwareCollectionAction(
                action: .exportBundle,
                state: .succeeded,
                collection: collection,
                startedAt: startedAt,
                outputPath: result.bundleURL.path
            )
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([result.bundleURL])
            finish(text(.softwareCollectionBundleExported, result.bundleURL.lastPathComponent))
        } catch {
            let report = softwareCollectionReport
            saveSoftwareCollectionAction(
                action: .exportBundle,
                state: .failed,
                collection: report,
                startedAt: startedAt,
                errorMessage: error.localizedDescription
            )
            fail(error)
        }
    }

    func exportSoftwareCollectionAcceptanceRunbook() {
        setBusy(text(.exportingSoftwareCollectionAcceptanceRunbook))
        let startedAt = Date()
        do {
            try paths.ensureBaseDirectories()
            let capability = capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport,
                logLimit: 80
            )
            let collection = makeSoftwareCollectionReport(from: capability)
            softwareCollectionReport = collection
            let acceptance = SoftwareCollectionAcceptanceService().report(
                collection: collection,
                smokeMatrix: capability.softwareSmokeMatrix,
                testExecutionPlan: capability.testExecutionPlan,
                logIssues: capability.logs.issueReport,
                generatedAt: startedAt
            )
            softwareCollectionAcceptanceReport = acceptance
            let url = paths.logsDirectory.appendingPathComponent("software-collection-acceptance-runbook.sh")
            try Data(SoftwareCollectionAcceptanceReport.runbookScript(report: acceptance).utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            saveSoftwareCollectionAction(
                action: .exportAcceptanceRunbook,
                state: .succeeded,
                collection: collection,
                startedAt: startedAt,
                outputPath: url.path
            )
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareCollectionAcceptanceRunbookExported, url.lastPathComponent))
        } catch {
            let report = softwareCollectionReport
            saveSoftwareCollectionAction(
                action: .exportAcceptanceRunbook,
                state: .failed,
                collection: report,
                startedAt: startedAt,
                errorMessage: error.localizedDescription
            )
            fail(error)
        }
    }

    func downloadMissingSoftwareCollectionInstallers() async {
        let report = currentSoftwareCollectionReport()
        let ids = report.entries
            .filter { entry in
                entry.installerMode == .download
                    && !entry.cachedInstallerExists
                    && entry.installerSourceURL?.isEmpty == false
                    && entry.installerFileName?.isEmpty == false
            }
            .map(\.recipeId)
        let selectedRecipes = ids.compactMap { id in
            recipes.first { $0.id == id }
        }
        guard !selectedRecipes.isEmpty else {
            fail(MacWinError.invalidManifest("No missing downloadable installers in software collection."))
            return
        }
        let startedAt = Date()
        setBusy(text(.downloadingInstallerBatch, selectedRecipes.count))
        var completed: [String] = []
        do {
            for recipe in selectedRecipes {
                statusMessage = text(.downloadingInstaller, recipe.name)
                _ = try installerAssetService.cacheInstaller(for: recipe)
                completed.append(recipe.id)
            }
            refreshRecentLogs()
            saveSoftwareCollectionAction(
                action: .downloadMissingInstallers,
                state: .succeeded,
                collection: currentSoftwareCollectionReport(),
                startedAt: startedAt,
                recipeIds: ids,
                completedRecipeIds: completed
            )
            finish(text(.installerDownloadBatchFinished, completed.count))
        } catch {
            refreshSoftwareTestPlan()
            saveSoftwareCollectionAction(
                action: .downloadMissingInstallers,
                state: .failed,
                collection: softwareCollectionReport,
                startedAt: startedAt,
                recipeIds: ids,
                completedRecipeIds: completed,
                errorMessage: error.localizedDescription
            )
            fail(error)
        }
    }

    func exportTestExecutionPlanCSV() {
        setBusy(text(.exportingTestExecutionPlanCSV))
        do {
            try paths.ensureBaseDirectories()
            let plan = testExecutionPlanReport ?? capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).testExecutionPlan
            let url = paths.logsDirectory.appendingPathComponent("test-execution-plan.csv")
            try Data(TestExecutionPlan.csv(plan: plan).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.testExecutionPlanCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportTestRunHistoryCSV() {
        setBusy(text(.exportingTestRunHistoryCSV))
        do {
            try paths.ensureBaseDirectories()
            let history = capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).testRunHistory
            let url = paths.logsDirectory.appendingPathComponent("test-run-history.csv")
            try Data(TestRunHistoryReport.csv(report: history).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.testRunHistoryCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportTestSessionArchive() {
        setBusy(text(.exportingTestSessionArchive))
        do {
            try paths.ensureBaseDirectories()
            let capability = capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            )
            let artifacts = diagnosticArtifactIndexService.report(limit: 500)
            let collection = makeSoftwareCollectionReport(from: capability)
            let acceptance = SoftwareCollectionAcceptanceService().report(
                collection: collection,
                smokeMatrix: capability.softwareSmokeMatrix,
                testExecutionPlan: capability.testExecutionPlan,
                logIssues: capability.logs.issueReport,
                generatedAt: capability.generatedAt
            )
            let archiveURL = try testSessionArchiveService.exportArchive(
                testAssets: capability.testAssets,
                coverage: capability.testCoverage,
                executionPlan: capability.testExecutionPlan,
                runHistory: capability.testRunHistory,
                logIssues: capability.logs.issueReport,
                diagnosticArtifacts: artifacts,
                softwareSampleCatalog: capability.softwareSampleCatalog,
                softwareSampleLogCorrelation: capability.softwareSampleLogCorrelation,
                softwareCollection: collection,
                softwareCollectionAcceptance: acceptance
            )
            testAssetReport = capability.testAssets
            testCoverageReport = capability.testCoverage
            testExecutionPlanReport = capability.testExecutionPlan
            softwareSampleCatalogReport = capability.softwareSampleCatalog
            softwareSampleLogCorrelationReport = capability.softwareSampleLogCorrelation
            softwareCollectionReport = collection
            softwareCollectionAcceptanceReport = acceptance
            diagnosticArtifactIndexReport = artifacts
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
            finish(text(.testSessionArchiveExported, archiveURL.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportDiagnosticHistoryCSV() {
        setBusy(text(.exportingDiagnosticHistoryCSV))
        do {
            try paths.ensureBaseDirectories()
            let history = diagnosticsHistoryService.report(limit: 500)
            diagnosticHistoryReport = history
            let url = paths.logsDirectory.appendingPathComponent("diagnostic-history.csv")
            try Data(DiagnosticHistoryReport.csv(report: history).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.diagnosticHistoryCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportDiagnosticArtifactIndexCSV() {
        setBusy(text(.exportingDiagnosticArtifactIndexCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = diagnosticArtifactIndexService.report(limit: 500)
            diagnosticArtifactIndexReport = report
            let url = paths.logsDirectory.appendingPathComponent("diagnostic-artifacts.csv")
            try Data(DiagnosticArtifactIndexReport.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.diagnosticArtifactIndexCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportInstallHistoryCSV() {
        setBusy(text(.exportingInstallHistoryCSV))
        do {
            try paths.ensureBaseDirectories()
            let history = capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).installHistory
            let url = paths.logsDirectory.appendingPathComponent("install-history.csv")
            try Data(InstallHistoryReport.csv(report: history).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.installHistoryCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportLaunchHistoryCSV() {
        setBusy(text(.exportingLaunchHistoryCSV))
        do {
            try paths.ensureBaseDirectories()
            let history = capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).launchHistory
            let url = paths.logsDirectory.appendingPathComponent("launch-history.csv")
            try Data(LaunchHistoryReport.csv(report: history).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.launchHistoryCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportLogMaintenanceScript() {
        setBusy(text(.exportingLogMaintenanceScript))
        do {
            try paths.ensureBaseDirectories()
            let report = logMaintenanceReport ?? logService.maintenanceReport()
            let url = paths.logsDirectory.appendingPathComponent("log-maintenance.sh")
            try Data(LogService.maintenanceShellScript(for: report).utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.logMaintenanceScriptExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func archiveCleanupLogs() {
        setBusy(text(.archivingCleanupLogs))
        do {
            try paths.ensureBaseDirectories()
            let report = logMaintenanceReport ?? logService.maintenanceReport()
            guard !report.cleanupCandidates.isEmpty else {
                refreshRecentLogs()
                finish(text(.noCleanupLogsToArchive))
                return
            }
            let result = try logService.archiveCleanupCandidates(report: report)
            refreshRecentLogs()
            let archiveURL = URL(fileURLWithPath: result.archivePath, isDirectory: true)
            NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
            finish(text(.cleanupLogsArchived, result.archivedCount, archiveURL.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func cleanHistoricalLogs() {
        setBusy(text(.cleaningHistoricalLogs))
        do {
            try paths.ensureBaseDirectories()
            let result = try logService.archiveHistoricalFailures()
            refreshRecentLogs()
            finish(text(.historicalLogsCleaned, result.archivedCount))
        } catch {
            fail(error)
        }
    }

    func exportLogIssueReport() {
        setBusy(text(.exportingLogIssueReport))
        do {
            try paths.ensureBaseDirectories()
            let report = logIssueReport.logsAnalyzed > 0 ? logIssueReport : logService.issueReport()
            logIssueReport = report
            let generatedAt = Date()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let timestamp = formatter.string(from: generatedAt)
                .replacingOccurrences(of: ":", with: "")
            let url = paths.logsDirectory.appendingPathComponent("log-issues-\(timestamp).md")
            try Data(LogService.triageMarkdown(report: report, generatedAt: generatedAt).utf8)
                .write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.logIssueReportExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportRecommendedProbeScript() {
        setBusy(text(.exportingRecommendedProbeScript))
        do {
            try paths.ensureBaseDirectories()
            let report = logIssueReport.logsAnalyzed > 0 ? logIssueReport : logService.issueReport()
            logIssueReport = report
            let runbook = testAssetService.runbook()
            let generatedAt = Date()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let timestamp = formatter.string(from: generatedAt)
                .replacingOccurrences(of: ":", with: "")
            let url = paths.logsDirectory.appendingPathComponent("log-issue-probes-\(timestamp).sh")
            try Data(TestAssetService.shellScript(forRecommendedProbes: report, runbook: runbook).utf8)
                .write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.recommendedProbeScriptExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSoftwareAdaptationRunbook() {
        setBusy(text(.exportingSoftwareAdaptationRunbook))
        do {
            try paths.ensureBaseDirectories()
            let generatedAt = Date()
            let report = capabilityReportService.makeReport(
                generatedAt: generatedAt,
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            )
            softwareTestPlanReport = report.softwareTestPlan
            softwareSmokeMatrixReport = report.softwareSmokeMatrix
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let timestamp = formatter.string(from: generatedAt)
                .replacingOccurrences(of: ":", with: "")
            let url = paths.logsDirectory.appendingPathComponent("software-adaptation-runbook-\(timestamp).md")
            try Data(SupportBundleService.softwareAdaptationRunbook(report: report, generatedAt: generatedAt).utf8)
                .write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.softwareAdaptationRunbookExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportCapabilityReport() {
        setBusy(text(.exportingCapabilityReport))
        do {
            let url = try capabilityReportService.exportReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            )
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.capabilityReportExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportHostEnvironmentCSV() {
        setBusy(text(.exportingHostEnvironmentCSV))
        do {
            try paths.ensureBaseDirectories()
            let report = capabilityReportService.makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            ).hostEnvironment
            let url = paths.logsDirectory.appendingPathComponent("host-environment.csv")
            try Data(HostEnvironmentReport.csv(report: report).utf8).write(to: url, options: [.atomic])
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.hostEnvironmentCSVExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func exportSupportBundle() {
        setBusy(text(.exportingSupportBundle))
        do {
            let url = try supportBundleService.exportBundle(
                engines: engines,
                bottles: bottles,
                recipes: recipes,
                diagnosticReport: diagnosticReport
            )
            refreshRecentLogs()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            finish(text(.supportBundleExported, url.lastPathComponent))
        } catch {
            fail(error)
        }
    }

    func openLog(_ item: LogFileItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealLog(_ item: LogFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openBottleDirectory(_ bottle: BottleManifest) {
        let url = paths.bottleDirectory(id: bottle.id)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func ensureDiagnosticsBottle(engine: EngineManifest) throws -> BottleManifest {
        if let existing = bottles.first(where: { $0.name == "Diagnostics" }) {
            return existing
        }
        return try bottleService.createBottle(
            name: "Diagnostics",
            template: BottleTemplate(windowsVersion: "win11", arch: .win64),
            engine: engine,
            runWineboot: true
        )
    }

    private func ensureDefaultPerformanceBottle(engine: EngineManifest, runWineboot: Bool = true) throws -> BottleManifest {
        try bottleService.ensureHighPerformanceBottle(
            name: text(.highPerformanceBottleName),
            engine: engine,
            runWineboot: runWineboot
        )
    }

    private struct DetachedLauncherLaunch: Sendable {
        var bottle: BottleManifest
        var launcher: LauncherManifest
        var result: WineLaunchResult
    }

    private struct DetachedDiagnosticsRun: Sendable {
        var bottle: BottleManifest
        var report: DiagnosticReport
    }

    nonisolated private static func prepareAndLaunchLauncher(
        paths: MacWinPaths,
        bottle: BottleManifest,
        engine: EngineManifest,
        launcher: LauncherManifest,
        logName: String,
        additionalEnvOverrides: [String: String] = [:]
    ) throws -> DetachedLauncherLaunch {
        let bottleService = BottleService(paths: paths)
        let template = BottleTemplate(windowsVersion: bottle.windowsVersion, arch: bottle.arch)
        let envOverrides = bottle.id == BottleService.highPerformanceBottleId
            ? BottleService.highPerformanceEnvOverrides(engine: engine)
            : bottle.envOverrides
        let preparedBottle = try bottleService.ensureBottle(
            id: bottle.id,
            name: bottle.name,
            template: template,
            engine: engine,
            envOverrides: envOverrides,
            enforceEnvOverrides: false
        )
        let refreshedBottle = try bottleService.bottle(id: bottle.id) ?? preparedBottle
        var effectiveLauncher = refreshedBottle.installedApps.first(where: { $0.id == launcher.id }) ?? launcher
        if let profile = ApplicationCompatibilityProfile.current(in: effectiveLauncher)
            ?? ApplicationCompatibilityProfile.matched(
                launcherId: effectiveLauncher.id,
                displayName: effectiveLauncher.displayName,
                exePath: effectiveLauncher.exePath
            ) {
            let migratedLauncher = profile.applied(to: effectiveLauncher)
            if migratedLauncher != effectiveLauncher {
                _ = try bottleService.updateLauncher(migratedLauncher, in: refreshedBottle)
                effectiveLauncher = migratedLauncher
            }
        }

        let hasTextRepair = effectiveLauncher.envOverrides["MACWIN_TEXT_RENDERING_REPAIR"] == "1"
            || effectiveLauncher.envOverrides["MACWIN_HOYOPLAY_TEXT_REPAIR"] == "1"
            || effectiveLauncher.envOverrides["MACWIN_STEAMWEBHELPER_FORCE_OPAQUE"] == "1"
            || effectiveLauncher.envOverrides["MACWIN_LENOVO_BLACK_SCREEN_REPAIR"] == "1"
        if hasTextRepair {
            try bottleService.resetWebViewRenderingCaches(for: preparedBottle)
        }

        var launchEnvOverrides = effectiveLauncher.envOverrides
        launchEnvOverrides.merge(additionalEnvOverrides) { _, override in override }
        let result = try WineRunner(paths: paths).launchDetached(
            WineRunRequest(
                exe: effectiveLauncher.exePath,
                args: effectiveLauncher.args,
                bottle: preparedBottle,
                engine: engine,
                envOverrides: launchEnvOverrides,
                logName: logName
            )
        )
        return DetachedLauncherLaunch(
            bottle: preparedBottle,
            launcher: effectiveLauncher,
            result: result
        )
    }

    private func prepareBottle(_ bottle: BottleManifest, for engine: EngineManifest) throws -> BottleManifest {
        let template = BottleTemplate(windowsVersion: bottle.windowsVersion, arch: bottle.arch)
        let envOverrides = bottle.id == BottleService.highPerformanceBottleId
            ? BottleService.highPerformanceEnvOverrides(engine: engine)
            : bottle.envOverrides
        return try bottleService.ensureBottle(
            id: bottle.id,
            name: bottle.name,
            template: template,
            engine: engine,
            envOverrides: envOverrides,
            enforceEnvOverrides: false
        )
    }

    private func resetRenderingCachesIfNeeded(for launcher: LauncherManifest, in bottle: BottleManifest) throws {
        let hasTextRepair = launcher.envOverrides["MACWIN_TEXT_RENDERING_REPAIR"] == "1"
            || launcher.envOverrides["MACWIN_HOYOPLAY_TEXT_REPAIR"] == "1"
            || launcher.envOverrides["MACWIN_STEAMWEBHELPER_FORCE_OPAQUE"] == "1"
            || launcher.envOverrides["MACWIN_LENOVO_BLACK_SCREEN_REPAIR"] == "1"
        guard hasTextRepair else { return }
        try bottleService.resetWebViewRenderingCaches(for: bottle)
    }

    private func refreshedLauncher(_ launcher: LauncherManifest, in bottle: BottleManifest) throws -> LauncherManifest {
        let refreshedBottle = try bottleService.bottle(id: bottle.id) ?? bottle
        let effectiveLauncher = refreshedBottle.installedApps.first(where: { $0.id == launcher.id }) ?? launcher
        guard let profile = ApplicationCompatibilityProfile.current(in: effectiveLauncher)
            ?? ApplicationCompatibilityProfile.matched(
                launcherId: effectiveLauncher.id,
                displayName: effectiveLauncher.displayName,
                exePath: effectiveLauncher.exePath
            )
        else {
            return effectiveLauncher
        }

        let migratedLauncher = profile.applied(to: effectiveLauncher)
        guard migratedLauncher != effectiveLauncher else {
            return effectiveLauncher
        }
        _ = try bottleService.updateLauncher(migratedLauncher, in: refreshedBottle)
        return migratedLauncher
    }

    private func preferredEngine(for recipe: RecipeManifest? = nil, requiresWin32: Bool = false) -> EngineManifest? {
        let needsWin32 = requiresWin32 || recipe?.engineRequirements.requiresWin32 == true
        let candidates = sortedEnginesByPreference().filter { engine in
            guard !needsWin32 || engine.supportsWin32 else { return false }
            guard let recipe else { return true }
            return recipe.engineRequirements.isSatisfied(by: engine)
        }
        return candidates.first
    }

    private func sortedEnginesByPreference() -> [EngineManifest] {
        engines.sorted { lhs, rhs in
            if lhs.supportsWin32 != rhs.supportsWin32 {
                return lhs.supportsWin32 && !rhs.supportsWin32
            }
            if lhs.id == EngineRegistry.currentWoW64GameEngineId || rhs.id == EngineRegistry.currentWoW64GameEngineId {
                return lhs.id == EngineRegistry.currentWoW64GameEngineId
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func trackRunningItem(
        title: String,
        bottle: BottleManifest,
        processIdentifier: Int32,
        logName: String,
        launchKey: String? = nil
    ) {
        refreshRunningItems()
        if let launchKey {
            runningItems.removeAll { $0.launchKey == launchKey }
        }
        runningItems.append(
            RunningDesktopItem(
                id: "\(processIdentifier)-\(UUID().uuidString.prefix(6))",
                title: title,
                bottleId: bottle.id,
                engineId: bottle.engineId,
                bottleName: bottle.name,
                processIdentifier: processIdentifier,
                logName: logName,
                launchKey: launchKey,
                startedAt: Date()
            )
        )
    }

    private func recordLocalInstallerLaunch(
        fileName: String,
        sourceURL: URL,
        bottle: BottleManifest,
        logName: String,
        processIdentifier: Int32
    ) {
        let safeName = Self.logSafeName(fileName)
        let task = InstallTask(
            id: "local-\(UUID().uuidString)",
            recipeId: "local-installer:\(safeName)",
            bottleId: bottle.id,
            state: .launched,
            progressText: "Launched interactive installer \(fileName) pid \(processIdentifier) source \(sourceURL.path)",
            logPath: paths.logsDirectory.appendingPathComponent(logName).path,
            startedAt: Date()
        )
        try? installHistoryService.save(task)
    }

    private func beginLaunchIfNeeded(launchKey: String, displayName: String) -> Bool {
        if finishIfAlreadyRunning(launchKey: launchKey, displayName: displayName) {
            return false
        }
        guard !launchKeysInFlight.contains(launchKey) else {
            finish(text(.actionAlreadyInProgress, displayName))
            return false
        }
        launchKeysInFlight.insert(launchKey)
        return true
    }

    private func endLaunch(launchKey: String) {
        launchKeysInFlight.remove(launchKey)
    }

    private func enqueueExternalExecutableRequest(_ request: ExternalExecutableRequest) {
        let path = request.url.standardizedFileURL.path
        if pendingExternalExecutable?.url.standardizedFileURL.path == path {
            statusMessage = text(.openWindowsExecutable)
            return
        }
        guard !queuedExternalExecutables.contains(where: { $0.url.standardizedFileURL.path == path }) else {
            statusMessage = text(.openWindowsExecutable)
            return
        }
        if pendingExternalExecutable == nil {
            pendingExternalExecutable = request
        } else {
            queuedExternalExecutables.append(request)
        }
    }

    private func showNextQueuedExternalExecutable() {
        guard pendingExternalExecutable == nil, !queuedExternalExecutables.isEmpty else { return }
        pendingExternalExecutable = queuedExternalExecutables.removeFirst()
    }

    private func finishIfAlreadyRunning(launchKey: String, displayName: String) -> Bool {
        refreshRunningItems()
        guard let item = runningItems.first(where: { $0.launchKey == launchKey }) else { return false }
        finish(text(.alreadyRunningPid, displayName, "\(item.processIdentifier)"))
        return true
    }

    private func finishIfRuntimeAlreadyRunning(executable: String, displayName: String) -> Bool {
        guard let entry = runtimeProcessAuditService.firstRunningMatch(forExecutable: executable, displayName: displayName) else {
            return false
        }
        runtimeProcessAuditReport = runtimeProcessAuditService.makeReport()
        finish(text(.alreadyRunningPid, displayName, "\(entry.processIdentifier)"))
        return true
    }

    nonisolated private static func launcherLaunchKey(bottleId: String, launcherId: String) -> String {
        "launcher:\(bottleId):\(launcherId)"
    }

    nonisolated private static func externalExecutableLaunchKey(bottleId: String, url: URL) -> String {
        "external:\(bottleId):\(url.standardizedFileURL.path)"
    }

    nonisolated private static func commandLaunchKey(bottleId: String, exe: String, args: [String]) -> String {
        "command:\(bottleId):\(exe):\(args.joined(separator: "\u{1f}"))"
    }

    nonisolated private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated private static func logSafeName(_ fileName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = fileName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = scalars.reduce(into: "") { $0.append($1) }
        return value.isEmpty ? "installer" : value
    }

    private func cacheDroppedInstaller(_ sourceURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: paths.downloadsDirectory, withIntermediateDirectories: true)
        let cachedName = "dropped-\(UUID().uuidString.prefix(8))-\(Self.logSafeName(sourceURL.lastPathComponent))"
        let destinationURL = paths.downloadsDirectory.appendingPathComponent(cachedName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func cacheIconIfAvailable(for executableURL: URL) throws -> URL? {
        guard let iconData = try WindowsExecutableIconExtractor.extractBestIcon(from: executableURL) else {
            return nil
        }
        try FileManager.default.createDirectory(at: paths.iconCacheDirectory, withIntermediateDirectories: true)
        let hash = try Hashing.sha256Hex(file: executableURL)
        let destination = paths.iconCacheDirectory.appendingPathComponent("\(hash).ico")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try iconData.write(to: destination, options: [.atomic])
        }
        return destination
    }

    private func setBusy(_ message: String) {
        isBusy = true
        statusMessage = message
        lastError = nil
    }

    private func finish(_ message: String) {
        isBusy = false
        statusMessage = message
    }

    private func fail(_ error: Error) {
        isBusy = false
        lastError = localizedError(error)
        statusMessage = text(.catalogError)
    }

    private func localizedError(_ error: Error) -> String {
        guard let macWinError = error as? MacWinError else {
            return error.localizedDescription
        }
        switch macWinError {
        case .missingFile(let path):
            return text(.missingFile, path)
        case .invalidPath(let path):
            return text(.missingFile, path)
        case .invalidManifest(let reason):
            return text(.invalidManifest, reason)
        case .unsupportedEngine(let reason), .unsupportedInstallerMode(let reason):
            return text(.unsupported, reason)
        case .processFailed(let command, let exitCode, _):
            return text(.processFailed, "\(exitCode)", command)
        case .processLaunchFailed(let reason):
            return text(.unableToLaunchProcess, reason)
        case .guiSessionLocked:
            return text(.nativeUIProbeSessionLocked)
        case .runtimeUnavailable(let processIdentifiers):
            return text(.wineRuntimeUnavailable, processIdentifiers.map(String.init).joined(separator: ", "))
        case .catalogSignatureInvalid:
            return text(.signatureInvalid)
        case .catalogHashMismatch(let recipeId, let expected, let actual):
            return text(.hashMismatch, "\(recipeId) \(expected) \(actual)")
        case .installerRequired(let recipe):
            return text(.installerRequired, recipe)
        }
    }

    private static let diagnosticWineDebug = "+timestamp,+pid,+tid,+seh,+loaddll,+event,+cursor,+winhttp,+d3d,+vulkan"
}
