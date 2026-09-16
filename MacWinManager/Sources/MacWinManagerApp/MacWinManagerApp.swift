import AppKit
import CryptoKit
import Darwin
import MacWinCore
import SwiftUI

@MainActor
final class MacWinAppDelegate: NSObject, NSApplicationDelegate {
    private let minimumMainWindowSize = NSSize(width: 1040, height: 700)
    private let defaultMainWindowSize = NSSize(width: 1280, height: 800)
    private var fallbackWindowController: NSWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        MacWinIconAssets.installApplicationIcon()
        MacWinDockHygiene.disableRecentExecutableClutter()
        MacWinLaunchCoordinator.shared.prepareEarlyLaunch()
        guard MacWinLaunchCoordinator.shared.isPrimaryInstance else {
            MacWinLaunchCoordinator.shared.forwardAndExit()
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard MacWinLaunchCoordinator.shared.isPrimaryInstance else { return }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self, weak application] in
            guard let self, let application else { return }
            self.revealMainWindow(in: application, attemptsRemaining: 12)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard MacWinLaunchCoordinator.shared.isPrimaryInstance,
              let application = notification.object as? NSApplication else {
            return
        }
        revealMainWindow(in: application, attemptsRemaining: 3)
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard MacWinLaunchCoordinator.shared.isPrimaryInstance else { return false }
        revealMainWindow(in: sender, attemptsRemaining: 3)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !MacWinLaunchCoordinator.shared.isPrimaryInstance {
            MacWinExternalOpenQueue.enqueue(urls: urls)
            MacWinLaunchCoordinator.shared.forwardAndExit()
            return
        }
        NotificationCenter.default.post(name: .macWinExternalOpenURLs, object: urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealMainWindow(in: sender, attemptsRemaining: flag ? 1 : 3)
        return true
    }

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard MacWinLaunchCoordinator.shared.isPrimaryInstance else { return }
        MacWinStore.shared.cleanupAllBottleRuntimeProcessesForShutdown()
    }

    private func revealMainWindow(in application: NSApplication, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            createFallbackMainWindow(in: application)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak application] in
            guard let self, let application else { return }
            guard let window = self.managedMainWindow(in: application) else {
                self.revealMainWindow(in: application, attemptsRemaining: attemptsRemaining - 1)
                return
            }

            window.identifier = NSUserInterfaceItemIdentifier("macwin-main-window")
            if window.frame.width < self.minimumMainWindowSize.width
                || window.frame.height < self.minimumMainWindowSize.height {
                window.setContentSize(self.defaultMainWindowSize)
                window.center()
            }
            _ = MacWinWindowChrome.configure(window)
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            self.scheduleBootstrap()
        }
    }

    private func createFallbackMainWindow(in application: NSApplication) {
        if let existingWindow = managedMainWindow(in: application) {
            existingWindow.identifier = NSUserInterfaceItemIdentifier("macwin-main-window")
            _ = MacWinWindowChrome.configure(existingWindow)
            existingWindow.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            scheduleBootstrap()
            return
        }
        guard fallbackWindowController == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultMainWindowSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("macwin-main-window")
        window.contentView = NSHostingView(rootView: MacWinRootView(store: .shared))
        window.minSize = minimumMainWindowSize
        window.center()
        _ = MacWinWindowChrome.configure(window)

        let controller = NSWindowController(window: window)
        fallbackWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        scheduleBootstrap()
    }

    private func scheduleBootstrap() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            await MacWinStore.shared.bootstrapIfNeeded()
        }
    }

    private func managedMainWindow(in application: NSApplication) -> NSWindow? {
        if let fallbackWindow = fallbackWindowController?.window {
            return fallbackWindow
        }
        if let identifiedWindow = application.windows.first(where: {
            $0.identifier?.rawValue == "macwin-main-window"
        }) {
            return identifiedWindow
        }
        return application.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel)
        })
    }
}

enum MacWinIconAssets {
    @MainActor
    static func installApplicationIcon() {
        if Bundle.main.bundleURL.pathExtension == "app" {
            let resolvedIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            if resolvedIcon.isValid {
                NSApp.applicationIconImage = resolvedIcon
                return
            }
        }

        guard let url = Bundle.module.url(
            forResource: "MacWinAppIcon",
            withExtension: "icns",
            subdirectory: "Icons"
        ), let image = NSImage(contentsOf: url) else {
            return
        }
        NSApp.applicationIconImage = image
    }
}

@MainActor
enum MacWinDockHygiene {
    static func disableRecentExecutableClutter() {
        UserDefaults.standard.set(0, forKey: "NSRecentDocumentsLimit")
    }
}

@MainActor
final class MacWinLaunchCoordinator {
    static let shared = MacWinLaunchCoordinator()

    private var didPrepare = false
    private(set) var isPrimaryInstance = true

    func prepareEarlyLaunch() {
        guard !didPrepare else { return }
        didPrepare = true
        isPrimaryInstance = MacWinSingleInstanceLock.shared.acquire()
        if !isPrimaryInstance {
            if let application = NSApp {
                application.setActivationPolicy(.prohibited)
                application.hide(nil)
            }
        } else {
            MacWinSingleInstanceLock.terminateDuplicateManagerInstances()
        }
    }

    func forwardAndExit() {
        MacWinExternalOpenQueue.enqueueCommandLineURLs()
        MacWinSingleInstanceLock.activateExistingInstance()
        fflush(nil)
        exit(0)
    }
}

@MainActor
final class MacWinSingleInstanceLock {
    static let shared = MacWinSingleInstanceLock()

    private var lockDescriptor: Int32 = -1

    func acquire() -> Bool {
        let lockURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacWin", isDirectory: true)
            .appendingPathComponent("macwin-manager.lock")
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return true
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return true }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            lockDescriptor = descriptor
            ftruncate(descriptor, 0)
            let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
            _ = pid.withCString { write(descriptor, $0, strlen($0)) }
            return true
        }

        close(descriptor)
        return false
    }

    static func activateExistingInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.local.macwin.manager")
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        candidates.first?.activate(options: [.activateAllWindows])
    }

    static func terminateDuplicateManagerInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.local.macwin.manager")
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }

        guard !duplicates.isEmpty else { return }
        for duplicate in duplicates {
            NSLog("MacWin terminating duplicate manager instance pid=\(duplicate.processIdentifier)")
            if !duplicate.terminate() {
                duplicate.forceTerminate()
            }
        }
    }
}

extension Notification.Name {
    static let macWinExternalOpenURLs = Notification.Name("dev.local.macwin.manager.external-open-urls")
}

enum MacWinExternalOpenQueue {
    static func enqueueCommandLineURLs() {
        let urls = ExternalExecutableOpenQueueService.executableURLs(fromCommandLineArguments: ProcessInfo.processInfo.arguments)
        enqueue(urls: urls)
    }

    static func enqueue(urls: [URL]) {
        do {
            try ExternalExecutableOpenQueueService().enqueue(urls: urls, source: "duplicate-instance")
        } catch {
            NSLog("MacWin failed to queue external exe open: \(error.localizedDescription)")
        }
    }

    static func drain() -> [URL] {
        (try? ExternalExecutableOpenQueueService().drainURLs()) ?? []
    }
}

enum MacWinCommandLineTool {
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--help") || arguments.contains("-h") {
            printHelp()
            exit(0)
        }
        if let scanIndex = arguments.firstIndex(of: "--scan-installed-apps") {
            runInstalledAppScan(arguments: arguments, optionIndex: scanIndex)
            exit(0)
        }
        if let installIndex = arguments.firstIndex(of: "--install-recipe") {
            runRecipeInstall(arguments: arguments, optionIndex: installIndex)
            exit(0)
        }
        if let smokeIndex = arguments.firstIndex(of: "--smoke-launcher") {
            runLauncherSmoke(arguments: arguments, optionIndex: smokeIndex)
            exit(0)
        }
        if let probeIndex = arguments.firstIndex(of: "--run-probe") {
            runProbe(arguments: arguments, optionIndex: probeIndex)
            exit(0)
        }
        if arguments.contains("--export-log-issue-report") {
            runLogIssueReportExport()
            exit(0)
        }
        if arguments.contains("--export-log-maintenance") {
            runLogMaintenanceExport()
            exit(0)
        }
        if arguments.contains("--archive-log-cleanup-candidates") {
            runLogMaintenanceArchive()
            exit(0)
        }
        if arguments.contains("--export-test-run-history") {
            runTestRunHistoryExport()
            exit(0)
        }
        if arguments.contains("--export-software-test-plan") {
            runSoftwareTestPlanExport()
            exit(0)
        }
        if arguments.contains("--export-software-smoke-matrix") {
            runSoftwareSmokeMatrixExport()
            exit(0)
        }
        if arguments.contains("--export-software-sample-catalog") {
            runSoftwareSampleCatalogExport()
            exit(0)
        }
        if arguments.contains("--export-software-sample-preparation") {
            runSoftwareSamplePreparationExport()
            exit(0)
        }
        if arguments.contains("--export-software-sample-coverage") {
            runSoftwareSampleCoverageExport()
            exit(0)
        }
        if arguments.contains("--export-runtime-processes") {
            runRuntimeProcessExport()
            exit(0)
        }
        if arguments.contains("--export-support-triage") {
            runSupportTriageExport()
            exit(0)
        }
        if arguments.contains("--export-native-ui-bridge-health") {
            runNativeUIBridgeHealthExport()
            exit(0)
        }
        if arguments.contains("--stop-wine-virtual-desktops") {
            runRuntimeProcessTermination(mode: .wineVirtualDesktops)
            exit(0)
        }
        if arguments.contains("--stop-detached-runtime-processes") {
            runRuntimeProcessTermination(mode: .detachedWineSystemProcesses)
            exit(0)
        }
        if arguments.contains("--stop-all-runtime-processes") {
            runRuntimeProcessTermination(mode: .all)
            exit(0)
        }
        if arguments.contains("--export-representative-acceptance") {
            runRepresentativeAcceptanceExport()
            exit(0)
        }

        let exportsFoundationStatus = arguments.contains("--export-foundation-status")
            || arguments.contains("--export-foundation-readiness")
        guard exportsFoundationStatus else { return }

        do {
            let paths = MacWinPaths()
            let engines = try EngineRegistry(paths: paths).listEngines()
            let bottles = try BottleService(paths: paths).listBottles()
            let recipes = try loadRecipes(paths: paths)
            let capability = CapabilityReportService(paths: paths).makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes
            )
            let result = try FoundationStatusSnapshotService(paths: paths).exportSnapshot(report: capability)
            print(result.latestSnapshotURL.path)
            exit(0)
        } catch {
            fputs("MacWin foundation status export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printHelp() {
        print("""
        MacWin Manager command line tools:
          --scan-installed-apps <bottle-id>
          --install-recipe <recipe-id> [bottle-id] [installer-path]
          --install-timeout <seconds>
          --smoke-launcher <bottle-id> <launcher-id> [seconds]
          --smoke-launcher-env KEY=VALUE
          --smoke-launcher-clear-args
          --run-probe <asset-id> [bottle-id]
          --probe-timeout <seconds>
          --export-log-issue-report
          --export-log-maintenance
          --archive-log-cleanup-candidates
          --export-test-run-history
          --export-software-test-plan
          --export-software-smoke-matrix
          --export-software-sample-catalog
          --export-software-sample-preparation
          --export-software-sample-coverage
          --export-runtime-processes
          --export-support-triage
          --export-native-ui-bridge-health
          --stop-wine-virtual-desktops
          --stop-detached-runtime-processes
          --stop-all-runtime-processes
          --export-foundation-status
          --export-foundation-readiness
          --export-representative-acceptance
        """)
    }

    private static func runRepresentativeAcceptanceExport() {
        do {
            let paths = MacWinPaths()
            let engines = try EngineRegistry(paths: paths).listEngines()
            let bottles = try BottleService(paths: paths).listBottles()
            let recipes = try loadRecipes(paths: paths)
            let capability = CapabilityReportService(paths: paths).makeReport(
                engines: engines,
                bottles: bottles,
                recipes: recipes
            )
            let matrix = capability.nativeUIApplicationMatrix
                ?? NativeUIApplicationMatrixReport.empty(rootPath: paths.root.path)
            let service = RepresentativeSoftwareAcceptanceService(paths: paths)
            let report = service.report(matrix: matrix)
            let url = try service.save(report)
            print(url.path)
            exit(0)
        } catch {
            fputs("MacWin representative acceptance export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRecipeInstall(arguments: [String], optionIndex: Int) {
        guard arguments.indices.contains(optionIndex + 1) else {
            fputs("MacWin recipe install failed: expected --install-recipe <recipe-id> [bottle-id] [installer-path]\n", stderr)
            exit(2)
        }

        do {
            let paths = MacWinPaths()
            let recipeId = arguments[optionIndex + 1]
            let recipes = try loadRecipes(paths: paths)
            guard let recipe = recipes.first(where: { $0.id == recipeId }) else {
                fputs("MacWin recipe install failed: recipe not found: \(recipeId)\n", stderr)
                exit(2)
            }

            let bottleId = optionalPositionalArgument(arguments, after: optionIndex + 1)
                ?? BottleService.highPerformanceBottleId
            let localInstallerPath = optionalPositionalArgument(arguments, after: optionIndex + 2)
            let timeoutSeconds = installTimeoutSeconds(arguments: arguments)
            let engineRegistry = EngineRegistry(paths: paths)
            let engines = try engineRegistry.listEngines()
            guard let engine = preferredEngine(for: recipe, engines: engines) else {
                fputs("MacWin recipe install failed: no compatible engine for \(recipe.id)\n", stderr)
                exit(2)
            }

            let bottleService = BottleService(paths: paths)
            let bottle = try resolveInstallBottle(
                id: bottleId,
                recipe: recipe,
                engine: engine,
                bottleService: bottleService
            )
            let installerSource = installerSource(for: recipe, localInstallerPath: localInstallerPath)
            let startedAt = Date()
            let resultBox = InstallTaskResultBox()
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let task = try InstallService(paths: paths).install(
                        recipe: recipe,
                        bottle: bottle,
                        engine: engine,
                        installerSource: installerSource
                    )
                    resultBox.set(.success(task))
                } catch {
                    resultBox.set(.failure(error))
                }
                completed.signal()
            }

            if !waitForSignal(completed, timeoutSeconds: timeoutSeconds) {
                let cleanup = terminateRuntimeProcessesForSmokeWatchdog()
                let logURL = paths.logsDirectory.appendingPathComponent(
                    "\(bottle.id)-install-\(recipe.id)-cli-watchdog-\(compactTimestamp(Date())).log"
                )
                appendInstallWatchdogTimeoutLog(
                    logURL: logURL,
                    recipe: recipe,
                    bottle: bottle,
                    timeoutSeconds: timeoutSeconds,
                    cleanup: cleanup
                )
                print("recipe=\(recipe.id)")
                print("bottle=\(bottle.id)")
                print("state=timedOut")
                print("exitCode=\(SIGTERM)")
                print("elapsedSeconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))")
                print("log=\(logURL.path)")
                exit(124)
            }

            let task = try resultBox.get()
            let refreshedBottle = try bottleService.bottle(id: bottle.id) ?? bottle
            print("recipe=\(recipe.id)")
            print("bottle=\(refreshedBottle.id)")
            print("task=\(task.id)")
            print("state=\(task.state.rawValue)")
            if let exitCode = task.exitCode {
                print("exitCode=\(exitCode)")
            }
            print("elapsedSeconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))")
            print("log=\(task.logPath)")
            for launcher in refreshedBottle.installedApps
                .filter({ launcher in
                    launcher.appId == recipe.id
                        || recipe.launchers.contains(where: { recipeLauncher in recipeLauncher.id == launcher.id })
                })
                .sorted(by: { $0.displayName < $1.displayName }) {
                print("launcher=\(launcher.id)\t\(launcher.displayName)\t\(launcher.exePath)")
            }
            if task.state != .succeeded {
                exit(1)
            }
        } catch {
            fputs("MacWin recipe install failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func optionalPositionalArgument(_ arguments: [String], after index: Int) -> String? {
        let candidateIndex = index + 1
        guard arguments.indices.contains(candidateIndex) else { return nil }
        let candidate = arguments[candidateIndex]
        guard !candidate.hasPrefix("--") else { return nil }
        return candidate
    }

    private static func installTimeoutSeconds(arguments: [String]) -> TimeInterval {
        guard let timeoutIndex = arguments.firstIndex(of: "--install-timeout"),
              arguments.indices.contains(timeoutIndex + 1),
              let seconds = TimeInterval(arguments[timeoutIndex + 1])
        else {
            return 180
        }
        return max(seconds, 5)
    }

    private static func preferredEngine(for recipe: RecipeManifest, engines: [EngineManifest]) -> EngineManifest? {
        engines.first(where: { recipe.engineRequirements.isSatisfied(by: $0) }) ?? engines.first
    }

    private static func resolveInstallBottle(
        id: String,
        recipe: RecipeManifest,
        engine: EngineManifest,
        bottleService: BottleService
    ) throws -> BottleManifest {
        if id == BottleService.highPerformanceBottleId {
            return try bottleService.ensureHighPerformanceBottle(
                name: "高性能 Windows 11",
                engine: engine
            )
        }
        if let existing = try bottleService.bottle(id: id) {
            return existing
        }
        return try bottleService.ensureBottle(
            id: id,
            name: id,
            template: recipe.bottleTemplate,
            engine: engine,
            envOverrides: BottleService.highPerformanceEnvOverrides(engine: engine)
        )
    }

    private static func installerSource(for recipe: RecipeManifest, localInstallerPath: String?) -> InstallerSource? {
        if let localInstallerPath {
            return .localFile(URL(fileURLWithPath: localInstallerPath))
        }
        if recipe.installer.mode == .alreadyInstalled {
            return .existingInstallation
        }
        return nil
    }

    private static func appendInstallWatchdogTimeoutLog(
        logURL: URL,
        recipe: RecipeManifest,
        bottle: BottleManifest,
        timeoutSeconds: TimeInterval,
        cleanup: RuntimeProcessTerminationReport
    ) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        installOutcome=timedOut
        recipe=\(recipe.id)
        bottle=\(bottle.id)
        cliWatchdog=timedOut
        cliWatchdogTimeoutSeconds=\(String(format: "%.2f", timeoutSeconds))
        runtimeCleanupRequested=\(cleanup.requestedCount)
        runtimeCleanupStopped=\(cleanup.stoppedProcessIdentifiers.map(String.init).joined(separator: ","))
        runtimeCleanupFailed=\(cleanup.failedProcessIdentifiers.map(String.init).joined(separator: ","))
        ----- MacWin result -----
        endedAt=\(ISO8601DateFormatter().string(from: Date()))
        exitCode=\(SIGTERM)
        -------------------------
        """
        try? Data(text.utf8).write(to: logURL, options: [.atomic])
    }

    private static func runLauncherSmoke(arguments: [String], optionIndex: Int) {
        guard arguments.indices.contains(optionIndex + 2) else {
            fputs("MacWin launcher smoke failed: expected --smoke-launcher <bottle-id> <launcher-id> [seconds]\n", stderr)
            exit(2)
        }

        do {
            let bottleId = arguments[optionIndex + 1]
            let launcherId = arguments[optionIndex + 2]
            let timeoutSeconds: TimeInterval
            if arguments.indices.contains(optionIndex + 3) {
                timeoutSeconds = TimeInterval(arguments[optionIndex + 3]) ?? 30
            } else {
                timeoutSeconds = 30
            }
            let smokeEnvOverrides = smokeLauncherEnvironmentOverrides(arguments: arguments)
            let clearLauncherArguments = arguments.contains("--smoke-launcher-clear-args")

            let paths = MacWinPaths()
            let bottleService = BottleService(paths: paths)
            let engineRegistry = EngineRegistry(paths: paths)
            guard let bottle = try bottleService.bottle(id: bottleId) else {
                fputs("MacWin launcher smoke failed: bottle not found: \(bottleId)\n", stderr)
                exit(2)
            }
            guard let launcher = bottle.installedApps.first(where: { $0.id == launcherId || $0.appId == launcherId }) else {
                fputs("MacWin launcher smoke failed: launcher not found: \(launcherId)\n", stderr)
                exit(2)
            }
            let engines = try engineRegistry.listEngines()
            guard let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first else {
                fputs("MacWin launcher smoke failed: no usable engine registered\n", stderr)
                exit(2)
            }

            let timestamp = compactTimestamp(Date())
            let logName = "\(bottle.id)-\(launcher.id)-cli-smoke-\(timestamp).log"
            let logURL = paths.logsDirectory.appendingPathComponent(logName)
            let envOverrides = launcher.envOverrides.merging(smokeEnvOverrides) { _, override in override }
            let startedAt = Date()
            let resultBox = SmokeLaunchResultBox()
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try WineRunner(paths: paths).smokeLaunch(WineRunRequest(
                        exe: launcher.exePath,
                        args: clearLauncherArguments ? [] : launcher.args,
                        bottle: bottle,
                        engine: engine,
                        envOverrides: envOverrides,
                        logName: logName
                    ), timeoutSeconds: timeoutSeconds)
                    resultBox.set(.success(result))
                } catch {
                    resultBox.set(.failure(error))
                }
                completed.signal()
            }

            let watchdogSeconds = max(timeoutSeconds + 8, timeoutSeconds)
            if !waitForSignal(completed, timeoutSeconds: watchdogSeconds) {
                let cleanup = terminateRuntimeProcessesForSmokeWatchdog()
                appendSmokeWatchdogTimeoutLog(
                    logURL: logURL,
                    timeoutSeconds: timeoutSeconds,
                    watchdogSeconds: watchdogSeconds,
                    cleanup: cleanup
                )
                print("bottle=\(bottle.id)")
                print("launcher=\(launcher.id)")
                if clearLauncherArguments {
                    print("clearArgs=true")
                }
                if !smokeEnvOverrides.isEmpty {
                    let overrideKeys = smokeEnvOverrides.keys.sorted().joined(separator: ",")
                    print("smokeEnvOverrides=\(overrideKeys)")
                }
                print("timedOut=true")
                print("exitCode=\(SIGTERM)")
                print("elapsedSeconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))")
                print("log=\(logURL.path)")
                exit(0)
            }

            let result = try resultBox.get()
            print("bottle=\(bottle.id)")
            print("launcher=\(launcher.id)")
            if clearLauncherArguments {
                print("clearArgs=true")
            }
            if !smokeEnvOverrides.isEmpty {
                let overrideKeys = smokeEnvOverrides.keys.sorted().joined(separator: ",")
                print("smokeEnvOverrides=\(overrideKeys)")
            }
            print("timedOut=\(result.timedOut)")
            print("exitCode=\(result.exitCode)")
            print("elapsedSeconds=\(String(format: "%.2f", result.elapsedSeconds))")
            print("log=\(result.logURL.path)")
        } catch {
            fputs("MacWin launcher smoke failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runProbe(arguments: [String], optionIndex: Int) {
        guard arguments.indices.contains(optionIndex + 1) else {
            fputs("MacWin probe failed: expected --run-probe <asset-id> [bottle-id]\n", stderr)
            exit(2)
        }

        do {
            let assetId = arguments[optionIndex + 1]
            let bottleId = optionalPositionalArgument(arguments, after: optionIndex + 1)
                ?? BottleService.highPerformanceBottleId
            let timeoutSeconds = probeTimeoutSeconds(arguments: arguments)
            let paths = MacWinPaths()
            let engineRegistry = EngineRegistry(paths: paths)
            let bottleService = BottleService(paths: paths)
            let engines = try engineRegistry.listEngines()
            guard let engine = preferredProbeEngine(bottleId: bottleId, engines: engines, bottleService: bottleService) else {
                fputs("MacWin probe failed: no usable engine registered\n", stderr)
                exit(2)
            }

            let bottle = try resolveProbeBottle(
                id: bottleId,
                engine: engine,
                bottleService: bottleService
            )
            let bootstrappedBottle = try bottleService.bootstrapWinePrefixIfNeeded(bottle: bottle, engine: engine)
            let report = try DiagnosticsService(paths: paths).runProbe(
                assetId: assetId,
                engine: engine,
                bottle: bootstrappedBottle,
                timeoutSeconds: timeoutSeconds
            )
            _ = try DiagnosticsHistoryService(paths: paths).save(
                report: report,
                scope: .probe,
                engine: engine,
                bottle: bootstrappedBottle,
                assetId: assetId
            )

            print("probe=\(assetId)")
            print("bottle=\(bootstrappedBottle.id)")
            print("engine=\(engine.id)")
            print("timedOut=\(report.timedOut)")
            print("exitCode=\(report.exitCode)")
            print("elapsedSeconds=\(String(format: "%.2f", report.durationSeconds))")
            print("log=\(report.logURL.path)")
            for item in report.items where item.status != .notObserved {
                print("item=\(item.id)\t\(item.status.rawValue)\t\(item.detail)")
            }
            if report.exitCode != 0 {
                exit(1)
            }
        } catch {
            fputs("MacWin probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func probeTimeoutSeconds(arguments: [String]) -> TimeInterval {
        guard let timeoutIndex = arguments.firstIndex(of: "--probe-timeout"),
              arguments.indices.contains(timeoutIndex + 1),
              let seconds = TimeInterval(arguments[timeoutIndex + 1])
        else {
            return 180
        }
        return max(seconds, 5)
    }

    private static func preferredProbeEngine(
        bottleId: String,
        engines: [EngineManifest],
        bottleService: BottleService
    ) -> EngineManifest? {
        if let bottle = try? bottleService.bottle(id: bottleId),
           let engine = engines.first(where: { $0.id == bottle.engineId }) {
            return engine
        }
        return engines.first(where: { $0.id == EngineRegistry.currentWoW64GameEngineId })
            ?? engines.first(where: \.supportsWin32)
            ?? engines.first
    }

    private static func resolveProbeBottle(
        id: String,
        engine: EngineManifest,
        bottleService: BottleService
    ) throws -> BottleManifest {
        if id == BottleService.highPerformanceBottleId {
            return try bottleService.ensureHighPerformanceBottle(
                name: "高性能 Windows 11",
                engine: engine
            )
        }
        if let existing = try bottleService.bottle(id: id) {
            return existing
        }
        return try bottleService.ensureBottle(
            id: id,
            name: id,
            template: BottleTemplate(windowsVersion: "win11", arch: .win64),
            engine: engine,
            envOverrides: BottleService.highPerformanceEnvOverrides(engine: engine)
        )
    }

    private static func smokeLauncherEnvironmentOverrides(arguments: [String]) -> [String: String] {
        var overrides: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            defer { index += 1 }
            guard arguments[index] == "--smoke-launcher-env",
                  arguments.indices.contains(index + 1)
            else {
                continue
            }
            let assignment = arguments[index + 1]
            guard let separator = assignment.firstIndex(of: "=") else { continue }
            let key = String(assignment[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(assignment[assignment.index(after: separator)...])
            if !key.isEmpty {
                overrides[key] = value
            }
        }
        return overrides
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 0))
        repeat {
            if semaphore.wait(timeout: .now()) == .success {
                return true
            }
            Thread.sleep(forTimeInterval: min(0.1, max(deadline.timeIntervalSinceNow, 0)))
        } while Date() < deadline
        return semaphore.wait(timeout: .now()) == .success
    }

    private static func terminateRuntimeProcessesForSmokeWatchdog() -> RuntimeProcessTerminationReport {
        let terminator = RuntimeProcessTerminator()
        var requested = 0
        var stopped: Set<Int32> = []
        var failed: Set<Int32> = []
        var consecutiveEmptyScans = 0
        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            let report = RuntimeProcessAuditService().makeReport()
            if report.entries.isEmpty {
                consecutiveEmptyScans += 1
                if consecutiveEmptyScans >= 2 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            consecutiveEmptyScans = 0
            let result = terminator.terminateAllRuntimeProcesses(in: report)
            requested += result.requestedCount
            stopped.formUnion(result.stoppedProcessIdentifiers)
            failed.formUnion(result.failedProcessIdentifiers)
            Thread.sleep(forTimeInterval: 0.75)
        }

        return RuntimeProcessTerminationReport(
            requestedCount: requested,
            stoppedProcessIdentifiers: stopped.sorted(),
            failedProcessIdentifiers: failed.sorted()
        )
    }

    private static func appendSmokeWatchdogTimeoutLog(
        logURL: URL,
        timeoutSeconds: TimeInterval,
        watchdogSeconds: TimeInterval,
        cleanup: RuntimeProcessTerminationReport
    ) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let text = """

        smokeOutcome=keptAlive
        cliWatchdog=timedOut
        cliWatchdogTimeoutSeconds=\(String(format: "%.2f", watchdogSeconds))
        smokeTimeoutSeconds=\(String(format: "%.2f", timeoutSeconds))
        runtimeCleanupRequested=\(cleanup.requestedCount)
        runtimeCleanupStopped=\(cleanup.stoppedProcessIdentifiers.map(String.init).joined(separator: ","))
        runtimeCleanupFailed=\(cleanup.failedProcessIdentifiers.map(String.init).joined(separator: ","))
        ----- MacWin result -----
        endedAt=\(ISO8601DateFormatter().string(from: Date()))
        exitCode=\(SIGTERM)
        -------------------------
        """
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static func runLogIssueReportExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let report = LogService(paths: paths).issueReport()
            let generatedAt = Date()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let timestamp = formatter.string(from: generatedAt)
                .replacingOccurrences(of: ":", with: "")
            let markdownURL = paths.logsDirectory.appendingPathComponent("log-issues-\(timestamp).md")
            let jsonURL = paths.logsDirectory.appendingPathComponent("log-issues-\(timestamp).json")
            let csvURL = paths.logsDirectory.appendingPathComponent("log-issues-\(timestamp).csv")

            try Data(LogService.triageMarkdown(report: report, generatedAt: generatedAt).utf8)
                .write(to: markdownURL, options: [.atomic])

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: jsonURL, options: [.atomic])
            try Data(LogIssueReport.csv(report: report).utf8).write(to: csvURL, options: [.atomic])

            print(markdownURL.path)
            print(jsonURL.path)
            print(csvURL.path)
        } catch {
            fputs("MacWin log issue report export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runLogMaintenanceExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let generatedAt = Date()
            let report = LogService(paths: paths).maintenanceReport(generatedAt: generatedAt)
            let urls = try writeReportArtifacts(
                jsonName: "log-maintenance",
                csvName: "log-maintenance",
                jsonData: encodeJSON(report),
                csvText: LogMaintenanceReport.csv(report: report),
                paths: paths
            )
            let scriptURL = paths.logsDirectory.appendingPathComponent("log-maintenance-\(compactTimestamp(generatedAt)).sh")
            let latestScriptURL = paths.logsDirectory.appendingPathComponent("log-maintenance-latest.sh")
            let scriptData = Data(LogService.maintenanceShellScript(for: report).utf8)
            try scriptData.write(to: scriptURL, options: [.atomic])
            try scriptData.write(to: latestScriptURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: latestScriptURL.path)
            (urls + [scriptURL, latestScriptURL]).forEach { print($0.path) }
        } catch {
            fputs("MacWin log maintenance export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runLogMaintenanceArchive() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let generatedAt = Date()
            let service = LogService(paths: paths)
            let report = service.maintenanceReport(generatedAt: generatedAt)
            let result = try service.archiveCleanupCandidates(report: report, generatedAt: generatedAt)
            let resultURL = paths.logsDirectory.appendingPathComponent("log-maintenance-archive-\(compactTimestamp(generatedAt)).json")
            let latestURL = paths.logsDirectory.appendingPathComponent("log-maintenance-archive-latest.json")
            let data = try encodeJSON(result)
            try data.write(to: resultURL, options: [.atomic])
            try data.write(to: latestURL, options: [.atomic])
            print(resultURL.path)
            print(latestURL.path)
            print("archivedCount=\(result.archivedCount)")
            print("archivedBytes=\(result.archivedBytes)")
            print("archivePath=\(result.archivePath)")
        } catch {
            fputs("MacWin log maintenance archive failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runTestRunHistoryExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let report = TestRunHistoryService().report(limit: 200)
            let generatedAt = Date()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let timestamp = formatter.string(from: generatedAt)
                .replacingOccurrences(of: ":", with: "")
            let jsonURL = paths.logsDirectory.appendingPathComponent("test-run-history-\(timestamp).json")
            let csvURL = paths.logsDirectory.appendingPathComponent("test-run-history-\(timestamp).csv")
            let latestJSONURL = paths.logsDirectory.appendingPathComponent("test-run-history-latest.json")
            let latestCSVURL = paths.logsDirectory.appendingPathComponent("test-run-history-latest.csv")

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(report)
            try jsonData.write(to: jsonURL, options: [.atomic])
            try jsonData.write(to: latestJSONURL, options: [.atomic])
            let csvData = Data(TestRunHistoryReport.csv(report: report).utf8)
            try csvData.write(to: csvURL, options: [.atomic])
            try csvData.write(to: latestCSVURL, options: [.atomic])

            print(jsonURL.path)
            print(csvURL.path)
            print(latestJSONURL.path)
            print(latestCSVURL.path)
        } catch {
            fputs("MacWin test run history export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runSoftwareTestPlanExport() {
        do {
            let paths = MacWinPaths()
            let report = try makeCapabilityReport(paths: paths, logLimit: 80).softwareTestPlan
            let urls = try writeReportArtifacts(
                jsonName: "software-test-plan",
                csvName: "software-test-plan",
                jsonData: encodeJSON(report),
                csvText: SoftwareTestPlanService.csv(report: report),
                paths: paths
            )
            urls.forEach { print($0.path) }
        } catch {
            fputs("MacWin software test plan export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runSoftwareSmokeMatrixExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let report = CapabilityReportService(paths: paths).makeSoftwareSmokeMatrixReport(
                engines: try EngineRegistry(paths: paths).listEngines(),
                bottles: try BottleService(paths: paths).listBottles(),
                recipes: try loadRecipes(paths: paths),
                logLimit: 80
            )
            let urls = try writeReportArtifacts(
                jsonName: "software-smoke-matrix",
                csvName: "software-smoke-matrix",
                jsonData: encodeJSON(report),
                csvText: SoftwareSmokeMatrixService.csv(report: report),
                paths: paths
            )
            urls.forEach { print($0.path) }
        } catch {
            fputs("MacWin software smoke matrix export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runSoftwareSampleCatalogExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let recipes = try loadRecipes(paths: paths)
            let report = SoftwareSampleCatalogService(paths: paths).report(recipes: recipes)
            let urls = try writeReportArtifacts(
                jsonName: "software-sample-catalog",
                csvName: "software-sample-catalog",
                jsonData: encodeJSON(report),
                csvText: SoftwareSampleCatalogService.csv(report: report),
                paths: paths
            )
            let runbookURL = paths.logsDirectory.appendingPathComponent("software-sample-catalog-runbook.md")
            try Data(SoftwareSampleCatalogService.runbookMarkdown(report: report).utf8)
                .write(to: runbookURL, options: [.atomic])
            (urls + [runbookURL]).forEach { print($0.path) }
        } catch {
            fputs("MacWin software sample catalog export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runSoftwareSamplePreparationExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let recipes = try loadRecipes(paths: paths)
            let service = SoftwareSampleCatalogService(paths: paths)
            let catalog = service.report(recipes: recipes)
            let result = try service.exportPreparationSnapshot(catalog: catalog)
            print(result.directoryURL.path)
            print(result.manifestURL.path)
            print(result.reportURL.path)
            print(result.csvURL.path)
            print(result.markdownURL.path)
            print(result.runbookURL.path)
        } catch {
            fputs("MacWin software sample preparation export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runSoftwareSampleCoverageExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let capability = try makeCapabilityReport(paths: paths, logLimit: 80)
            let sampleService = SoftwareSampleCatalogService(paths: paths)
            let catalog = capability.softwareSampleCatalog
            let preparation = sampleService.preparationReport(catalog: catalog, generatedAt: catalog.generatedAt)
            let launchRecords = capability.launchHistory?.records ?? []
            let smokeReports = (try? SoftwareSmokeRunReportService(paths: paths).reports(limit: 250))
                ?? capability.softwareSmokeRuns?.reports
                ?? []
            let report = sampleService.smokeCoverageReport(
                preparation: preparation,
                smokeMatrix: capability.softwareSmokeMatrix,
                launchRecords: launchRecords,
                smokeReports: smokeReports,
                generatedAt: capability.generatedAt
            )
            let urls = try writeReportArtifacts(
                jsonName: "software-sample-coverage",
                csvName: "software-sample-coverage",
                jsonData: encodeJSON(report),
                csvText: SoftwareSampleCatalogService.smokeCoverageCSV(report: report),
                paths: paths
            )
            let markdownURL = paths.logsDirectory.appendingPathComponent("software-sample-coverage.md")
            try Data(SoftwareSampleCatalogService.smokeCoverageMarkdown(report: report).utf8)
                .write(to: markdownURL, options: [.atomic])
            (urls + [markdownURL]).forEach { print($0.path) }
        } catch {
            fputs("MacWin software sample coverage export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runRuntimeProcessExport() {
        do {
            let paths = MacWinPaths()
            let report = RuntimeProcessAuditService().makeReport()
            let artifact = try RuntimeProcessSnapshotService(paths: paths).writeSnapshot(report: report)
            let csvURL = paths.logsDirectory.appendingPathComponent("runtime-processes.csv")
            try Data(RuntimeProcessAuditReport.csv(report: report).utf8).write(to: csvURL, options: [.atomic])
            print(artifact.jsonURL.path)
            print(artifact.logURL.path)
            print(csvURL.path)
        } catch {
            fputs("MacWin runtime process export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runSupportTriageExport() {
        do {
            let paths = MacWinPaths()
            let report = try makeSupportTriageReport(paths: paths)
            let result = try SupportTriageSnapshotService(paths: paths).export(
                report: report,
                generatedAt: report.generatedAt
            )
            [
                result.jsonURL,
                result.csvURL,
                result.markdownURL,
                result.latestJSONURL,
                result.latestCSVURL,
                result.latestMarkdownURL
            ].forEach { print($0.path) }
        } catch {
            fputs("MacWin support triage export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runNativeUIBridgeHealthExport() {
        do {
            let paths = MacWinPaths()
            try paths.ensureBaseDirectories()
            let generatedAt = Date()
            let engines = try EngineRegistry(paths: paths).listEngines()
            let report = NativeUIBridgeHealthService().report(
                engines: engines,
                generatedAt: generatedAt
            )
            let directory = paths.logsDirectory.appendingPathComponent("NativeUIBridge", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestampURL = directory.appendingPathComponent(
                "native-ui-bridge-health-\(compactTimestamp(generatedAt)).json"
            )
            let latestURL = directory.appendingPathComponent("native-ui-bridge-health-latest.json")
            let store = JSONStore()
            try store.save(report, to: timestampURL)
            try store.save(report, to: latestURL)
            print(timestampURL.path)
            print(latestURL.path)
        } catch {
            fputs("MacWin native UI bridge health export failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func makeCapabilityReport(paths: MacWinPaths, logLimit: Int = 24) throws -> CapabilityReport {
        try paths.ensureBaseDirectories()
        let engines = try EngineRegistry(paths: paths).listEngines()
        let bottles = try BottleService(paths: paths).listBottles()
        let recipes = try loadRecipes(paths: paths)
        return CapabilityReportService(paths: paths).makeReport(
            engines: engines,
            bottles: bottles,
            recipes: recipes,
            logLimit: logLimit
        )
    }

    private static func makeSupportTriageReport(paths: MacWinPaths) throws -> SupportTriageReport {
        let capability = try makeCapabilityReport(paths: paths, logLimit: 80)
        let adaptationQueue = SoftwareAdaptationQueueService(paths: paths).report(
            softwareTestPlan: capability.softwareTestPlan,
            softwareSmokeMatrix: capability.softwareSmokeMatrix,
            logIssues: capability.logs.issueReport,
            testAssets: capability.testAssets,
            generatedAt: capability.generatedAt
        )
        let collection = SoftwareCollectionService(paths: paths).report(
            recipes: try loadRecipes(paths: paths),
            readiness: capability.recipeReadiness,
            installerAssets: capability.installerAssets,
            softwareTestPlan: capability.softwareTestPlan,
            softwareSmokeMatrix: capability.softwareSmokeMatrix,
            adaptationQueue: adaptationQueue,
            generatedAt: capability.generatedAt
        )
        let acceptance = SoftwareCollectionAcceptanceService().report(
            collection: collection,
            smokeMatrix: capability.softwareSmokeMatrix,
            testExecutionPlan: capability.testExecutionPlan,
            logIssues: capability.logs.issueReport,
            generatedAt: capability.generatedAt
        )
        let samplePreparation = SoftwareSampleCatalogService(paths: paths).preparationReport(
            catalog: capability.softwareSampleCatalog,
            generatedAt: capability.generatedAt
        )
        let softwareAcquisition = SoftwareAcquisitionService().report(
            collection: collection,
            samplePreparation: samplePreparation,
            generatedAt: capability.generatedAt
        )
        let launchHealth = LaunchHealthService(paths: paths).report(
            launchHistory: capability.launchHistory,
            logs: capability.logs,
            smokeReports: capability.softwareSmokeRuns?.reports ?? [],
            generatedAt: capability.generatedAt
        )
        let externalOpenQueue = ExternalExecutableOpenQueueService(paths: paths).report(
            generatedAt: capability.generatedAt
        )
        return SupportTriageService().report(
            generatedAt: capability.generatedAt,
            capability: capability,
            logRemediation: LogService.remediationPlan(
                report: capability.logs.issueReport,
                generatedAt: capability.generatedAt
            ),
            softwareAcceptance: acceptance,
            softwareAcquisition: softwareAcquisition,
            launchHealth: launchHealth,
            externalOpenQueue: externalOpenQueue
        )
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func writeReportArtifacts(
        jsonName: String,
        csvName: String,
        jsonData: Data,
        csvText: String,
        paths: MacWinPaths
    ) throws -> [URL] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let jsonURL = paths.logsDirectory.appendingPathComponent("\(jsonName)-\(timestamp).json")
        let csvURL = paths.logsDirectory.appendingPathComponent("\(csvName)-\(timestamp).csv")
        let latestJSONURL = paths.logsDirectory.appendingPathComponent("\(jsonName)-latest.json")
        let latestCSVURL = paths.logsDirectory.appendingPathComponent("\(csvName)-latest.csv")
        try jsonData.write(to: jsonURL, options: [.atomic])
        try jsonData.write(to: latestJSONURL, options: [.atomic])
        let csvData = Data(csvText.utf8)
        try csvData.write(to: csvURL, options: [.atomic])
        try csvData.write(to: latestCSVURL, options: [.atomic])
        return [jsonURL, csvURL, latestJSONURL, latestCSVURL]
    }

    private enum RuntimeProcessTerminationMode {
        case wineVirtualDesktops
        case detachedWineSystemProcesses
        case all
    }

    private static func runRuntimeProcessTermination(mode: RuntimeProcessTerminationMode) {
        let report = RuntimeProcessAuditService().makeReport()
        let terminator = RuntimeProcessTerminator()
        let result: RuntimeProcessTerminationReport
        switch mode {
        case .wineVirtualDesktops:
            result = terminator.terminateWineVirtualDesktopProcesses(in: report)
        case .detachedWineSystemProcesses:
            result = terminator.terminateDetachedWineSystemProcesses(in: report)
        case .all:
            result = terminator.terminateAllRuntimeProcesses(in: report)
        }

        print("requested=\(result.requestedCount)")
        print("stopped=\(result.stoppedCount)")
        print("failed=\(result.failedCount)")
        if !result.stoppedProcessIdentifiers.isEmpty {
            print("stoppedPids=\(result.stoppedProcessIdentifiers.map(String.init).joined(separator: ","))")
        }
        if !result.failedProcessIdentifiers.isEmpty {
            print("failedPids=\(result.failedProcessIdentifiers.map(String.init).joined(separator: ","))")
            exit(1)
        }
    }

    private static func compactTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "")
    }

    private static func runInstalledAppScan(arguments: [String], optionIndex: Int) {
        guard arguments.indices.contains(optionIndex + 1) else {
            fputs("MacWin installed app scan failed: missing bottle id after --scan-installed-apps\n", stderr)
            exit(2)
        }

        do {
            let bottleId = arguments[optionIndex + 1]
            let paths = MacWinPaths()
            let engineRegistry = EngineRegistry(paths: paths)
            let bottleService = BottleService(paths: paths)
            guard let bottle = try bottleService.bottle(id: bottleId) else {
                fputs("MacWin installed app scan failed: bottle not found: \(bottleId)\n", stderr)
                exit(2)
            }
            let engines = try engineRegistry.listEngines()
            let engine = engines.first(where: { $0.id == bottle.engineId }) ?? engines.first
            if let engine {
                try bottleService.repairBottleCompatibility(bottle, engine: engine)
            } else {
                let detectedBottle = try bottleService.registerDetectedInstalledApps(in: bottle)
                _ = try bottleService.migrateLauncherCompatibility(in: detectedBottle)
            }
            let updated = try bottleService.bottle(id: bottleId) ?? bottle
            print("bottle=\(updated.id)")
            print("installedApps=\(updated.installedApps.count)")
            for launcher in updated.installedApps.sorted(by: { $0.displayName < $1.displayName }) {
                print("\(launcher.id)\t\(launcher.displayName)\t\(launcher.exePath)")
            }
        } catch {
            fputs("MacWin installed app scan failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func loadRecipes(paths: MacWinPaths) throws -> [RecipeManifest] {
        let candidates = [
            Bundle.module.url(forResource: "catalog.index", withExtension: "json", subdirectory: "Catalog"),
            paths.catalogDirectory.appendingPathComponent("catalog.index.json")
        ].compactMap(\.self)

        guard let indexURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return []
        }

        let keyData = Data(base64Encoded: CatalogTrust.developmentPublicKeyBase64)!
        let publicKey = try P256.Signing.PublicKey(rawRepresentation: keyData)
        let snapshot = try CatalogService(
            source: CatalogSource(root: indexURL.deletingLastPathComponent()),
            trustedPublicKeys: [CatalogTrust.developmentKeyId: publicKey]
        ).refresh()
        return snapshot.recipes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private final class SmokeLaunchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<WineSmokeResult, Error>?

    func set(_ result: Result<WineSmokeResult, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> WineSmokeResult {
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

private final class InstallTaskResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<InstallTask, Error>?

    func set(_ result: Result<InstallTask, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() throws -> InstallTask {
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

private struct MacWinRootView: View {
    @ObservedObject var store: MacWinStore

    var body: some View {
        ContentView()
            .overlay(alignment: .bottomTrailing) { ResourceConsumptionView().padding(12) }
            .environmentObject(store)
            .frame(minWidth: 1040, minHeight: 700)
            .ignoresSafeArea(.container, edges: .top)
            .onOpenURL { url in
                Task { await store.handleExternalExecutableOpen(url) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .macWinExternalOpenURLs)) { notification in
                guard let urls = notification.object as? [URL] else { return }
                for url in urls {
                    Task { await store.handleExternalExecutableOpen(url) }
                }
            }
            .task {
                // Let AppKit create and paint the native window before the
                // compatibility catalog and bottle scans occupy the main actor.
                try? await Task.sleep(for: .milliseconds(800))
                await store.bootstrapIfNeeded()
                await store.drainQueuedExternalExecutableOpens()
                store.startExternalExecutableOpenQueueWatcher()
                store.startBottleRuntimeCleanupWatcher()
            }
    }
}

@main
struct MacWinManagerApp: App {
    @NSApplicationDelegateAdaptor(MacWinAppDelegate.self) private var appDelegate
    @StateObject private var store = MacWinStore.shared

    init() {
        MacWinCommandLineTool.runIfRequested()
        MacWinLaunchCoordinator.shared.prepareEarlyLaunch()
        if !MacWinLaunchCoordinator.shared.isPrimaryInstance {
            MacWinLaunchCoordinator.shared.forwardAndExit()
        }
    }

    var body: some Scene {
        WindowGroup {
            if MacWinLaunchCoordinator.shared.isPrimaryInstance {
                MacWinRootView(store: store)
            } else {
                HiddenDuplicateLaunchView()
                    .frame(width: 1, height: 1)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
            .commands {
                CommandGroup(replacing: .newItem) {
                Button(store.text(.createBottle)) {
                    Task { await store.createBottle(named: store.text(.defaultBottleName)) }
                }
                .keyboardShortcut("n")
            }
        }
    }
}

private struct HiddenDuplicateLaunchView: View {
    var body: some View {
        Color.clear
            .onAppear {
                NSApp.setActivationPolicy(.prohibited)
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
                MacWinLaunchCoordinator.shared.forwardAndExit()
            }
    }
}
