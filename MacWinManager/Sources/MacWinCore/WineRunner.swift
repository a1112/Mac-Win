import Darwin
import CoreText
import Foundation

public struct WineRunRequest: Sendable {
    public var exe: String
    public var args: [String]
    public var bottle: BottleManifest
    public var engine: EngineManifest
    public var envOverrides: [String: String]
    public var workingDirectory: URL?
    public var logName: String?

    public init(
        exe: String,
        args: [String] = [],
        bottle: BottleManifest,
        engine: EngineManifest,
        envOverrides: [String: String] = [:],
        workingDirectory: URL? = nil,
        logName: String? = nil
    ) {
        self.exe = exe
        self.args = args
        self.bottle = bottle
        self.engine = engine
        self.envOverrides = envOverrides
        self.workingDirectory = workingDirectory
        self.logName = logName
    }
}

public struct WineRunResult: Equatable, Sendable {
    public var exitCode: Int32
    public var logURL: URL
    public var commandLine: [String]
    public var output: String

    public init(exitCode: Int32, logURL: URL, commandLine: [String], output: String) {
        self.exitCode = exitCode
        self.logURL = logURL
        self.commandLine = commandLine
        self.output = output
    }
}

public struct WineLaunchResult: Equatable, Sendable {
    public var processIdentifier: Int32
    public var logURL: URL
    public var commandLine: [String]

    public init(processIdentifier: Int32, logURL: URL, commandLine: [String]) {
        self.processIdentifier = processIdentifier
        self.logURL = logURL
        self.commandLine = commandLine
    }
}

public struct WineSmokeResult: Equatable, Sendable {
    public var timedOut: Bool
    public var exitCode: Int32
    public var logURL: URL
    public var commandLine: [String]
    public var elapsedSeconds: TimeInterval

    public init(
        timedOut: Bool,
        exitCode: Int32,
        logURL: URL,
        commandLine: [String],
        elapsedSeconds: TimeInterval
    ) {
        self.timedOut = timedOut
        self.exitCode = exitCode
        self.logURL = logURL
        self.commandLine = commandLine
        self.elapsedSeconds = elapsedSeconds
    }
}

struct HostProcessLine: Equatable, Sendable {
    var pid: Int32
    var command: String
}

public struct WineRunner {
    public var paths: MacWinPaths
    public var fileManager: FileManager
    public var processEnvironmentProvider: () -> [String: String]
    public var hostNetworkEnvironmentProvider: () -> [String: String]
    public var rosettaX87Path: String
    public var uninterruptibleRuntimeProcessProvider: @Sendable () -> [Int32]

    public init(
        paths: MacWinPaths = MacWinPaths(),
        fileManager: FileManager = .default,
        processEnvironmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        hostNetworkEnvironmentProvider: @escaping () -> [String: String] = HostNetworkEnvironment.current,
        rosettaX87Path: String = EngineRegistry.currentRosettaX87Path,
        uninterruptibleRuntimeProcessProvider: @escaping @Sendable () -> [Int32] = {
            RuntimeProcessAuditService().makeReport().uninterruptibleProcessIdentifiers
        }
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.processEnvironmentProvider = processEnvironmentProvider
        self.hostNetworkEnvironmentProvider = hostNetworkEnvironmentProvider
        self.rosettaX87Path = rosettaX87Path
        self.uninterruptibleRuntimeProcessProvider = uninterruptibleRuntimeProcessProvider
    }

    public func mergedEnvironment(
        engine: EngineManifest,
        bottle: BottleManifest,
        recipeEnv: [String: String] = [:],
        launchEnv: [String: String] = [:]
    ) -> [String: String] {
        var env = Self.sanitizedHostProcessEnvironment(processEnvironmentProvider())
        for (key, value) in hostNetworkEnvironmentProvider() where env[key] == nil {
            env[key] = value
        }
        for (key, value) in engine.defaultEnv {
            env[key] = value
        }
        let bottleDirectory = paths.bottleDirectory(id: bottle.id)
        env["WINEPREFIX"] = bottleDirectory.path
        env["WINEARCH"] = bottle.arch.rawValue
        env["MACWIN_MANAGED_LAUNCH"] = "1"
        env["MACWIN_APP_MODE_INPUT_REPAIR"] = env["MACWIN_APP_MODE_INPUT_REPAIR"] ?? "1"
        env["MACWIN_DOCK_POLICY"] = "managed-app-mode"
        let fontConfigURL = BottleService.fontConfigURL(for: bottle.id, paths: paths)
        if fileManager.fileExists(atPath: fontConfigURL.path) {
            env["FONTCONFIG_FILE"] = fontConfigURL.path
            env["FONTCONFIG_PATH"] = bottleDirectory.path
            env["FC_LANG"] = "zh-cn"
            if env["LC_CTYPE"] == nil {
                env["LC_CTYPE"] = env["LC_ALL"] ?? env["LANG"] ?? "zh_CN.UTF-8"
            }
        }
        for (key, value) in bottle.envOverrides {
            env[key] = value
        }
        for (key, value) in recipeEnv {
            env[key] = value
        }
        for (key, value) in launchEnv {
            env[key] = value
        }
        if env["MACWIN_DISABLE_WINE_D3D_CONFIG"] == "1" {
            env.removeValue(forKey: "WINE_D3D_CONFIG")
        }
        if env["MACWIN_ALLOW_WINE_MENU_BUILDER"] != "1" {
            env["WINEDLLOVERRIDES"] = Self.dllOverrides(
                env["WINEDLLOVERRIDES"],
                ensuring: "winemenubuilder.exe=d"
            )
        }
        return Self.sanitizedRuntimeEnvironment(env)
    }

    public func commandLine(for request: WineRunRequest) -> [String] {
        let request = sanitizedRuntimeRequest(request)
        return ["/usr/bin/arch", "-x86_64", request.engine.winePath, request.exe] + request.args
    }

    public func sanitizedRuntimeRequest(_ request: WineRunRequest) -> WineRunRequest {
        var sanitized = request
        let explicitLaunchEnv = Self.sanitizedRuntimeEnvironment(request.envOverrides)
        let disabledProfile = explicitLaunchEnv["MACWIN_COMPAT_PROFILE"]?.lowercased()
            == ApplicationCompatibilityProfile.disabledProfileValue

        if !disabledProfile,
           let profile = ApplicationCompatibilityProfile.matched(exePath: request.exe),
           profile == .bambuStudioSoftwareOpenGL
            || profile == .blenderSoftwareOpenGL
            || profile == .browserGecko
            || profile == .freeCADOpenGL
            || profile == .kiCadEDA
            || profile == .libreCADQt
            || profile == .jabRefJavaFXD3D
            || profile == .jaspQtWebEngineQrc
            || profile == .meshLabSoftwareOpenGL
            || profile == .openSCADSoftwareOpenGL
            || profile == .sweetHome3DOpenGL
            || profile == .mRemoteNG1782
            || profile == .museScoreStudio
            || profile == .officeSuite
            || profile == .orcaSlicerNativeOpenGL
            || profile == .wpsOffice
            || profile == .qtRhiSoftware
            || profile == .softMakerOffice
            || profile == .supermium32Browser
            || profile == .texStudioQt6
            || profile == .zoteroGecko32 {
            let displayName = URL(fileURLWithPath: request.exe.replacingOccurrences(of: "\\", with: "/"))
                .deletingPathExtension()
                .lastPathComponent
            let launcher = LauncherManifest(
                id: "runtime-\(displayName.isEmpty ? "executable" : displayName)",
                appId: "runtime-executable",
                bottleId: request.bottle.id,
                displayName: displayName.isEmpty ? request.exe : displayName,
                exePath: request.exe,
                args: request.args
            )
            let profiledLauncher = profile.applied(to: launcher)
            sanitized.args = profiledLauncher.args
            sanitized.envOverrides = Self.sanitizedRuntimeEnvironment(
                profiledLauncher.envOverrides.merging(explicitLaunchEnv) { _, explicit in explicit }
            )
        } else {
            sanitized.args = ApplicationCompatibilityProfile.sanitizedLaunchArguments(request.args)
            sanitized.envOverrides = explicitLaunchEnv
        }
        if sanitized.envOverrides["ROSETTA_X87_PATH"] == nil,
           sanitized.engine.supportsWin32,
           Self.requiresRosettaX87(exePath: sanitized.exe),
           fileManager.isExecutableFile(atPath: rosettaX87Path) {
            sanitized.envOverrides["ROSETTA_X87_PATH"] = rosettaX87Path
        }
        return sanitized
    }

    static func requiresRosettaX87(exePath: String) -> Bool {
        let path = exePath.lowercased().replacingOccurrences(of: "/", with: "\\")
        return path.contains("\\program files (x86)\\pale moon\\")
            || path.contains("\\program files (x86)\\winscp\\winscp.exe")
            || path.contains("\\program files (x86)\\winscp\\winscp.com")
            || path.hasSuffix("\\portableappsplatform.exe")
    }

    func ensureRuntimeAvailable(for engine: EngineManifest) throws {
        let managedEnginesPath = paths.enginesDirectory.standardizedFileURL.path + "/"
        let winePath = URL(fileURLWithPath: engine.winePath).standardizedFileURL.path
        guard winePath.hasPrefix(managedEnginesPath) else { return }
        let processIdentifiers = Array(Set(uninterruptibleRuntimeProcessProvider())).sorted()
        guard processIdentifiers.isEmpty else {
            throw MacWinError.runtimeUnavailable(processIdentifiers: processIdentifiers)
        }
    }

    public static func sanitizedRuntimeEnvironment(_ environment: [String: String]) -> [String: String] {
        var sanitized = environment
        for key in chromiumFlagEnvironmentKeys {
            guard let value = sanitized[key] else { continue }
            sanitized[key] = sanitizedChromiumFlagString(value)
        }
        if let dllOverrides = sanitized["WINEDLLOVERRIDES"] {
            sanitized["WINEDLLOVERRIDES"] = sanitizedDLLOverrides(dllOverrides)
        }
        return sanitized
    }

    public static func sanitizedHostProcessEnvironment(_ environment: [String: String]) -> [String: String] {
        var sanitized = environment
        for key in hostProxyEnvironmentKeys {
            sanitized[key] = ""
        }
        return sanitized
    }

    public func windows11DesktopRequest(
        bottle: BottleManifest,
        engine: EngineManifest,
        width: Int = 1280,
        height: Int = 720
    ) -> WineRunRequest {
        let safeWidth = max(width, 800)
        let safeHeight = max(height, 600)
        return WineRunRequest(
            exe: "C:\\windows\\system32\\explorer.exe",
            args: ["/desktop=MacWin-Windows-11,\(safeWidth)x\(safeHeight)", "C:\\windows\\system32\\winefile.exe"],
            bottle: bottle,
            engine: engine,
            envOverrides: [
                "WINE_D3D_CONFIG": engine.defaultEnv["WINE_D3D_CONFIG"] ?? "renderer=vulkan,csmt=0x0"
            ],
            logName: "\(bottle.id)-windows11-desktop.log"
        )
    }

    @discardableResult
    public func run(_ request: WineRunRequest, recipeEnv: [String: String] = [:]) throws -> WineRunResult {
        try ensureRuntimeAvailable(for: request.engine)
        let request = sanitizedRuntimeRequest(request)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let logURL = makeLogURL(logName: request.logName, bottleId: request.bottle.id, exe: request.exe)
        let commandLine = commandLine(for: request)
        let startedAt = Date()
        let launchRecordURL = try makeLaunchRecordURL(logURL: logURL, startedAt: startedAt)
        let environment = mergedEnvironment(
            engine: request.engine,
            bottle: request.bottle,
            recipeEnv: recipeEnv,
            launchEnv: request.envOverrides
        )
        try applyRuntimeCompatibilityRepairs(for: request, environment: environment)
        let workingDirectory = try workingDirectory(for: request)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", request.engine.winePath, request.exe] + request.args
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            LenovoAppStorePageRepairService.startIfNeeded(environment: environment, launchLogURL: logURL)
        } catch {
            try? Self.saveLaunchRecord(
                Self.launchRecord(
                    id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                    request: request,
                    mode: .foregroundRun,
                    state: .failedToLaunch,
                    logURL: logURL,
                    commandLine: commandLine,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    startedAt: startedAt,
                    endedAt: Date(),
                    errorMessage: error.localizedDescription
                ),
                to: launchRecordURL
            )
            throw MacWinError.processLaunchFailed(error.localizedDescription)
        }

        activateWineApplicationIfNeeded(for: request, environment: environment, launchedProcess: process)

        process.waitUntilExit()
        if environment["MACWIN_ONLYOFFICE_RENDERER_FONT_REPAIR"] == "1" {
            try? applyOnlyOfficeRendererFontRepair(for: request, waitForSource: true)
        }
        let endedAt = Date()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var logData = Self.logHeader(
            request: request,
            commandLine: commandLine,
            environment: environment,
            workingDirectory: workingDirectory,
            startedAt: startedAt,
            detached: false
        )
        logData.append(data)
        logData.append(Self.logFooter(exitCode: process.terminationStatus, endedAt: endedAt))
        try logData.write(to: logURL, options: [.atomic])
        try Self.saveLaunchRecord(
            Self.launchRecord(
                id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                request: request,
                mode: .foregroundRun,
                state: .completed,
                logURL: logURL,
                commandLine: commandLine,
                environment: environment,
                workingDirectory: workingDirectory,
                startedAt: startedAt,
                endedAt: endedAt,
                exitCode: process.terminationStatus
            ),
            to: launchRecordURL
        )
        let output = String(data: data, encoding: .utf8) ?? ""

        return WineRunResult(
            exitCode: process.terminationStatus,
            logURL: logURL,
            commandLine: commandLine,
            output: output
        )
    }

    @discardableResult
    public func smokeLaunch(
        _ request: WineRunRequest,
        timeoutSeconds: TimeInterval = 30,
        recipeEnv: [String: String] = [:]
    ) throws -> WineSmokeResult {
        try ensureRuntimeAvailable(for: request.engine)
        let request = sanitizedRuntimeRequest(request)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let logURL = makeLogURL(logName: request.logName, bottleId: request.bottle.id, exe: request.exe)
        let startedAt = Date()
        let launchRecordURL = try makeLaunchRecordURL(logURL: logURL, startedAt: startedAt)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        let commandLine = commandLine(for: request)
        var environment = mergedEnvironment(
            engine: request.engine,
            bottle: request.bottle,
            recipeEnv: recipeEnv,
            launchEnv: request.envOverrides
        )
        environment["MACWIN_DISABLE_WINE_APP_ACTIVATION"] = "1"
        try applyRuntimeCompatibilityRepairs(for: request, environment: environment)
        let workingDirectory = try workingDirectory(for: request)
        try handle.write(contentsOf: Self.logHeader(
            request: request,
            commandLine: commandLine,
            environment: environment,
            workingDirectory: workingDirectory,
            startedAt: startedAt,
            detached: false
        ))
        let preflightCleanup = terminateDetachedRuntimeProcesses(
            inWinePrefix: paths.bottleDirectory(id: request.bottle.id).path
        )
        try writeRuntimePreflightCleanupReport(preflightCleanup, to: handle)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", request.engine.winePath, request.exe] + request.args
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = handle
        process.standardError = handle

        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completed.signal()
        }
        let delegatedProcessPIDsBeforeLaunch = Set(Self.delegatedWineProcessLines(
            in: hostProcessLines(),
            for: request
        ).map(\.pid))
        let runtimeProcessPIDsBeforeLaunch = Set(
            RuntimeProcessAuditService().makeReport().stoppableProcessIdentifiers
        )

        do {
            try process.run()
            LenovoAppStorePageRepairService.startIfNeeded(environment: environment, launchLogURL: logURL)
        } catch {
            try? handle.close()
            try? Self.saveLaunchRecord(
                Self.launchRecord(
                    id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                    request: request,
                    mode: .foregroundRun,
                    state: .failedToLaunch,
                    logURL: logURL,
                    commandLine: commandLine,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    startedAt: startedAt,
                    endedAt: Date(),
                    errorMessage: error.localizedDescription
                ),
                to: launchRecordURL
            )
            throw MacWinError.processLaunchFailed(error.localizedDescription)
        }

        activateWineApplicationIfNeeded(for: request, environment: environment, launchedProcess: process)

        let timeout = max(timeoutSeconds, 1)
        var timedOut = false
        var timedOutExitCode: Int32?
        var delegatedLaunchSucceeded = false
        if !Self.waitForSignal(completed, timeoutSeconds: timeout) {
            timedOut = true
            timedOutExitCode = SIGTERM
            try handle.write(contentsOf: Data("smokeOutcome=keptAlive\n".utf8))
            try handle.write(contentsOf: Data("\nTIMEOUT after \(Int(timeout))s; sending SIGTERM to \(process.processIdentifier)\n".utf8))
            Darwin.kill(process.processIdentifier, SIGTERM)
            if !Self.waitForSignal(completed, timeoutSeconds: 0.5, pollInterval: 0.05) {
                try handle.write(contentsOf: Data("SIGTERM timeout; sending SIGKILL\n".utf8))
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            try handle.write(contentsOf: Data("Requesting wineserver -k for smoke timeout cleanup\n".utf8))
            let wineServerCleanupCompleted = terminateWineServerForRegistryTimeout(
                request: request,
                environment: environment,
                timeoutSeconds: 2
            )
            try handle.write(contentsOf: Data("wineserverCleanup=\(wineServerCleanupCompleted ? "completed" : "timedOut")\n".utf8))
            let residualCleanup = terminateRuntimeProcessesStartedAfterLaunch(
                excluding: runtimeProcessPIDsBeforeLaunch
            )
            try writeRuntimeCleanupReport(residualCleanup, to: handle)
        } else {
            let delegatedProcesses = Self.isDelegatedWineProcessCandidate(for: request)
                ? waitForDelegatedWineProcesses(
                    for: request,
                    excluding: delegatedProcessPIDsBeforeLaunch,
                    timeoutSeconds: min(max(timeout * 0.8, 5), 25)
                )
                : []
            let reusableDelegatedProcesses = delegatedProcesses.isEmpty && process.terminationStatus == 0
                ? Self.delegatedWineProcessLines(in: hostProcessLines(), for: request)
                : []
            let keptAliveDelegatedProcesses = delegatedProcesses.isEmpty
                ? reusableDelegatedProcesses
                : delegatedProcesses
            let assumesSuccessfulDelegation = keptAliveDelegatedProcesses.isEmpty
                && process.terminationStatus == 0
                && Self.allowsAssumedDelegationSuccess(for: request)
            if keptAliveDelegatedProcesses.isEmpty && !assumesSuccessfulDelegation {
                try handle.write(contentsOf: Data("\nsmokeOutcome=earlyExit\n".utf8))
            } else {
                delegatedLaunchSucceeded = true
                let delegatedPIDs = keptAliveDelegatedProcesses
                    .map { String($0.pid) }
                    .sorted()
                    .joined(separator: ",")
                try handle.write(contentsOf: Data("\nsmokeOutcome=keptAlive\n".utf8))
                try handle.write(contentsOf: Data("smokeDelegatedProcess=true\n".utf8))
                if !reusableDelegatedProcesses.isEmpty {
                    try handle.write(contentsOf: Data("smokeDelegatedProcessReused=true\n".utf8))
                }
                if assumesSuccessfulDelegation {
                    try handle.write(contentsOf: Data("smokeDelegatedProcessAssumed=true\n".utf8))
                }
                try handle.write(contentsOf: Data("smokeParentExitCode=\(process.terminationStatus)\n".utf8))
                if !delegatedPIDs.isEmpty {
                    try handle.write(contentsOf: Data("smokeDelegatedPIDs=\(delegatedPIDs)\n".utf8))
                }
                let residualCleanup = terminateRuntimeProcessesStartedAfterLaunch(
                    excluding: runtimeProcessPIDsBeforeLaunch
                )
                try writeRuntimeCleanupReport(residualCleanup, to: handle)
            }
        }

        let endedAt = Date()
        let exitCode = timedOutExitCode ?? (delegatedLaunchSucceeded ? 0 : process.terminationStatus)
        try handle.write(contentsOf: Self.logFooter(exitCode: exitCode, endedAt: endedAt))
        try handle.close()
        try Self.saveLaunchRecord(
            Self.launchRecord(
                id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                request: request,
                mode: .foregroundRun,
                state: .completed,
                logURL: logURL,
                commandLine: commandLine,
                environment: environment,
                workingDirectory: workingDirectory,
                startedAt: startedAt,
                endedAt: endedAt,
                exitCode: exitCode
            ),
            to: launchRecordURL
        )
        return WineSmokeResult(
            timedOut: timedOut,
            exitCode: exitCode,
            logURL: logURL,
            commandLine: commandLine,
            elapsedSeconds: endedAt.timeIntervalSince(startedAt)
        )
    }

    func waitForDelegatedWineProcesses(
        for request: WineRunRequest,
        excluding existingPIDs: Set<Int32>,
        timeoutSeconds: TimeInterval
    ) -> [HostProcessLine] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            let delegatedProcesses = Self.delegatedWineProcessLines(
                in: hostProcessLines(),
                for: request
            ).filter { !existingPIDs.contains($0.pid) }
            if !delegatedProcesses.isEmpty {
                return delegatedProcesses
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return []
    }

    func hostProcessLines() -> [HostProcessLine] {
        let ps = Process()
        let pipe = Pipe()
        let output = WineRunnerProcessOutputBuffer()
        let outputQueue = DispatchQueue(label: "dev.local.macwin.wine-runner.ps-output")
        let outputRead = DispatchSemaphore(value: 0)
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["axww", "-o", "pid=,command="]
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        let completed = DispatchSemaphore(value: 0)
        ps.terminationHandler = { _ in
            completed.signal()
        }
        do {
            try ps.run()
            outputQueue.async {
                output.set(pipe.fileHandleForReading.readDataToEndOfFile())
                outputRead.signal()
            }
        } catch {
            return []
        }
        if !Self.waitForSignal(completed, timeoutSeconds: 2) {
            ps.terminate()
            _ = Self.waitForSignal(completed, timeoutSeconds: 1)
            _ = Self.waitForSignal(outputRead, timeoutSeconds: 1)
            return []
        }
        _ = Self.waitForSignal(outputRead, timeoutSeconds: 1)
        let data = output.data()
        guard let processList = String(data: data, encoding: .utf8) else { return [] }
        return Self.hostProcessLines(from: processList)
    }

    static func hostProcessLines(from processList: String) -> [HostProcessLine] {
        processList.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
            let pidText = trimmed[..<separator]
            let command = trimmed[separator...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = Int32(pidText), !command.isEmpty else { return nil }
            return HostProcessLine(pid: pid, command: command)
        }
    }

    static func delegatedWineProcessLines(
        in processLines: [HostProcessLine],
        for request: WineRunRequest
    ) -> [HostProcessLine] {
        guard isDelegatedWineProcessCandidate(for: request) else {
            return []
        }

        return processLines.filter { line in
            let command = line.command.lowercased()
            guard command.contains("c:\\program files\\mihoyo launcher\\")
                || command.contains("hyp.exe")
                || command.contains("hyphelper")
                || command.contains("c:\\program files\\tencent\\androws\\application\\")
                || command.contains("androwssvr.exe")
                || command.contains("c:\\program files (x86)\\lenovo\\leappstore\\")
                || command.contains("lenovoappstore.exe")
                || command.contains("lenovoserviceas.exe")
                || command.contains("c:\\program files (x86)\\lenovo\\lenovointernetsoftwareframework\\")
                || command.contains("lenovointernetsoftwareframework.exe")
                || command.contains("lisfservice.exe")
                || command.contains("steamwebhelper.exe")
                || command.contains("steamservice.exe") else {
                return false
            }
            return !command.contains("winedevice.exe")
                && !command.contains("wineserver")
                && !command.contains("wineboot")
                && !command.contains("crashpad_handler.exe")
        }
    }

    static func isDelegatedWineProcessCandidate(for request: WineRunRequest) -> Bool {
        let tokens = [
            request.exe,
            request.logName,
            request.envOverrides["MACWIN_COMPAT_PROFILE"],
            request.envOverrides["QTWEBENGINE_CHROMIUM_FLAGS"],
            request.envOverrides["MACWIN_CHROMIUM_HELPER_ARGS"]
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return tokens.contains("hoyoplay")
            || tokens.contains("mihoyo launcher")
            || tokens.contains("hyp.exe")
            || tokens.contains("hyphelper")
            || tokens.contains("hoyoplay-webview")
            || tokens.contains("lenovo-app-store")
            || tokens.contains("androws")
            || tokens.contains("leappstore")
            || tokens.contains("lenovoappstore")
            || tokens.contains("lenovointernetsoftwareframework")
            || tokens.contains("lisfservice")
            || tokens.contains("steam.exe")
            || tokens.contains("steam-client")
    }

    static func allowsAssumedDelegationSuccess(for request: WineRunRequest) -> Bool {
        let tokens = [
            request.exe,
            request.logName,
            request.envOverrides["MACWIN_COMPAT_PROFILE"]
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return tokens.contains("hoyoplay")
            || tokens.contains("mihoyo launcher")
            || tokens.contains("hyp.exe")
            || tokens.contains("hoyoplay-webview")
            || tokens.contains("androwslauncher.exe")
    }

    public func launchDetached(_ request: WineRunRequest, recipeEnv: [String: String] = [:]) throws -> WineLaunchResult {
        try ensureRuntimeAvailable(for: request.engine)
        let request = sanitizedRuntimeRequest(request)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let logURL = makeLogURL(logName: request.logName, bottleId: request.bottle.id, exe: request.exe)
        let startedAt = Date()
        let launchRecordURL = try makeLaunchRecordURL(logURL: logURL, startedAt: startedAt)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        let commandLine = commandLine(for: request)
        let environment = mergedEnvironment(
            engine: request.engine,
            bottle: request.bottle,
            recipeEnv: recipeEnv,
            launchEnv: request.envOverrides
        )
        try applyRuntimeCompatibilityRepairs(for: request, environment: environment)
        let workingDirectory = try workingDirectory(for: request)
        try handle.write(contentsOf: Self.logHeader(
            request: request,
            commandLine: commandLine,
            environment: environment,
            workingDirectory: workingDirectory,
            startedAt: startedAt,
            detached: true
        ))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", request.engine.winePath, request.exe] + request.args
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = handle
        process.standardError = handle
        let onlyOfficeRepairPaths = paths
        process.terminationHandler = { finishedProcess in
            let endedAt = Date()
            if environment["MACWIN_ONLYOFFICE_RENDERER_FONT_REPAIR"] == "1" {
                try? Self.applyOnlyOfficeRendererFontRepair(
                    paths: onlyOfficeRepairPaths,
                    bottle: request.bottle,
                    waitForSource: true
                )
            }
            try? Self.saveLaunchRecord(
                Self.launchRecord(
                    id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                    request: request,
                    mode: .detached,
                    state: .completed,
                    logURL: logURL,
                    commandLine: commandLine,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    processIdentifier: finishedProcess.processIdentifier,
                    exitCode: finishedProcess.terminationStatus
                ),
                to: launchRecordURL
            )
            try? handle.close()
        }

        do {
            try process.run()
            LenovoAppStorePageRepairService.startIfNeeded(environment: environment, launchLogURL: logURL)
        } catch {
            try? handle.close()
            try? Self.saveLaunchRecord(
                Self.launchRecord(
                    id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                    request: request,
                    mode: .detached,
                    state: .failedToLaunch,
                    logURL: logURL,
                    commandLine: commandLine,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    startedAt: startedAt,
                    endedAt: Date(),
                    errorMessage: error.localizedDescription
                ),
                to: launchRecordURL
            )
            throw MacWinError.processLaunchFailed(error.localizedDescription)
        }

        activateWineApplicationIfNeeded(for: request, environment: environment, launchedProcess: process)

        try Self.saveLaunchRecord(
            Self.launchRecord(
                id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                request: request,
                mode: .detached,
                state: .started,
                logURL: logURL,
                commandLine: commandLine,
                environment: environment,
                workingDirectory: workingDirectory,
                startedAt: startedAt,
                processIdentifier: process.processIdentifier
            ),
            to: launchRecordURL
        )

        return WineLaunchResult(
            processIdentifier: process.processIdentifier,
            logURL: logURL,
            commandLine: commandLine
        )
    }

    private func activateWineApplicationIfNeeded(for request: WineRunRequest, environment: [String: String], launchedProcess: Process) {
        guard environment["MACWIN_DISABLE_WINE_APP_ACTIVATION"] != "1" else {
            return
        }
        let lowercasedExecutable = request.exe.lowercased()
        guard Self.isInteractiveWineExecutable(lowercasedExecutable) else {
            return
        }
        guard environment["MACWIN_MANAGED_LAUNCH"] == "1"
            || environment["MACWIN_ACTIVATE_WINE_APP"] == "1"
            || environment["MACWIN_FORCE_MOUSE_FOCUS"] == "1"
            || lowercasedExecutable.contains("musescore")
        else {
            return
        }
        guard URL(fileURLWithPath: request.engine.winePath).lastPathComponent == "wine" else {
            return
        }

        var titleTokens = ["MuseScore", "入门", "Get Started", "Welcome"]
        titleTokens.append(contentsOf: Self.windowTitleTokens(forExecutable: request.exe))
        let automatedUIClicks = environment["MACWIN_AUTOMATED_UI_CLICK_REPAIR"] == "1"
        let clickContentProbe = automatedUIClicks
            && environment["MACWIN_MOUSE_FOCUS_CLICK_AUTOMATION"] == "1"
            && environment["MACWIN_FORCE_MOUSE_FOCUS"] == "1"
        let clickWelcomeButton = automatedUIClicks
            && (environment["MACWIN_MUSESCORE_WELCOME_CLICK_AUTOMATION"] == "1"
                || environment["MACWIN_MUSESCORE_WELCOME_REPAIR"] == "1"
                || lowercasedExecutable.contains("musescore"))
        let script: String
        if clickContentProbe || clickWelcomeButton {
            script = """
        set targetProcessNames to {"wine", "wine-preloader", "wine64-preloader", "MuseScore4", "MuseScore4.exe", "MuseScore Studio"}
        set targetWindowTitleTokens to \(Self.appleScriptStringList(titleTokens))
        set shouldClickContentProbe to \(clickContentProbe ? "true" : "false")
        set shouldClickWelcomeButton to \(clickWelcomeButton ? "true" : "false")
        set welcomeWindowTitleTokens to {"入门", "Get Started", "Welcome", "MuseScore Studio"}
        set welcomeContentTokens to {"欢迎使用", "MuseScore Studio", "选择主题", "高对比度", "浅色", "深色", "下一步", "Next"}
        set welcomeButtonTokens to {"下一步", "下一页", "Next", "继续", "Continue", "Keep going", "完成", "Finish", "开始", "Start", "跳过", "Skip", "关闭", "Close", "知道了", "Got it", "Done"}

        on elementTextMatches(uiElement, tokenList)
            try
                set elementName to name of uiElement as text
                repeat with tokenValue in tokenList
                    if elementName contains (tokenValue as text) then return true
                end repeat
            end try
            try
                set elementDescription to description of uiElement as text
                repeat with tokenValue in tokenList
                    if elementDescription contains (tokenValue as text) then return true
                end repeat
            end try
            try
                set elementValue to value of uiElement as text
                repeat with tokenValue in tokenList
                    if elementValue contains (tokenValue as text) then return true
                end repeat
            end try
            return false
        end elementTextMatches

        on windowContentMatches(windowElement, tokenList)
            try
                if my elementTextMatches(windowElement, tokenList) then return true
            end try
            try
                repeat with uiElement in entire contents of windowElement
                    if my elementTextMatches(uiElement, tokenList) then return true
                end repeat
            end try
            return false
        end windowContentMatches

        on clickWelcomeCandidates(windowPosition, windowSize)
            set windowX to item 1 of windowPosition
            set windowY to item 2 of windowPosition
            set windowWidth to item 1 of windowSize
            set windowHeight to item 2 of windowSize
            set candidatePoints to {{windowX + windowWidth - 220, windowY + windowHeight - 58}, {windowX + windowWidth - 130, windowY + windowHeight - 58}, {windowX + (windowWidth * 0.82), windowY + (windowHeight * 0.925)}, {windowX + (windowWidth * 0.76), windowY + (windowHeight * 0.925)}, {windowX + (windowWidth * 0.5), windowY + (windowHeight * 0.92)}}
            repeat with candidatePoint in candidatePoints
                try
                    click at (contents of candidatePoint)
                    delay 0.08
                end try
            end repeat
        end clickWelcomeCandidates

        repeat with attemptIndex from 1 to 40
            delay 0.25
            with timeout of 1 second
                tell application "System Events"
                    repeat with p in every process
                        try
                            set processName to name of p as text
                            set processMatches to false
                            repeat with targetName in targetProcessNames
                                if processName is (targetName as text) then set processMatches to true
                                if processName contains (targetName as text) then set processMatches to true
                            end repeat

                            if (count of windows of p) > 0 then
                                repeat with w in windows of p
                                    set windowMatches to processMatches
                                    try
                                        set windowName to name of w as text
                                        repeat with titleToken in targetWindowTitleTokens
                                            if windowName contains (titleToken as text) then set windowMatches to true
                                        end repeat
                                    end try

                                    if windowMatches is true then
                                        set frontmost of p to true
                                        try
                                            perform action "AXRaise" of w
                                        end try
                                        try
                                            set windowPosition to position of w
                                            set windowSize to size of w
                                            set windowLooksLikeWelcome to false
                                            try
                                                set windowName to name of w as text
                                                repeat with welcomeTitleToken in welcomeWindowTitleTokens
                                                    if windowName contains (welcomeTitleToken as text) then set windowLooksLikeWelcome to true
                                                end repeat
                                            end try
                                            if windowLooksLikeWelcome is false then
                                                try
                                                    if my windowContentMatches(w, welcomeContentTokens) then set windowLooksLikeWelcome to true
                                                end try
                                            end if
                                            if shouldClickContentProbe is true or shouldClickWelcomeButton is true then
                                                set clickX to (item 1 of windowPosition) + ((item 1 of windowSize) / 2)
                                                set clickY to (item 2 of windowPosition) + 28
                                                if (item 2 of windowSize) < 80 then set clickY to (item 2 of windowPosition) + ((item 2 of windowSize) / 2)
                                                click at {clickX, clickY}
                                                delay 0.05
                                                set frontmost of p to true
                                            end if
                                            if shouldClickContentProbe is true then
                                                delay 0.08
                                                set probeX to (item 1 of windowPosition) + 24
                                                set probeY to (item 2 of windowPosition) + 64
                                                if (item 1 of windowSize) < 120 then set probeX to (item 1 of windowPosition) + ((item 1 of windowSize) / 2)
                                                if (item 2 of windowSize) < 120 then set probeY to (item 2 of windowPosition) + ((item 2 of windowSize) / 2)
                                                click at {probeX, probeY}
                                                delay 0.05
                                                set centerX to (item 1 of windowPosition) + ((item 1 of windowSize) / 2)
                                                set centerY to (item 2 of windowPosition) + ((item 2 of windowSize) / 2)
                                                click at {centerX, centerY}
                                            end if
                                            if shouldClickWelcomeButton is true and windowLooksLikeWelcome is true then
                                                delay 0.12
                                                try
                                                    repeat with b in buttons of w
                                                        try
                                                            if my elementTextMatches(b, welcomeButtonTokens) then
                                                                click b
                                                            end if
                                                        end try
                                                    end repeat
                                                end try
                                                try
                                                    my clickWelcomeCandidates(windowPosition, windowSize)
                                                end try
                                                delay 0.12
                                                key code 36
                                                delay 0.12
                                                key code 48
                                                delay 0.06
                                                key code 36
                                            end if
                                        end try
                                        if shouldClickWelcomeButton is false or windowLooksLikeWelcome is false then return
                                    end if
                                end repeat
                            end if
                        end try
                    end repeat
                end tell
            end timeout
        end repeat
        """
        } else {
            script = """
        set targetProcessNames to {"wine", "wine-preloader", "wine64-preloader"}
        set targetWindowTitleTokens to \(Self.appleScriptStringList(titleTokens))

        repeat with attemptIndex from 1 to 20
            delay 0.25
            with timeout of 1 second
                tell application "System Events"
                    repeat with p in every process
                        try
                            set processName to name of p as text
                            set processMatches to false
                            repeat with targetName in targetProcessNames
                                if processName is (targetName as text) then set processMatches to true
                                if processName contains (targetName as text) then set processMatches to true
                            end repeat
                            if (count of windows of p) > 0 then
                                repeat with w in windows of p
                                    set windowMatches to processMatches
                                    try
                                        set windowName to name of w as text
                                        repeat with titleToken in targetWindowTitleTokens
                                            if windowName contains (titleToken as text) then set windowMatches to true
                                        end repeat
                                    end try
                                    if windowMatches is true then
                                        set frontmost of p to true
                                        try
                                            perform action "AXRaise" of w
                                        end try
                                        return
                                    end if
                                end repeat
                            end if
                        end try
                    end repeat
                end tell
            end timeout
        end repeat
        """
        }
        // No helper runs from launch/smoke. The exact pending operation is
        // consumed only by the visible user action; parent preflights never gate it.
        // Bind to the original live Process and PID, rather than another Wine app.
        let scopedScript = "set targetPID to \(launchedProcess.processIdentifier)\n" + script.replacingOccurrences(
            of: "repeat with p in every process",
            with: "repeat with p in (every process whose unix id is targetPID)"
        )
        WindowControlPermission.prepare(isCurrent: { launchedProcess.isRunning }) {
            Self.runWindowControlScript(scopedScript)
        }
    }

    private static func runWindowControlScript(_ script: String) {
        let activationProcess = Process()
        activationProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        activationProcess.arguments = ["-e", WindowControlPermission.preservingPermissionErrors(in: script)]
        activationProcess.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        activationProcess.standardError = errorPipe
        // Drain concurrently, so a full stderr pipe cannot hang the helper.
        // Its actual exit/status remains authoritative even after preflight.

        do {
            try activationProcess.run()
            Thread.detachNewThread {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                activationProcess.waitUntilExit()
                guard activationProcess.terminationStatus != 0 else { return }
                let stderr = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let recovery = WindowControlPermission.recovery(for: WindowControlPermission.classify(stderr: stderr))
                WindowControlPermission.report("\(recovery) Wine remains usable manually. Helper exit \(activationProcess.terminationStatus): \(stderr.prefix(1200))")
            }
            Self.scheduleTermination(
                of: activationProcess,
                after: Self.wineApplicationActivationTimeout
            )
        } catch {
            WindowControlPermission.report("Could not start optional window control: \(error.localizedDescription). Select the Wine window manually.")
        }
    }

    static let wineApplicationActivationTimeout: TimeInterval = 12

    static func scheduleTermination(
        of process: Process,
        after timeout: TimeInterval
    ) {
        let processIdentifier = process.processIdentifier
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: max(timeout, 0.01))
            guard process.isRunning,
                  process.processIdentifier == processIdentifier else {
                return
            }
            Darwin.kill(processIdentifier, SIGTERM)
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning,
               process.processIdentifier == processIdentifier {
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }
    }

    private static func isInteractiveWineExecutable(_ lowercasedExecutable: String) -> Bool {
        let normalizedExecutable = lowercasedExecutable.replacingOccurrences(of: "/", with: "\\")
        let executableName = normalizedExecutable
            .split(separator: "\\")
            .last
            .map(String.init) ?? normalizedExecutable
        let executableStem = executableName.hasSuffix(".exe")
            ? String(executableName.dropLast(4))
            : executableName
        if ["reg", "regedit", "wineboot", "wineserver"].contains(executableStem) {
            return false
        }

        let nonInteractiveTokens = [
            "\\reg.exe",
            "/reg.exe",
            "\\regedit.exe",
            "/regedit.exe",
            "\\wineboot.exe",
            "/wineboot.exe",
            "wineserver"
        ]
        return !nonInteractiveTokens.contains { lowercasedExecutable.contains($0) }
    }

    private static func windowTitleTokens(forExecutable executable: String) -> [String] {
        let fileName = executable
            .split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .last
            .map(String.init) ?? executable
        let withoutExtension = fileName.lowercased().hasSuffix(".exe")
            ? String(fileName.dropLast(4))
            : fileName
        let cleaned = withoutExtension
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens: [String] = []
        for candidate in [withoutExtension, cleaned] where candidate.count >= 3 {
            tokens.append(candidate)
        }
        return Array(Set(tokens)).sorted()
    }

    private static func appleScriptStringList(_ values: [String]) -> String {
        let escaped = values
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { value in
                "\"" + value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
        return "{\(escaped.joined(separator: ", "))}"
    }

    @discardableResult
    public func terminateBottle(
        bottle: BottleManifest,
        engine: EngineManifest,
        logName: String? = nil
    ) throws -> WineRunResult {
        try ensureRuntimeAvailable(for: engine)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let request = WineRunRequest(
            exe: engine.wineserverPath,
            args: ["-k"],
            bottle: bottle,
            engine: engine,
            logName: logName ?? "\(bottle.id)-wineserver-kill.log"
        )
        let logURL = makeLogURL(logName: request.logName, bottleId: bottle.id, exe: "wineserver-kill")
        let startedAt = Date()
        let launchRecordURL = try makeLaunchRecordURL(logURL: logURL, startedAt: startedAt)
        let commandLine = ["/usr/bin/arch", "-x86_64", engine.wineserverPath, "-k"]
        let environment = mergedEnvironment(engine: engine, bottle: bottle)
        let workingDirectory = try workingDirectory(for: request)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", engine.wineserverPath, "-k"]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            try? Self.saveLaunchRecord(
                Self.launchRecord(
                    id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                    request: request,
                    mode: .foregroundRun,
                    state: .failedToLaunch,
                    logURL: logURL,
                    commandLine: commandLine,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    startedAt: startedAt,
                    endedAt: Date(),
                    errorMessage: error.localizedDescription
                ),
                to: launchRecordURL
            )
            throw MacWinError.processLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let endedAt = Date()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        var logData = Self.logHeader(
            request: request,
            commandLine: commandLine,
            environment: environment,
            workingDirectory: workingDirectory,
            startedAt: startedAt,
            detached: false
        )
        logData.append(data)
        logData.append(Self.logFooter(exitCode: process.terminationStatus, endedAt: endedAt))
        try logData.write(to: logURL, options: [.atomic])
        try Self.saveLaunchRecord(
            Self.launchRecord(
                id: launchRecordURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
                request: request,
                mode: .foregroundRun,
                state: .completed,
                logURL: logURL,
                commandLine: commandLine,
                environment: environment,
                workingDirectory: workingDirectory,
                startedAt: startedAt,
                endedAt: endedAt,
                exitCode: process.terminationStatus
            ),
            to: launchRecordURL
        )
        let output = String(data: data, encoding: .utf8) ?? ""
        let result = WineRunResult(
            exitCode: process.terminationStatus,
            logURL: logURL,
            commandLine: commandLine,
            output: output
        )
        if process.terminationStatus != 0 {
            throw MacWinError.processFailed(
                command: commandLine.joined(separator: " "),
                exitCode: process.terminationStatus,
                logPath: logURL.path
            )
        }
        return result
    }

    private func makeLogURL(logName: String?, bottleId: String, exe: String) -> URL {
        let safeExe = exe.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        let name = logName ?? "\(bottleId)-\(safeExe)-\(Self.timestamp()).log"
        return paths.logsDirectory.appendingPathComponent(name)
    }

    private func makeLaunchRecordURL(logURL: URL, startedAt: Date) throws -> URL {
        let directory = LaunchHistoryService.recordsDirectory(in: paths.logsDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = Self.safeFileName(logURL.deletingPathExtension().lastPathComponent)
        let name = "\(Self.timestamp(startedAt))-\(baseName)-\(UUID().uuidString.prefix(8).lowercased()).launch.json"
        return directory.appendingPathComponent(name)
    }

    private func workingDirectory(for request: WineRunRequest) throws -> URL {
        if let workingDirectory = request.workingDirectory {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            return workingDirectory
        }

        if request.envOverrides["MACWIN_LAUNCH_CWD"] == "versioned-chromium-dir",
           let directory = chromiumVersionWorkingDirectory(for: request) {
            return directory
        }

        if request.envOverrides["MACWIN_LAUNCH_CWD"] == "executable-dir",
           let directory = executableWorkingDirectory(for: request) {
            return directory
        }

        let driveC = paths.bottleDriveCURL(id: request.bottle.id)
        if fileManager.fileExists(atPath: driveC.path) {
            return driveC
        }

        let bottleRoot = paths.bottleDirectory(id: request.bottle.id)
        try fileManager.createDirectory(at: bottleRoot, withIntermediateDirectories: true)
        return bottleRoot
    }

    private func applyRuntimeCompatibilityRepairs(
        for request: WineRunRequest,
        environment: [String: String]
    ) throws {
        let lowercasedExecutable = request.exe.lowercased()
        let requiresMuseScoreRepair = lowercasedExecutable.contains("musescore")
        let requiresLTspiceRepair = lowercasedExecutable.contains("ltspice")
        let requiresAppModeInputRepair = environment["MACWIN_APP_MODE_INPUT_REPAIR"] != "0"
            && environment["MACWIN_MANAGED_LAUNCH"] == "1"
            && Self.isInteractiveWineExecutable(lowercasedExecutable)
        if environment["MACWIN_FORCE_MOUSE_FOCUS"] == "1"
            || requiresMuseScoreRepair
            || requiresAppModeInputRepair {
            terminateVirtualDesktopContainersIfNeeded(for: request, environment: environment)
            try applyMacDriverInputRepair(for: request, environment: environment)
        }

        if requiresMuseScoreRepair {
            try applyMuseScoreFirstLaunchRepair(for: request, environment: environment)
        }

        if requiresLTspiceRepair {
            try applyLTspiceFirstLaunchRepair(for: request)
        }

        if environment["MACWIN_COM_PROXY_REPAIR"] == "1" {
            applyCOMProxyRegistryRepair(for: request, environment: environment)
        }

        if environment["MACWIN_DOTNET_DESKTOP10_RUNTIME_REPAIR"] == "1" {
            try deployDotNetDesktop10RuntimeIfCached(for: request)
        }

        if environment["MACWIN_DXVK_MACOS_REPAIR"] == "1" {
            try deployDXVKMacOSIfAvailable(for: request, environment: environment)
        }

        if environment["MACWIN_MESHLAB_SOFTWARE_OPENGL_REPAIR"] == "1" {
            try deployMeshLabSoftwareOpenGL(for: request)
        }

        if environment["MACWIN_BAMBU_STUDIO_RUNTIME_REPAIR"] == "1" {
            try deployBambuStudioRuntime(for: request)
        }

        if environment["MACWIN_BLENDER_SOFTWARE_OPENGL_REPAIR"] == "1" {
            try deployBlenderSoftwareOpenGL(for: request)
        }

        if environment["MACWIN_ORCASLICER_RUNTIME_REPAIR"] == "1" {
            try deployOrcaSlicerRuntime(for: request)
        }

        if environment["MACWIN_WPS_OFFICE_REPAIR"] == "1" {
            try deployWPSOfficeRuntimeCoverage(for: request)
        }

        if environment["MACWIN_ONLYOFFICE_RENDERER_FONT_REPAIR"] == "1"
            || lowercasedExecutable.contains("onlyoffice")
            || lowercasedExecutable.contains("desktopeditors") {
            try applyOnlyOfficeRendererFontRepair(for: request)
        }

        if environment["MACWIN_MREMOTENG_REPAIR"] == "1" {
            try applyMRemoteNG1782Repair(for: request, environment: environment)
        }

        if environment["MACWIN_NPACKD_CATALOG_REPAIR"] == "1"
            || lowercasedExecutable.contains("npackdg.exe") {
            try deployNpackdCatalogSeedIfCached(for: request)
        }

        if environment["MACWIN_CURA_PROFILE_REPAIR"] == "1"
            || lowercasedExecutable.contains("ultimaker-cura.exe") {
            try applyCuraProfileRepair(for: request)
        }

        if environment["MACWIN_JABREF_JAVAFX_REPAIR"] == "1"
            || lowercasedExecutable.hasSuffix("\\jabref.exe") {
            try applyJabRefJavaFXRepair(for: request)
        }

        if environment["MACWIN_FREECAD_PYTHON_REPAIR"] == "1"
            || lowercasedExecutable.hasSuffix("\\freecad.exe")
            || lowercasedExecutable.hasSuffix("\\freecadcmd.exe") {
            try applyFreeCADPythonRepair(for: request)
        }

        if environment["MACWIN_LIBRECAD_PROFILE_REPAIR"] == "1"
            || lowercasedExecutable.hasSuffix("\\librecad.exe") {
            applyLibreCADProfileRepair(for: request, environment: environment)
        }

        if environment["MACWIN_OPENSCAD_SOFTWARE_OPENGL_REPAIR"] == "1"
            || lowercasedExecutable.hasSuffix("\\openscad.exe") {
            try deployOpenSCADSoftwareOpenGL(for: request)
        }

        if environment["MACWIN_SWEETHOME3D_OPENGL_REPAIR"] == "1"
            || lowercasedExecutable.hasSuffix("\\sweethome3d.exe") {
            try applySweetHome3DOpenGLRepair(for: request)
        }

        if environment["MACWIN_JASP_STARTUP_REPAIR"] == "1"
            || lowercasedExecutable.contains("\\program files\\jasp\\jaspdesktop.exe") {
            try applyJASPStartupRepair(for: request)
        }

        if environment["MACWIN_ZOTERO_GECKO32_REPAIR"] == "1" {
            try applyZoteroGecko32Repair(for: request)
        } else if environment["MACWIN_GECKO_PROFILE_REPAIR"] == "1" {
            try applyGeckoBrowserRepair(for: request)
        }
    }

    private func deployWPSOfficeRuntimeCoverage(for request: WineRunRequest) throws {
        let driveC = paths.bottleDriveCURL(id: request.bottle.id)
        let sources = EngineRuntimeCoverage.wpsOfficeFltlibSources(for: request.engine)
        var deployments = [
            (sources[0], driveC.appendingPathComponent("windows/system32/fltlib.dll")),
        ]
        if request.engine.supportsWin32, sources.count > 1 {
            deployments.append((sources[1], driveC.appendingPathComponent("windows/syswow64/fltlib.dll")))
        }

        for (source, destination) in deployments {
            guard fileManager.fileExists(atPath: source.path) else {
                throw MacWinError.missingFile(source.path)
            }
            let sourceData = try Data(contentsOf: source)
            if fileManager.fileExists(atPath: destination.path),
               try Data(contentsOf: destination) == sourceData {
                continue
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try sourceData.write(to: destination, options: .atomic)
        }
    }

    private func deployNpackdCatalogSeedIfCached(for request: WineRunRequest) throws {
        let cacheDirectory = paths.downloadsDirectory
            .appendingPathComponent("NpackdRepository", isDirectory: true)
        let seed = cacheDirectory.appendingPathComponent("Data.db")
        guard fileManager.fileExists(atPath: seed.path) else { return }

        let expectedHashURL = cacheDirectory.appendingPathComponent("Data.db.sha256")
        let expectedHash: String
        if let sidecar = try? String(contentsOf: expectedHashURL, encoding: .utf8),
           let firstToken = sidecar.split(whereSeparator: { $0.isWhitespace }).first {
            expectedHash = firstToken.lowercased()
        } else {
            expectedHash = "23c53b9aadf67ee4795ffcc5d6834f7c8bf23d4829b73dffbb3d7004b6379997"
        }
        let actualHash = try Hashing.sha256Hex(file: seed)
        guard expectedHash.count == 64, actualHash == expectedHash else {
            throw MacWinError.catalogHashMismatch(
                recipeId: "npackd-catalog-seed",
                expected: expectedHash,
                actual: actualHash
            )
        }

        let destinationDirectory = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("ProgramData/Npackd", isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent("Data.db")
        let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let destinationSize = (destinationAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        if destinationSize < 10 * 1_024 * 1_024 {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let temporary = destinationDirectory.appendingPathComponent(
                ".Data.db.macwin-\(UUID().uuidString)"
            )
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: seed, to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        }

        let repositoryCache = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("macwin-runtime/npackd", isDirectory: true)
        try fileManager.createDirectory(at: repositoryCache, withIntermediateDirectories: true)
        for fileName in ["stable.zip", "stable64.zip"] {
            let source = cacheDirectory.appendingPathComponent(fileName)
            let target = repositoryCache.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try copyFileIfChanged(from: source, to: target)
        }
    }

    private func applyCuraProfileRepair(for request: WineRunRequest) throws {
        let disabledPlugins = [
            "3DConnexion",
            "3MFReader",
            "3MFWriter",
            "CuraDrive",
            "DigitalLibrary",
            "FirmwareUpdateChecker",
            "FirmwareUpdater",
            "Marketplace",
            "SentryLogger",
            "UM3NetworkPrinting",
            "USBPrinting",
            "UpdateChecker"
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "disabled": disabledPlugins,
                "to_install": [:],
                "to_remove": []
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        for userDirectory in wineUserDirectories(for: request.bottle) {
            let profileDirectory = userDirectory
                .appendingPathComponent("AppData/Roaming/cura/5.13", isDirectory: true)
            try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            for staleName in [".startup-incomplete", "startupCache", "cache2"] {
                let staleURL = profileDirectory.appendingPathComponent(staleName)
                if fileManager.fileExists(atPath: staleURL.path) {
                    try? fileManager.removeItem(at: staleURL)
                }
            }
            let pluginsURL = profileDirectory.appendingPathComponent("plugins.json")
            if (try? Data(contentsOf: pluginsURL)) != payload {
                try payload.write(to: pluginsURL, options: .atomic)
            }
        }
    }

    private func applyJASPStartupRepair(for request: WineRunRequest) throws {
        let jaspIsRunning = hostProcessLines().contains { process in
            let command = process.command.lowercased()
            return command.contains("jaspdesktop.exe") || command.contains("jaspengine.exe")
        }
        guard !jaspIsRunning else { return }

        for userDirectory in wineUserDirectories(for: request.bottle) {
            let settingsDirectory = userDirectory
                .appendingPathComponent("AppData/Roaming/JASP", isDirectory: true)
            try fileManager.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
            let settingsURL = settingsDirectory.appendingPathComponent("JASP.ini")
            let original = fileManager.fileExists(atPath: settingsURL.path)
                ? ((try? String(contentsOf: settingsURL, encoding: .utf8)) ?? "")
                : ""
            let repaired = Self.jaspStartupConfigText(original)
            if repaired != original {
                try repaired.write(to: settingsURL, atomically: true, encoding: .utf8)
            }

            let ipcDirectory = userDirectory
                .appendingPathComponent("AppData/Local/JASP/JASP/temp", isDirectory: true)
            try removeJASPIPCFiles(in: ipcDirectory)
        }

        let boostIPCDirectory = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("ProgramData/boost_interprocess/01000000", isDirectory: true)
        try removeJASPIPCFiles(in: boostIPCDirectory)

        guard let targetURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let cacheURL = paths.downloadsDirectory
            .appendingPathComponent("CompatibilityPatches/JASP/0.97.1", isDirectory: true)
            .appendingPathComponent("JASPDesktop.exe")
        _ = try Self.deployCachedExecutablePatch(
            fileManager: fileManager,
            cacheURL: cacheURL,
            targetURL: targetURL,
            expectedPatchHash: Self.jaspManagedPatchHash,
            allowedTargetHashes: Self.jaspManagedPatchSourceHashes
        )
    }

    private func applyJabRefJavaFXRepair(for request: WineRunRequest) throws {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let runtimeLibrary = executableURL.deletingLastPathComponent()
            .appendingPathComponent("runtime/lib", isDirectory: true)
        guard fileManager.fileExists(atPath: runtimeLibrary.path) else { return }

        let sourceConfiguration = runtimeLibrary.appendingPathComponent("fontconfig.properties.src")
        let targetConfiguration = runtimeLibrary.appendingPathComponent("fontconfig.properties")
        try copyFileIfChanged(from: sourceConfiguration, to: targetConfiguration)

        let windowsFonts = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("windows/Fonts", isDirectory: true)
        for (sourceName, targetName) in [
            ("ARIAL.TTF", "fontsLucidaSansRegular.ttf"),
            ("ARIALBD.TTF", "fontsLucidaSansDemiBold.ttf"),
            ("ARIALI.TTF", "fontsLucidaSansRegularItalic.ttf")
        ] {
            try copyFileIfChanged(
                from: windowsFonts.appendingPathComponent(sourceName),
                to: runtimeLibrary.appendingPathComponent(targetName)
            )
        }

        let binaryFontCache = runtimeLibrary.appendingPathComponent("fontconfig.bfc")
        if fileManager.fileExists(atPath: binaryFontCache.path) {
            try fileManager.removeItem(at: binaryFontCache)
        }
    }

    private func applyFreeCADPythonRepair(for request: WineRunRequest) throws {
        let driveC = paths.bottleDriveCURL(id: request.bottle.id)
        guard fileManager.fileExists(atPath: driveC.path),
              let enumerator = fileManager.enumerator(
                at: driveC,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let normalizedPath = item.path.replacingOccurrences(of: "\\", with: "/").lowercased()
            if normalizedPath.contains("/windows/") || normalizedPath.contains("/appdata/") {
                enumerator.skipDescendants()
                continue
            }
            guard item.lastPathComponent == "Lib",
                  normalizedPath.contains("/freecad"),
                  fileManager.fileExists(atPath: item.appendingPathComponent("platform.py").path) else {
                continue
            }

            let destination = item.appendingPathComponent("sitecustomize.py")
            if (try? String(contentsOf: destination, encoding: .utf8))
                != BottleService.freeCADPythonUnameShimText {
                try BottleService.freeCADPythonUnameShimText.write(
                    to: destination,
                    atomically: true,
                    encoding: .utf8
                )
            }
            enumerator.skipDescendants()
        }
    }

    private func applyOnlyOfficeRendererFontRepair(
        for request: WineRunRequest,
        waitForSource: Bool = false
    ) throws {
        try Self.applyOnlyOfficeRendererFontRepair(
            paths: paths,
            bottle: request.bottle,
            waitForSource: waitForSource
        )
    }

    private static func applyOnlyOfficeRendererFontRepair(
        paths: MacWinPaths,
        bottle: BottleManifest,
        waitForSource: Bool = false
    ) throws {
        let fileManager = FileManager.default
        let driveC = paths.bottleDriveCURL(id: bottle.id)
        let applicationDirectories = [
            driveC.appendingPathComponent(
                "Program Files/ONLYOFFICE/DesktopEditors",
                isDirectory: true
            ),
            driveC.appendingPathComponent(
                "Program Files (x86)/ONLYOFFICE/DesktopEditors",
                isDirectory: true
            )
        ]
        let usersDirectory = driveC.appendingPathComponent("users", isDirectory: true)
        var userDirectories = (try? fileManager.contentsOfDirectory(
            at: usersDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return false }
            let name = url.lastPathComponent.lowercased()
            return name != "public" && name != "default"
        }) ?? []
        if userDirectories.isEmpty {
            let userName = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
            userDirectories = [usersDirectory.appendingPathComponent(userName, isDirectory: true)]
        }

        let sourceCandidates = userDirectories.map {
            $0.appendingPathComponent(
                "AppData/Local/ONLYOFFICE/DesktopEditors/data/fonts/AllFonts.js"
            )
        }
        let maximumAttempts = waitForSource ? 41 : 1
        var source: URL?
        for attempt in 0..<maximumAttempts {
            source = sourceCandidates.first { sourceURL in
                guard fileManager.fileExists(atPath: sourceURL.path),
                      let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
                      let size = attributes[.size] as? NSNumber
                else {
                    return false
                }
                return size.intValue > 0
            }
            if source != nil || attempt == maximumAttempts - 1 {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let source else { return }

        for applicationDirectory in applicationDirectories {
            let targetDirectory = applicationDirectory.appendingPathComponent(
                "editors/sdkjs/common",
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: targetDirectory.path) else { continue }
            let destination = targetDirectory.appendingPathComponent("AllFonts.js")
            let sourceData = try Data(contentsOf: source)
            if fileManager.fileExists(atPath: destination.path),
               (try? Data(contentsOf: destination)) == sourceData {
                continue
            }
            try sourceData.write(to: destination, options: .atomic)
        }
    }

    private func copyFileIfChanged(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        let sourceData = try Data(contentsOf: source)
        if fileManager.fileExists(atPath: destination.path),
           (try? Data(contentsOf: destination)) == sourceData {
            return
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sourceData.write(to: destination, options: .atomic)
    }

    private func removeJASPIPCFiles(in directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries where entry.lastPathComponent.hasPrefix("JASP-IPC-") {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            try fileManager.removeItem(at: entry)
        }
    }

    @discardableResult
    static func deployCachedExecutablePatch(
        fileManager: FileManager,
        cacheURL: URL,
        targetURL: URL,
        expectedPatchHash: String,
        allowedTargetHashes: Set<String>
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: cacheURL.path),
              fileManager.fileExists(atPath: targetURL.path) else {
            return false
        }

        let normalizedPatchHash = expectedPatchHash.lowercased()
        let patchHash = try Hashing.sha256Hex(file: cacheURL)
        guard normalizedPatchHash.count == 64, patchHash == normalizedPatchHash else {
            return false
        }

        let targetHash = try Hashing.sha256Hex(file: targetURL)
        if targetHash == normalizedPatchHash {
            return false
        }
        let normalizedAllowedHashes = Set(allowedTargetHashes.map { $0.lowercased() })
        guard normalizedAllowedHashes.contains(targetHash) else {
            return false
        }

        let backupURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(targetURL.lastPathComponent).macwin-original-\(targetHash.prefix(8))")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.copyItem(at: targetURL, to: backupURL)
        }

        let temporaryURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).macwin-patch-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: cacheURL, to: temporaryURL)
        _ = try fileManager.replaceItemAt(
            targetURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
        return try Hashing.sha256Hex(file: targetURL) == normalizedPatchHash
    }

    private func deployMeshLabSoftwareOpenGL(for request: WineRunRequest) throws {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let applicationDirectory = executableURL.deletingLastPathComponent()
        let source = applicationDirectory.appendingPathComponent("opengl32sw.dll")
        let target = applicationDirectory.appendingPathComponent("opengl32.dll")
        guard fileManager.fileExists(atPath: source.path) else {
            throw MacWinError.missingFile(source.path)
        }
        if fileManager.fileExists(atPath: target.path),
           try Data(contentsOf: source) == Data(contentsOf: target) {
            return
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    private func deployOpenSCADSoftwareOpenGL(for request: WineRunRequest) throws {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let applicationDirectory = executableURL.deletingLastPathComponent()
        let cachedMesa = paths.downloadsDirectory
            .appendingPathComponent(".bambu-studio-runtime/mesa/opengl32.dll")
        guard fileManager.fileExists(atPath: cachedMesa.path) else {
            throw MacWinError.missingFile(cachedMesa.path)
        }
        try deployRuntimeFile(
            from: cachedMesa,
            to: applicationDirectory.appendingPathComponent("opengl32.dll")
        )
    }

    private func deployBlenderSoftwareOpenGL(for request: WineRunRequest) throws {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let applicationDirectory = executableURL.deletingLastPathComponent()
        let mesaDirectory = paths.downloadsDirectory
            .appendingPathComponent(".mesa3d-26.1.2-msvc/x64", isDirectory: true)
        let requiredRuntimeNames = [
            "opengl32.dll",
            "libgallium_wgl.dll"
        ]
        for runtimeName in requiredRuntimeNames {
            let source = mesaDirectory.appendingPathComponent(runtimeName)
            guard fileManager.fileExists(atPath: source.path) else {
                throw MacWinError.missingFile(source.path)
            }
            try deployRuntimeFile(
                from: source,
                to: applicationDirectory.appendingPathComponent(runtimeName)
            )
        }

        let optionalDXIL = mesaDirectory.appendingPathComponent("dxil.dll")
        if fileManager.fileExists(atPath: optionalDXIL.path) {
            try deployRuntimeFile(
                from: optionalDXIL,
                to: applicationDirectory.appendingPathComponent("dxil.dll")
            )
        }
    }

    private func applySweetHome3DOpenGLRepair(for request: WineRunRequest) throws {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let runtimeLibrary = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("runtime/lib", isDirectory: true)
        let bundledExtensions = runtimeLibrary.appendingPathComponent("ext", isDirectory: true)
        let disabledExtensions = runtimeLibrary.appendingPathComponent(
            "ext.macwin-disabled",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: bundledExtensions.path),
           !fileManager.fileExists(atPath: disabledExtensions.path) {
            try fileManager.moveItem(at: bundledExtensions, to: disabledExtensions)
        }

        let windowsFonts = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("windows/Fonts", isDirectory: true)
        let fontCandidates = ["SIMSUN.TTC", "MSYH.TTC", "SIMHEI.TTF"]
            .map { windowsFonts.appendingPathComponent($0) }
        guard let fontURL = fontCandidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }),
        let fontFaces = Self.javaCJKFontFaces(at: fontURL) else {
            return
        }

        let sourceConfiguration = runtimeLibrary.appendingPathComponent("fontconfig.properties.src")
        let targetConfiguration = runtimeLibrary.appendingPathComponent("fontconfig.properties")
        guard fileManager.fileExists(atPath: sourceConfiguration.path) else { return }
        let sourceText = try String(contentsOf: sourceConfiguration, encoding: .utf8)
        let repairedText = Self.javaCJKFontConfigurationText(
            sourceText,
            regularFontName: fontFaces.regular,
            boldFontName: fontFaces.bold,
            fontFileName: fontURL.lastPathComponent
        )
        let currentText = try? String(contentsOf: targetConfiguration, encoding: .utf8)
        if currentText != repairedText {
            try repairedText.write(to: targetConfiguration, atomically: true, encoding: .utf8)
        }

        let binaryFontCache = runtimeLibrary.appendingPathComponent("fontconfig.bfc")
        if fileManager.fileExists(atPath: binaryFontCache.path) {
            try fileManager.removeItem(at: binaryFontCache)
        }
    }

    private func deployBambuStudioRuntime(for request: WineRunRequest) throws {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let applicationDirectory = executableURL.deletingLastPathComponent()
        let bundledMesa = applicationDirectory.appendingPathComponent("mesa/opengl32.dll")
        let cachedMesa = paths.downloadsDirectory
            .appendingPathComponent(".bambu-studio-runtime/mesa/opengl32.dll")
        let mesaSource = [bundledMesa, cachedMesa].first {
            fileManager.fileExists(atPath: $0.path)
        }
        guard let mesaSource else {
            throw MacWinError.missingFile(bundledMesa.path)
        }

        try deployRuntimeFile(
            from: mesaSource,
            to: applicationDirectory.appendingPathComponent("opengl32.dll")
        )
        try deployRuntimeFile(
            from: mesaSource,
            to: bundledMesa
        )

        let runtimeDirectory = paths.downloadsDirectory
            .appendingPathComponent("vc_redist.x64.vs17.runtime-amd64", isDirectory: true)
        let runtimeNames = [
            "concrt140.dll",
            "msvcp140.dll",
            "msvcp140_1.dll",
            "msvcp140_2.dll",
            "msvcp140_atomic_wait.dll",
            "msvcp140_codecvt_ids.dll",
            "vcruntime140.dll",
            "vcruntime140_1.dll"
        ]
        for runtimeName in runtimeNames {
            let source = runtimeDirectory.appendingPathComponent("\(runtimeName)_amd64")
            guard fileManager.fileExists(atPath: source.path) else {
                throw MacWinError.missingFile(source.path)
            }
            try deployRuntimeFile(
                from: source,
                to: applicationDirectory.appendingPathComponent(runtimeName)
            )
        }
        try deployBambuStudioExport3MFPatch(in: applicationDirectory)
    }

    static let bambuStudioOriginalDLLHash =
        "656977de78fcea084790014c984ea5ace0b60debdd5dd234d727b887f4cfe5ae"
    static let bambuStudioPatchedDLLHash =
        "0ab1a0ec541fccd30d834451f316ace96e774c5c811c4eef098c4c8ce12335c2"
    static let bambuStudioExport3MFPatchOffset = 0x152eb0d
    static let bambuStudioExport3MFOriginalBytes: [UInt8] =
        [0x49, 0x8b, 0xc0, 0xc3] + Array(repeating: 0xcc, count: 13)
    static let bambuStudioExport3MFPatchBytes: [UInt8] = [
        0x4d, 0x85, 0xc0, 0x75, 0x08,
        0x48, 0x8d, 0x05, 0xe7, 0x98, 0xaf, 0x04,
        0xc3, 0x4c, 0x89, 0xc0, 0xc3
    ]

    @discardableResult
    static func applyBambuStudioExport3MFPatch(to data: inout Data) -> Bool {
        let start = bambuStudioExport3MFPatchOffset
        let end = start + bambuStudioExport3MFOriginalBytes.count
        guard end <= data.count else { return false }
        let range = start..<end
        guard Array(data[range]) == bambuStudioExport3MFOriginalBytes else { return false }
        data.replaceSubrange(range, with: bambuStudioExport3MFPatchBytes)
        return true
    }

    private func deployBambuStudioExport3MFPatch(in applicationDirectory: URL) throws {
        let target = applicationDirectory.appendingPathComponent("BambuStudio.dll")
        guard fileManager.fileExists(atPath: target.path) else { return }
        let currentHash = try Hashing.sha256Hex(file: target)
        if currentHash == Self.bambuStudioPatchedDLLHash {
            return
        }
        guard currentHash == Self.bambuStudioOriginalDLLHash else {
            return
        }

        var data = try Data(contentsOf: target)
        guard Self.applyBambuStudioExport3MFPatch(to: &data),
              Hashing.sha256Hex(data: data) == Self.bambuStudioPatchedDLLHash else {
            throw MacWinError.invalidManifest(
                "Bambu Studio export-3mf patch did not match its verified source bytes"
            )
        }

        let backup = applicationDirectory.appendingPathComponent(
            "BambuStudio.dll.macwin-original-\(Self.bambuStudioOriginalDLLHash.prefix(8))"
        )
        if !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: target, to: backup)
        }
        try data.write(to: target, options: .atomic)
    }

    static let orcaSlicerOriginalDLLHash =
        "fcd3bbdff6fa82674bcef773fcb049dcbf52acd3a69ad65b0ba57cd80ec72c6f"
    static let orcaSlicerPatchedDLLHash =
        "0d647a9894da841814dcd6e2c8f81d79158568cefc94fd2d14be6543850e08cb"
    static let orcaSlicerStartupPatches: [(offset: Int, original: [UInt8], replacement: [UInt8])] = [
        (0x29695f6, [0x0f, 0x85], [0x90, 0xe9]),
        (0x29b3872, [0x0f, 0x85], [0x90, 0xe9]),
        (0x299ba10, [0x48, 0x89, 0x5c], [0x31, 0xc0, 0xc3])
    ]

    @discardableResult
    static func applyOrcaSlicerStartupPatch(to data: inout Data) -> Bool {
        for patch in orcaSlicerStartupPatches {
            let end = patch.offset + patch.original.count
            guard end <= data.count,
                  Array(data[patch.offset..<end]) == patch.original,
                  patch.original.count == patch.replacement.count else {
                return false
            }
        }
        for patch in orcaSlicerStartupPatches {
            data.replaceSubrange(
                patch.offset..<(patch.offset + patch.original.count),
                with: patch.replacement
            )
        }
        return true
    }

    private func deployOrcaSlicerRuntime(for request: WineRunRequest) throws {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return }
        let applicationDirectory = executableURL.deletingLastPathComponent()
        try deployOrcaSlicerStartupPatch(in: applicationDirectory)
        try applyOrcaSlicerUpdatePromptRepair(for: request)
    }

    private func deployOrcaSlicerStartupPatch(in applicationDirectory: URL) throws {
        let target = applicationDirectory.appendingPathComponent("OrcaSlicer.dll")
        guard fileManager.fileExists(atPath: target.path) else { return }
        let currentHash = try Hashing.sha256Hex(file: target)
        if currentHash == Self.orcaSlicerPatchedDLLHash {
            return
        }
        guard currentHash == Self.orcaSlicerOriginalDLLHash else {
            return
        }

        var data = try Data(contentsOf: target)
        guard Self.applyOrcaSlicerStartupPatch(to: &data),
              Hashing.sha256Hex(data: data) == Self.orcaSlicerPatchedDLLHash else {
            throw MacWinError.invalidManifest(
                "OrcaSlicer startup patch did not match its verified source bytes"
            )
        }

        let backup = applicationDirectory.appendingPathComponent(
            "OrcaSlicer.dll.macwin-original-\(Self.orcaSlicerOriginalDLLHash.prefix(8))"
        )
        if !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: target, to: backup)
        }
        try data.write(to: target, options: .atomic)
    }

    private func applyOrcaSlicerUpdatePromptRepair(for request: WineRunRequest) throws {
        let bottleDirectory = paths.bottleDirectory(id: request.bottle.id)
        let usersDirectory = bottleDirectory.appendingPathComponent("drive_c/users", isDirectory: true)
        let userName = wineUserName(in: usersDirectory)
        let configURL = usersDirectory
            .appendingPathComponent(userName, isDirectory: true)
            .appendingPathComponent("AppData/Roaming/OrcaSlicer/OrcaSlicer.conf")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let jsonEnd = data.lastIndex(of: UInt8(ascii: "}")) {
            let jsonData = data.prefix(through: jsonEnd)
            if let decoded = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                root = decoded
            }
        }
        var app = root["app"] as? [String: Any] ?? [:]
        if app["skip_version"] as? String == "999.999.999" {
            return
        }
        app["skip_version"] = "999.999.999"
        app["preset_bundle_auto_update"] = false
        root["app"] = app
        if root["header"] == nil {
            root["header"] = "OrcaSlicer 2.4.0"
        }

        let json = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var output = json
        output.append(UInt8(ascii: "\n"))
        try output.write(to: configURL, options: .atomic)
    }

    private func wineUserName(in usersDirectory: URL) -> String {
        if let names = try? fileManager.contentsOfDirectory(atPath: usersDirectory.path),
           let name = names.first(where: { $0 != "Public" && $0 != "Default" && $0 != "default" }) {
            return name
        }
        return processEnvironmentProvider()["USER"] ?? NSUserName()
    }

    private func deployRuntimeFile(from source: URL, to destination: URL) throws {
        let sourceData = try Data(contentsOf: source)
        if fileManager.fileExists(atPath: destination.path),
           try Data(contentsOf: destination) == sourceData {
            return
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try sourceData.write(to: destination, options: .atomic)
    }

    private func applyMacDriverInputRepair(for request: WineRunRequest, environment: [String: String]) throws {
        let bottle = request.bottle
        let userRegistry = paths.bottleDirectory(id: bottle.id).appendingPathComponent("user.reg")
        try fileManager.createDirectory(at: userRegistry.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: String
        if fileManager.fileExists(atPath: userRegistry.path) {
            original = try String(contentsOf: userRegistry, encoding: .utf8)
        } else {
            original = "WINE REGISTRY Version 2\n\n"
        }
        let borderlessAppMode = environment["MACWIN_BORDERLESS_APP_MODE"] == "1"
            && environment["MACWIN_CLICK_THROUGH_REPAIR"] != "1"
        let retinaInputRepair = environment["MACWIN_RETINA_INPUT_REPAIR"] == "1"
        let wineFontDPI = retinaInputRepair ? BottleService.retinaWineDPI : BottleService.standardWineDPI
        let repaired = BottleService.registryTextWithMacDriverInputRepairs(
            original,
            borderlessAppMode: borderlessAppMode,
            retinaMode: retinaInputRepair
        )
        let marker = runtimeRepairMarkerURL(
            bottle: bottle,
            name: "mac-driver-input-\(borderlessAppMode ? "borderless" : "decorated")-\(retinaInputRepair ? "retina" : "standard")-\(wineFontDPI)-v2"
        )
        if fileManager.fileExists(atPath: marker.path), repaired == original {
            return
        }
        if repaired != original {
            try repaired.write(to: userRegistry, atomically: true, encoding: .utf8)
        } else {
            try markRuntimeRepairComplete(marker)
            return
        }

        for (registryPath, name, value) in [
            (#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "Managed", "Y"),
            (#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "Decorated", borderlessAppMode ? "N" : "Y"),
            (#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "UseTakeFocus", "Y"),
            (#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "GrabFullscreen", "N"),
            (#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "WindowsFloatWhenInactive", "all"),
            (#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "RetinaMode", retinaInputRepair ? "Y" : "N"),
            (#"HKEY_CURRENT_USER\Software\Wine\DirectInput"#, "MouseWarpOverride", "disable"),
            (#"HKEY_CURRENT_USER\Software\Wine\X11 Driver"#, "Managed", "Y"),
            (#"HKEY_CURRENT_USER\Software\Wine\X11 Driver"#, "Decorated", borderlessAppMode ? "N" : "Y"),
            (#"HKEY_CURRENT_USER\Software\Wine\X11 Driver"#, "UseTakeFocus", "Y"),
            (#"HKEY_CURRENT_USER\Software\Wine\X11 Driver"#, "GrabFullscreen", "N")
        ] {
            runWineRegistryStringUpdate(
                request: request,
                environment: environment,
                registryPath: registryPath,
                name: name,
                value: value
            )
        }
        runWineRegistryDWORDUpdate(
            request: request,
            environment: environment,
            registryPath: #"HKEY_CURRENT_USER\Software\Wine\Fonts"#,
            name: BottleService.wineFontsLogPixelsValue,
            value: wineFontDPI
        )
        try markRuntimeRepairComplete(marker)
    }

    private func applyCOMProxyRegistryRepair(for request: WineRunRequest, environment: [String: String]) {
        func setDefault(_ key: String, _ value: String) {
            runWineRegistryDefaultStringUpdate(request: request, environment: environment, registryPath: key, value: value)
        }
        func setString(_ key: String, _ name: String, _ value: String) {
            runWineRegistryStringUpdate(request: request, environment: environment, registryPath: key, name: name, value: value)
        }
        func setDWORD(_ key: String, _ name: String, _ value: UInt32) {
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: key, name: name, value: value)
        }
        func registerProxyInterface(name: String, iid: String, clsid: String, methods: String) {
            let key = #"HKEY_CLASSES_ROOT\Interface\"# + iid
            let wowKey = #"HKEY_CLASSES_ROOT\Wow6432Node\Interface\"# + iid
            for interfaceKey in [key, wowKey] {
                setDefault(interfaceKey, name)
                setString(interfaceKey, "ProxyStubClsid32", clsid)
                setString(interfaceKey, "NumMethods", methods)
                setDefault(interfaceKey + #"\ProxyStubClsid32"#, clsid)
                setDefault(interfaceKey + #"\NumMethods"#, methods)
            }
        }
        func registerInprocCLSID(clsid: String, name: String, systemDLL: String, wowDLL: String) {
            let key = #"HKEY_CLASSES_ROOT\CLSID\"# + clsid
            let inprocKey = key + #"\InprocServer32"#
            let wowKey = #"HKEY_CLASSES_ROOT\Wow6432Node\CLSID\"# + clsid
            let wowInprocKey = wowKey + #"\InprocServer32"#
            setDefault(key, name)
            setDefault(inprocKey, systemDLL)
            setString(inprocKey, "ThreadingModel", "Both")
            setDefault(wowKey, name)
            setDefault(wowInprocKey, wowDLL)
            setString(wowInprocKey, "ThreadingModel", "Both")
        }
        func registerDOMDocument(clsid: String, progId: String, systemDLL: String, wowDLL: String) {
            let key = #"HKEY_CLASSES_ROOT\CLSID\"# + clsid
            let inprocKey = key + #"\InprocServer32"#
            let progIdKey = key + #"\ProgID"#
            let wowKey = #"HKEY_CLASSES_ROOT\Wow6432Node\CLSID\"# + clsid
            let wowInprocKey = wowKey + #"\InprocServer32"#
            let wowProgIdKey = wowKey + #"\ProgID"#
            setDefault(key, progId)
            setDefault(inprocKey, systemDLL)
            setString(inprocKey, "ThreadingModel", "Both")
            setDefault(progIdKey, progId)
            setDefault(#"HKEY_CLASSES_ROOT\"# + progId + #"\CLSID"#, clsid)
            setDefault(wowKey, progId)
            setDefault(wowInprocKey, wowDLL)
            setString(wowInprocKey, "ThreadingModel", "Both")
            setDefault(wowProgIdKey, progId)
            setDefault(#"HKEY_CLASSES_ROOT\Wow6432Node\"# + progId + #"\CLSID"#, clsid)
        }

        registerProxyInterface(
            name: "IServiceProvider",
            iid: "{6D5140C1-7436-11CE-8034-00AA006009FA}",
            clsid: "{B8DA6310-E19B-11D0-933C-00A0C90DCAA9}",
            methods: "4"
        )
        registerInprocCLSID(
            clsid: "{B8DA6310-E19B-11D0-933C-00A0C90DCAA9}",
            name: "PSFactoryBuffer",
            systemDLL: #"C:\windows\system32\actxprxy.dll"#,
            wowDLL: #"C:\windows\syswow64\actxprxy.dll"#
        )
        registerProxyInterface(
            name: "IDropTarget",
            iid: "{00000122-0000-0000-C000-000000000046}",
            clsid: "{00000320-0000-0000-C000-000000000046}",
            methods: "7"
        )
        registerInprocCLSID(
            clsid: "{00000320-0000-0000-C000-000000000046}",
            name: "OLE32 PSFactoryBuffer",
            systemDLL: #"C:\windows\system32\ole32.dll"#,
            wowDLL: #"C:\windows\syswow64\ole32.dll"#
        )
        for proxy in [
            ("IRemUnknown", "{00000131-0000-0000-C000-000000000046}", "6"),
            ("IRemUnknown2", "{00000142-0000-0000-C000-000000000046}", "7"),
            ("IRemUnknownN", "{0000013C-0000-0000-C000-000000000046}", "12"),
            ("IRundown", "{00000134-0000-0000-C000-000000000046}", "13")
        ] {
            registerProxyInterface(name: proxy.0, iid: proxy.1, clsid: "{00000320-0000-0000-C000-000000000046}", methods: proxy.2)
        }
        registerInprocCLSID(
            clsid: "{BCDE0395-E52F-467C-8E3D-C4579291692E}",
            name: "MMDeviceEnumerator class",
            systemDLL: #"C:\windows\system32\mmdevapi.dll"#,
            wowDLL: #"C:\windows\syswow64\mmdevapi.dll"#
        )
        registerInprocCLSID(
            clsid: "{0F87369F-A4E5-4CFC-BD3E-73E6154572DD}",
            name: "TaskScheduler class",
            systemDLL: #"C:\windows\system32\taskschd.dll"#,
            wowDLL: #"C:\windows\syswow64\taskschd.dll"#
        )
        registerInprocCLSID(
            clsid: "{148BD52A-A2AB-11CE-B11F-00AA00530503}",
            name: "CTaskScheduler class",
            systemDLL: #"C:\windows\system32\mstask.dll"#,
            wowDLL: #"C:\windows\syswow64\mstask.dll"#
        )
        registerDOMDocument(
            clsid: "{F5078F32-C551-11D3-89B9-0000F81FE221}",
            progId: "Msxml2.DOMDocument.3.0",
            systemDLL: #"C:\windows\system32\msxml3.dll"#,
            wowDLL: #"C:\windows\syswow64\msxml3.dll"#
        )
        registerDOMDocument(
            clsid: "{88D96A05-F192-11D4-A65F-0040963251E5}",
            progId: "Msxml2.DOMDocument.6.0",
            systemDLL: #"C:\windows\system32\msxml3.dll"#,
            wowDLL: #"C:\windows\syswow64\msxml3.dll"#
        )

        let scheduleKey = #"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Schedule"#
        let scheduleParametersKey = scheduleKey + #"\Parameters"#
        setDWORD(scheduleKey, "Type", 32)
        setDWORD(scheduleKey, "Start", 2)
        setDWORD(scheduleKey, "ErrorControl", 1)
        setString(scheduleKey, "ImagePath", #"C:\windows\system32\svchost.exe -k netsvcs"#)
        setString(scheduleKey, "DisplayName", "Task Scheduler")
        setString(scheduleKey, "ObjectName", "LocalSystem")
        setString(scheduleParametersKey, "ServiceDll", #"C:\windows\system32\schedsvc.dll"#)
    }

    private func applyLibreCADProfileRepair(for request: WineRunRequest, environment: [String: String]) {
        let root = #"HKEY_CURRENT_USER\Software\LibreCAD\LibreCAD"#
        for (key, name, value) in [
            (root + #"\Appearance"#, "Language", "zh_CN"),
            (root + #"\Appearance"#, "LanguageCmd", "zh_CN"),
            (root + #"\Defaults"#, "Unit", "Millimeter")
        ] {
            runWineRegistryStringUpdate(
                request: request,
                environment: environment,
                registryPath: key,
                name: name,
                value: value
            )
        }
        for (key, name, value) in [
            (root + #"\Defaults"#, "UseQtFileOpenDialog", UInt32(0)),
            (root + #"\Startup"#, "FirstLoad", UInt32(0)),
            (root + #"\Startup"#, "Maximize", UInt32(1))
        ] {
            runWineRegistryDWORDUpdate(
                request: request,
                environment: environment,
                registryPath: key,
                name: name,
                value: value
            )
        }
    }

    private func deployDotNetDesktop10RuntimeIfCached(for request: WineRunRequest) throws {
        let destination = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("macwin-runtimes/dotnet-desktop-10-x64", isDirectory: true)
        let coreMarker = destination
            .appendingPathComponent("shared/Microsoft.NETCore.App/10.0.9/Microsoft.NETCore.App.deps.json")
        let desktopMarker = destination
            .appendingPathComponent("shared/Microsoft.WindowsDesktop.App/10.0.9/Microsoft.WindowsDesktop.App.deps.json")
        if fileManager.fileExists(atPath: destination.appendingPathComponent("dotnet.exe").path),
           fileManager.fileExists(atPath: coreMarker.path),
           fileManager.fileExists(atPath: desktopMarker.path) {
            return
        }

        let runtimeZip = paths.downloadsDirectory.appendingPathComponent("dotnet-runtime-10.0.9-win-x64.zip")
        let desktopZip = paths.downloadsDirectory.appendingPathComponent("windowsdesktop-runtime-10.0.9-win-x64.zip")
        guard fileManager.fileExists(atPath: runtimeZip.path),
              fileManager.fileExists(atPath: desktopZip.path) else {
            return
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try unzipArchive(runtimeZip, to: destination)
        try unzipArchive(desktopZip, to: destination)
    }

    private func deployDXVKMacOSIfAvailable(
        for request: WineRunRequest,
        environment: [String: String]
    ) throws {
        guard let sourceDirectory = dxvkMacOSSourceDirectory(for: request, environment: environment) else {
            return
        }
        let system32 = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("windows/system32", isDirectory: true)
        try fileManager.createDirectory(at: system32, withIntermediateDirectories: true)
        let backup = system32.appendingPathComponent(".macwin-wined3d-backup", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)

        for fileName in Self.dxvkMacOSDLLNames {
            let source = sourceDirectory.appendingPathComponent(fileName)
            let destination = system32.appendingPathComponent(fileName)
            let original = backup.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destination.path),
               !fileManager.fileExists(atPath: original.path) {
                try fileManager.copyItem(at: destination, to: original)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }

        let marker = paths.bottleDirectory(id: request.bottle.id)
            .appendingPathComponent(".macwin-dxvk-macos-source")
        try sourceDirectory.path.write(to: marker, atomically: true, encoding: .utf8)
    }

    func dxvkMacOSSourceDirectory(
        for request: WineRunRequest,
        environment: [String: String]
    ) -> URL? {
        var candidates: [URL] = []
        if let configuredPath = environment["MACWIN_DXVK_MACOS_DIR"], !configuredPath.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredPath, isDirectory: true))
        }
        candidates.append(
            paths.enginesDirectory
                .appendingPathComponent("dxvk-macos", isDirectory: true)
                .appendingPathComponent("x64", isDirectory: true)
        )

        let wineURL = URL(fileURLWithPath: request.engine.winePath)
        let refsDirectory = wineURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(
            refsDirectory
                .appendingPathComponent("dxvk-macos-full-build/install/x64", isDirectory: true)
        )

        return candidates.first { directory in
            Self.dxvkMacOSDLLNames.allSatisfy {
                fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        }
    }

    private func unzipArchive(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", archive.path, "-d", destination.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        _ = try? pipe.fileHandleForReading.readToEnd()
        if process.terminationStatus != 0 {
            throw MacWinError.processFailed(
                command: "/usr/bin/unzip -q \(archive.path) -d \(destination.path)",
                exitCode: process.terminationStatus,
                logPath: archive.path
            )
        }
    }

    private func applyMRemoteNG1782Repair(for request: WineRunRequest, environment: [String: String]) throws {
        if let executableURL = executableURL(for: request.exe, in: request.bottle) {
            let appDirectory = executableURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: appDirectory.path) {
                try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
                try removeGeneratedMRemoteNG1782Settings(in: appDirectory)
            }
        }

        for (registryPath, name, value) in [
            (#"HKEY_LOCAL_MACHINE\SOFTWARE\mRemoteNG\Updates"#, "AllowCheckForUpdates", UInt32(0)),
            (#"HKEY_LOCAL_MACHINE\SOFTWARE\mRemoteNG\Updates"#, "AllowCheckForUpdatesAutomatical", UInt32(0)),
            (#"HKEY_LOCAL_MACHINE\SOFTWARE\mRemoteNG\Updates"#, "AllowCheckForUpdatesManual", UInt32(0)),
            (#"HKEY_LOCAL_MACHINE\SOFTWARE\mRemoteNG\Updates\Options"#, "DisallowPromptForUpdatesPreference", UInt32(1)),
            (#"HKEY_LOCAL_MACHINE\SOFTWARE\mRemoteNG\Updates\Options"#, "CheckForUpdatesFrequencyDays", UInt32(36500)),
            (#"HKEY_LOCAL_MACHINE\SOFTWARE\mRemoteNG\Updates\Options"#, "UseProxyForUpdates", UInt32(0))
        ] {
            runWineRegistryDWORDUpdate(
                request: request,
                environment: environment,
                registryPath: registryPath,
                name: name,
                value: value
            )
        }
    }

    private func removeGeneratedMRemoteNG1782Settings(in appDirectory: URL) throws {
        let settingsURL = appDirectory.appendingPathComponent("mRemoteNG.settings")
        guard fileManager.fileExists(atPath: settingsURL.path),
              let text = try? String(contentsOf: settingsURL, encoding: .utf8) else {
            return
        }
        let generatedMarkers = [
            #"CheckForUpdatesLastCheck">2099-01-01"#,
            #"UpdateProxyAddress"></setting>"#,
            "<globalSettings />"
        ]
        guard generatedMarkers.allSatisfy({ text.contains($0) }) else { return }
        try fileManager.removeItem(at: settingsURL)
    }

    private func terminateVirtualDesktopContainersIfNeeded(for request: WineRunRequest, environment: [String: String]) {
        guard environment["MACWIN_KEEP_VIRTUAL_DESKTOPS"] != "1" else { return }
        let lowercasedExecutable = request.exe.lowercased()
        guard Self.isInteractiveWineExecutable(lowercasedExecutable),
              !lowercasedExecutable.contains("explorer.exe") else {
            return
        }
        guard URL(fileURLWithPath: request.engine.winePath).lastPathComponent == "wine" else {
            return
        }

        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        ps.standardOutput = pipe
        ps.standardError = nil
        let completed = DispatchSemaphore(value: 0)
        ps.terminationHandler = { _ in
            completed.signal()
        }
        do {
            try ps.run()
        } catch {
            return
        }
        if !Self.waitForSignal(completed, timeoutSeconds: 2) {
            kill(ps.processIdentifier, SIGKILL)
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let processList = String(data: data, encoding: .utf8) else { return }
        let currentProcessIdentifier = Int32(ProcessInfo.processInfo.processIdentifier)
        for line in processList.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            let pidText = trimmed[..<separator]
            let command = trimmed[separator...].trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedCommand = command.lowercased()
            guard let pid = Int32(pidText),
                  pid > 1,
                  pid != currentProcessIdentifier,
                  lowercasedCommand.contains("explorer.exe"),
                  lowercasedCommand.contains("/desktop") else {
                continue
            }
            kill(pid, SIGTERM)
        }
    }

    private func applyMuseScoreFirstLaunchRepair(for request: WineRunRequest, environment: [String: String]) throws {
        let bottle = request.bottle
        let marker = runtimeRepairMarkerURL(bottle: bottle, name: "musescore-first-launch-v2")
        var changed = false
        for userDirectory in wineUserDirectories(for: bottle) {
            for configURL in Self.museScoreConfigURLs(for: userDirectory) {
                try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let original = fileManager.fileExists(atPath: configURL.path)
                    ? (try String(contentsOf: configURL, encoding: .utf8))
                    : ""
                let repaired = Self.museScoreFirstLaunchConfigText(original)
                if repaired != original {
                    try repaired.write(to: configURL, atomically: true, encoding: .utf8)
                    changed = true
                }
            }
        }

        let userRegistry = paths.bottleDirectory(id: bottle.id).appendingPathComponent("user.reg")
        try fileManager.createDirectory(at: userRegistry.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalRegistry = fileManager.fileExists(atPath: userRegistry.path)
            ? (try String(contentsOf: userRegistry, encoding: .utf8))
            : "WINE REGISTRY Version 2\n\n"
        let repairedRegistry = BottleService.registryTextWithMuseScoreFirstLaunchRepairs(originalRegistry)
        if repairedRegistry != originalRegistry {
            try repairedRegistry.write(to: userRegistry, atomically: true, encoding: .utf8)
            changed = true
        }

        if fileManager.fileExists(atPath: marker.path) {
            return
        }
        if !changed {
            try markRuntimeRepairComplete(marker)
            return
        }

        for root in BottleService.museScoreSettingsRegistryRoots {
            let registryRoot = "HKEY_CURRENT_USER\\" + root.replacingOccurrences(of: "\\\\", with: "\\")
            let applicationPath = registryRoot + "\\application"
            let startupPath = applicationPath + "\\startup"
            let uiApplicationPath = registryRoot + "\\ui\\application"
            let uiStartupPath = uiApplicationPath + "\\startup"
            let uiThemePath = registryRoot + "\\ui\\theme"

            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: applicationPath, name: "hasCompletedFirstLaunchSetup", value: 1)
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: applicationPath, name: "welcomeDialogShowOnStartup", value: 0)
            runWineRegistryStringUpdate(request: request, environment: environment, registryPath: applicationPath, name: "welcomeDialogLastShownVersion", value: "999.999.999")
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: applicationPath, name: "welcomeDialogLastShownIndex", value: 999)
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: startupPath, name: "modeStart", value: 0)
            runWineRegistryStringUpdate(request: request, environment: environment, registryPath: startupPath, name: "startScore", value: "")
            runWineRegistryStringUpdate(request: request, environment: environment, registryPath: uiApplicationPath, name: "currentThemeCode", value: "light")
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: uiApplicationPath, name: "followSystemTheme", value: 0)
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: uiApplicationPath, name: "highContrastEnabled", value: 0)
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: uiApplicationPath, name: "currentAccentColorIndex", value: 4)
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: uiStartupPath, name: "showSplashScreen", value: 0)
            runWineRegistryStringUpdate(request: request, environment: environment, registryPath: uiThemePath, name: "fontFamily", value: "Arial")
            runWineRegistryDWORDUpdate(request: request, environment: environment, registryPath: uiThemePath, name: "fontSize", value: 12)
        }
        try markRuntimeRepairComplete(marker)
    }

    private func applyLTspiceFirstLaunchRepair(for request: WineRunRequest) throws {
        let marker = runtimeRepairMarkerURL(bottle: request.bottle, name: "ltspice-first-launch-v1")
        var changed = false

        for userDirectory in wineUserDirectories(for: request.bottle) {
            let configURL = userDirectory.appendingPathComponent("AppData/Roaming/LTspice.ini")
            try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let originalData = fileManager.fileExists(atPath: configURL.path)
                ? try Data(contentsOf: configURL)
                : Data()
            let originalText = Self.ltspiceConfigText(from: originalData)
            let repairedText = Self.ltspiceFirstLaunchConfigText(originalText)
            let repairedData = Self.ltspiceConfigData(from: repairedText)

            if originalData != repairedData {
                try repairedData.write(to: configURL, options: [.atomic])
                changed = true
            }
        }

        if !fileManager.fileExists(atPath: marker.path) || changed {
            try markRuntimeRepairComplete(marker)
        }
    }

    private func runtimeRepairMarkerURL(bottle: BottleManifest, name: String) -> URL {
        paths.bottleDirectory(id: bottle.id)
            .appendingPathComponent(".macwin", isDirectory: true)
            .appendingPathComponent("repair-state", isDirectory: true)
            .appendingPathComponent("\(Self.safeFileName(name)).done")
    }

    private func markRuntimeRepairComplete(_ marker: URL) throws {
        try fileManager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "completedAt=\(ISO8601DateFormatter().string(from: Date()))\n"
        try text.write(to: marker, atomically: true, encoding: .utf8)
    }

    private func applyZoteroGecko32Repair(for request: WineRunRequest) throws {
        let profileDirectory = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("macwin-portable/zotero-profile", isDirectory: true)
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        for staleName in [".startup-incomplete", "startupCache", "cache2"] {
            let staleURL = profileDirectory.appendingPathComponent(staleName)
            if fileManager.fileExists(atPath: staleURL.path) {
                try? fileManager.removeItem(at: staleURL)
            }
        }

        let userJSURL = profileDirectory.appendingPathComponent("user.js")
        let original = fileManager.fileExists(atPath: userJSURL.path)
            ? ((try? String(contentsOf: userJSURL, encoding: .utf8)) ?? "")
            : ""
        if original != Self.zoteroGecko32UserJS {
            try Self.zoteroGecko32UserJS.write(to: userJSURL, atomically: true, encoding: .utf8)
        }
    }

    private func applyGeckoBrowserRepair(for request: WineRunRequest) throws {
        let profileDirectory = paths.bottleDriveCURL(id: request.bottle.id)
            .appendingPathComponent("macwin-portable/firefox-profile", isDirectory: true)
        try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        for staleName in [".startup-incomplete", "startupCache", "cache2", "shader-cache"] {
            let staleURL = profileDirectory.appendingPathComponent(staleName)
            if fileManager.fileExists(atPath: staleURL.path) {
                try? fileManager.removeItem(at: staleURL)
            }
        }

        let userJSURL = profileDirectory.appendingPathComponent("user.js")
        let original = fileManager.fileExists(atPath: userJSURL.path)
            ? ((try? String(contentsOf: userJSURL, encoding: .utf8)) ?? "")
            : ""
        if original != Self.geckoBrowserUserJS {
            try Self.geckoBrowserUserJS.write(to: userJSURL, atomically: true, encoding: .utf8)
        }
    }

    private static func museScoreConfigURLs(for userDirectory: URL) -> [URL] {
        let roaming = userDirectory.appendingPathComponent("AppData/Roaming", isDirectory: true)
        let local = userDirectory.appendingPathComponent("AppData/Local", isDirectory: true)
        let localLow = userDirectory.appendingPathComponent("AppData/LocalLow", isDirectory: true)
        let fileNames = [
            "MuseScore4.ini",
            "MuseScore Studio.ini",
            "MuseScore Studio 4.ini",
            "MuseScore Studio 4 stable.ini"
        ]
        let baseDirectories = [
            roaming.appendingPathComponent("MuseScore", isDirectory: true),
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore4", isDirectory: true),
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio", isDirectory: true),
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4", isDirectory: true),
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4 stable", isDirectory: true),
            roaming.appendingPathComponent("MuseScore Studio", isDirectory: true),
            roaming.appendingPathComponent("MuseScore Studio 4", isDirectory: true),
            roaming.appendingPathComponent("MuseScore Studio 4 stable", isDirectory: true),
            roaming.appendingPathComponent("MuseScore 4", isDirectory: true),
            roaming.appendingPathComponent("MuseScore4", isDirectory: true),
            roaming.appendingPathComponent("MuseScoreStudio4", isDirectory: true),
            local.appendingPathComponent("MuseScore", isDirectory: true),
            local.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore4", isDirectory: true),
            local.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio", isDirectory: true),
            local.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4", isDirectory: true),
            local.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4 stable", isDirectory: true),
            local.appendingPathComponent("MuseScore Studio", isDirectory: true),
            local.appendingPathComponent("MuseScore Studio 4", isDirectory: true),
            local.appendingPathComponent("MuseScore Studio 4 stable", isDirectory: true),
            local.appendingPathComponent("MuseScore 4", isDirectory: true),
            local.appendingPathComponent("MuseScore4", isDirectory: true),
            local.appendingPathComponent("MuseScoreStudio4", isDirectory: true),
            localLow.appendingPathComponent("MuseScore", isDirectory: true),
            localLow.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore4", isDirectory: true),
            localLow.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio", isDirectory: true),
            localLow.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4", isDirectory: true),
            localLow.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4 stable", isDirectory: true),
            localLow.appendingPathComponent("MuseScore Studio", isDirectory: true),
            localLow.appendingPathComponent("MuseScore Studio 4", isDirectory: true),
            localLow.appendingPathComponent("MuseScore Studio 4 stable", isDirectory: true),
            localLow.appendingPathComponent("MuseScore 4", isDirectory: true),
            localLow.appendingPathComponent("MuseScore4", isDirectory: true),
            localLow.appendingPathComponent("MuseScoreStudio4", isDirectory: true)
        ]
        var urls: [URL] = []
        for directory in baseDirectories {
            for fileName in fileNames {
                urls.append(directory.appendingPathComponent(fileName))
            }
        }
        return [
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore4.ini"),
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio.ini"),
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4.ini"),
            roaming.appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4 stable.ini"),
            roaming.appendingPathComponent("MuseScore Studio", isDirectory: true)
                .appendingPathComponent("MuseScore Studio.ini"),
            roaming.appendingPathComponent("MuseScore Studio 4", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4.ini"),
            roaming.appendingPathComponent("MuseScore Studio 4 stable", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4 stable.ini"),
            userDirectory.appendingPathComponent("AppData/Local", isDirectory: true)
                .appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore4.ini"),
            userDirectory.appendingPathComponent("AppData/Local", isDirectory: true)
                .appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio.ini"),
            userDirectory.appendingPathComponent("AppData/Local", isDirectory: true)
                .appendingPathComponent("MuseScore", isDirectory: true)
                .appendingPathComponent("MuseScore Studio 4.ini")
        ] + urls
    }

    private func wineUserDirectories(for bottle: BottleManifest) -> [URL] {
        let usersDirectory = paths.bottleDriveCURL(id: bottle.id).appendingPathComponent("users", isDirectory: true)
        var candidates: [URL] = []
        if let existing = try? fileManager.contentsOfDirectory(
            at: usersDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: existing.filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return false }
                let name = url.lastPathComponent.lowercased()
                return name != "public" && name != "default"
            })
        }

        if candidates.isEmpty {
            let userName = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
            candidates.append(usersDirectory.appendingPathComponent(userName, isDirectory: true))
        }
        return candidates
    }

    static func museScoreFirstLaunchConfigText(_ text: String) -> String {
        var repaired = text
        repaired = iniText(repaired, setting: "hasCompletedFirstLaunchSetup", value: "true", inSection: "application")
        repaired = iniText(repaired, setting: "welcomeDialogShowOnStartup", value: "false", inSection: "application")
        repaired = iniText(repaired, setting: "welcomeDialogLastShownVersion", value: "999.999.999", inSection: "application")
        repaired = iniText(repaired, setting: "welcomeDialogLastShownIndex", value: "999", inSection: "application")
        repaired = iniText(repaired, setting: "currentStartupMode", value: "0", inSection: "application")
        repaired = iniText(repaired, setting: "startupScorePath", value: "", inSection: "application")
        repaired = iniText(repaired, setting: "showWelcomeDialog", value: "false", inSection: "application")
        repaired = iniText(repaired, setting: #"startup\modeStart"#, value: "0", inSection: "application")
        repaired = iniText(repaired, setting: #"startup\startScore"#, value: "", inSection: "application")
        repaired = iniText(repaired, setting: "modeStart", value: "0", inSection: "application/startup")
        repaired = iniText(repaired, setting: "startScore", value: "", inSection: "application/startup")
        repaired = iniText(repaired, setting: "hasCompletedFirstLaunchSetup", value: "true", inSection: "appshell/application")
        repaired = iniText(repaired, setting: "welcomeDialogShowOnStartup", value: "false", inSection: "appshell/application")
        repaired = iniText(repaired, setting: "welcomeDialogLastShownVersion", value: "999.999.999", inSection: "appshell/application")
        repaired = iniText(repaired, setting: "welcomeDialogLastShownIndex", value: "999", inSection: "appshell/application")
        repaired = iniText(repaired, setting: "modeStart", value: "0", inSection: "appshell/application/startup")
        repaired = iniText(repaired, setting: "startScore", value: "", inSection: "appshell/application/startup")
        repaired = iniText(repaired, setting: #"application\currentThemeCode"#, value: "light", inSection: "ui")
        repaired = iniText(repaired, setting: #"application\followSystemTheme"#, value: "false", inSection: "ui")
        repaired = iniText(repaired, setting: #"application\highContrastEnabled"#, value: "false", inSection: "ui")
        repaired = iniText(repaired, setting: #"application\currentAccentColorIndex"#, value: "4", inSection: "ui")
        repaired = iniText(repaired, setting: #"application\startup\showSplashScreen"#, value: "false", inSection: "ui")
        repaired = iniText(repaired, setting: "currentThemeCode", value: "light", inSection: "ui/application")
        repaired = iniText(repaired, setting: "followSystemTheme", value: "false", inSection: "ui/application")
        repaired = iniText(repaired, setting: "highContrastEnabled", value: "false", inSection: "ui/application")
        repaired = iniText(repaired, setting: "currentAccentColorIndex", value: "4", inSection: "ui/application")
        repaired = iniText(repaired, setting: "showSplashScreen", value: "false", inSection: "ui/application/startup")
        repaired = iniText(repaired, setting: "currentThemeCode", value: "light", inSection: "appshell/ui/application")
        repaired = iniText(repaired, setting: "followSystemTheme", value: "false", inSection: "appshell/ui/application")
        repaired = iniText(repaired, setting: "highContrastEnabled", value: "false", inSection: "appshell/ui/application")
        repaired = iniText(repaired, setting: "currentAccentColorIndex", value: "4", inSection: "appshell/ui/application")
        repaired = iniText(repaired, setting: "showSplashScreen", value: "false", inSection: "appshell/ui/application/startup")
        repaired = iniText(repaired, setting: #"theme\fontFamily"#, value: "Arial", inSection: "ui")
        repaired = iniText(repaired, setting: #"theme\fontSize"#, value: "12", inSection: "ui")
        repaired = iniText(repaired, setting: "fontFamily", value: "Arial", inSection: "appshell/ui/theme")
        repaired = iniText(repaired, setting: "fontSize", value: "12", inSection: "appshell/ui/theme")
        repaired = iniText(repaired, setting: "lastShownTours", value: "", inSection: "tours")
        repaired = iniText(repaired, setting: "lastShownTours", value: "", inSection: "appshell/tours")
        repaired = iniText(repaired, setting: #"application\hasCompletedFirstLaunchSetup"#, value: "true", inSection: "appshell")
        repaired = iniText(repaired, setting: #"application\welcomeDialogShowOnStartup"#, value: "false", inSection: "appshell")
        repaired = iniText(repaired, setting: #"application\welcomeDialogLastShownVersion"#, value: "999.999.999", inSection: "appshell")
        repaired = iniText(repaired, setting: #"application\welcomeDialogLastShownIndex"#, value: "999", inSection: "appshell")
        repaired = iniText(repaired, setting: #"application\startup\modeStart"#, value: "0", inSection: "appshell")
        repaired = iniText(repaired, setting: #"application\startup\startScore"#, value: "", inSection: "appshell")
        repaired = iniText(repaired, setting: #"ui\application\currentThemeCode"#, value: "light", inSection: "appshell")
        repaired = iniText(repaired, setting: #"ui\application\followSystemTheme"#, value: "false", inSection: "appshell")
        repaired = iniText(repaired, setting: #"ui\application\highContrastEnabled"#, value: "false", inSection: "appshell")
        repaired = iniText(repaired, setting: #"ui\application\currentAccentColorIndex"#, value: "4", inSection: "appshell")
        repaired = iniText(repaired, setting: #"ui\application\startup\showSplashScreen"#, value: "false", inSection: "appshell")
        repaired = iniText(repaired, setting: #"ui\theme\fontFamily"#, value: "Arial", inSection: "appshell")
        repaired = iniText(repaired, setting: #"ui\theme\fontSize"#, value: "12", inSection: "appshell")
        repaired = iniText(repaired, setting: #"tours\lastShownTours"#, value: "", inSection: "appshell")
        repaired = iniText(repaired, setting: "application/hasCompletedFirstLaunchSetup", value: "true", inSection: "General")
        repaired = iniText(repaired, setting: "application/welcomeDialogShowOnStartup", value: "false", inSection: "General")
        repaired = iniText(repaired, setting: "application/welcomeDialogLastShownVersion", value: "999.999.999", inSection: "General")
        repaired = iniText(repaired, setting: "application/welcomeDialogLastShownIndex", value: "999", inSection: "General")
        repaired = iniText(repaired, setting: "application/startup/modeStart", value: "0", inSection: "General")
        repaired = iniText(repaired, setting: "application/startup/startScore", value: "", inSection: "General")
        repaired = iniText(repaired, setting: "ui/application/startup/showSplashScreen", value: "false", inSection: "General")
        repaired = iniText(repaired, setting: "onboarding/finished", value: "true", inSection: "General")
        repaired = iniText(repaired, setting: "onboarding/currentPageIndex", value: "999", inSection: "General")
        repaired = iniText(repaired, setting: "gettingstarted/finished", value: "true", inSection: "General")
        repaired = iniText(repaired, setting: "gettingstarted/currentPageIndex", value: "999", inSection: "General")
        repaired = iniText(repaired, setting: "gettingStarted/finished", value: "true", inSection: "General")
        repaired = iniText(repaired, setting: "gettingStarted/currentPageIndex", value: "999", inSection: "General")
        repaired = iniText(repaired, setting: "finished", value: "true", inSection: "appshell/gettingstarted")
        repaired = iniText(repaired, setting: "currentPageIndex", value: "999", inSection: "appshell/gettingstarted")
        repaired = iniText(repaired, setting: "finished", value: "true", inSection: "appshell/gettingStarted")
        repaired = iniText(repaired, setting: "currentPageIndex", value: "999", inSection: "appshell/gettingStarted")
        repaired = iniText(repaired, setting: "finished", value: "true", inSection: "appshell/onboarding")
        repaired = iniText(repaired, setting: "currentPageIndex", value: "999", inSection: "appshell/onboarding")
        repaired = iniText(repaired, setting: "finished", value: "true", inSection: "gettingstarted")
        repaired = iniText(repaired, setting: "currentPageIndex", value: "999", inSection: "gettingstarted")
        repaired = iniText(repaired, setting: "finished", value: "true", inSection: "gettingStarted")
        repaired = iniText(repaired, setting: "currentPageIndex", value: "999", inSection: "gettingStarted")
        repaired = iniText(repaired, setting: "finished", value: "true", inSection: "onboarding")
        repaired = iniText(repaired, setting: "currentPageIndex", value: "999", inSection: "onboarding")
        return repaired
    }

    static func ltspiceFirstLaunchConfigText(_ text: String) -> String {
        iniText(text, setting: "CaptureAnalytics", value: "false", inSection: "Options")
    }

    private static func ltspiceConfigText(from data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? ""
    }

    private static func ltspiceConfigData(from text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    static func jaspStartupConfigText(_ text: String) -> String {
        var repaired = text
        let settings = [
            ("safeGraphicsMode", "true"),
            ("engineSandbox", "false"),
            ("logToFile", "false"),
            ("checkUpdatesAskUser", "false"),
            ("checkUpdates", "false"),
            ("useConfigurationFile", "false"),
            ("remoteConfiguration", "false"),
            ("remoteConfigurationURL", "about:blank"),
            ("moduleLibraryURL", "about:blank"),
            ("instructionsShown", "true")
        ]
        for (key, value) in settings {
            repaired = iniText(repaired, setting: key, value: value, inSection: "General")
        }
        return repaired
    }

    static func javaCJKFontConfigurationText(
        _ text: String,
        regularFontName: String,
        boldFontName: String,
        fontFileName: String
    ) -> String {
        let regularKeys = [
            "allfonts.chinese-ms936",
            "allfonts.chinese-ms936-extb",
            "allfonts.chinese-gb18030",
            "allfonts.chinese-gb18030-extb",
            "dialog.plain.alphabetic",
            "dialog.italic.alphabetic",
            "dialoginput.plain.alphabetic",
            "dialoginput.italic.alphabetic",
            "sansserif.plain.alphabetic",
            "sansserif.italic.alphabetic"
        ]
        let boldKeys = [
            "dialog.bold.alphabetic",
            "dialog.bolditalic.alphabetic",
            "dialoginput.bold.alphabetic",
            "dialoginput.bolditalic.alphabetic",
            "sansserif.bold.alphabetic",
            "sansserif.bolditalic.alphabetic"
        ]
        var replacements = Dictionary(
            uniqueKeysWithValues: regularKeys.map { ($0, regularFontName) }
        )
        replacements.merge(
            Dictionary(uniqueKeysWithValues: boldKeys.map { ($0, boldFontName) }),
            uniquingKeysWith: { _, replacement in replacement }
        )
        replacements["sequence.allfonts"] =
            "alphabetic/default,chinese-ms936,dingbats,symbol,chinese-ms936-extb"

        let regularFileKey = "filename.\(javaFontConfigurationKey(regularFontName))"
        let boldFileKey = "filename.\(javaFontConfigurationKey(boldFontName))"
        replacements[regularFileKey] = fontFileName
        replacements[boldFileKey] = fontFileName

        var encountered = Set<String>()
        var lines = text.components(separatedBy: .newlines).map { line in
            guard let separator = line.firstIndex(of: "=") else { return line }
            let key = String(line[..<separator])
            guard let replacement = replacements[key] else { return line }
            encountered.insert(key)
            return "\(key)=\(replacement)"
        }
        for key in [regularFileKey, boldFileKey] where !encountered.contains(key) {
            lines.append("\(key)=\(replacements[key]!)")
        }

        while lines.last == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func javaFontConfigurationKey(_ fontName: String) -> String {
        fontName.replacingOccurrences(of: " ", with: "_")
    }

    private static func javaCJKFontFaces(at fontURL: URL) -> (regular: String, bold: String)? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL)
            as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            return nil
        }

        var regularName: String?
        var boldName: String?
        for descriptor in descriptors {
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            let fullName = CTFontCopyFullName(font) as String
            guard !fullName.hasPrefix(".") else { continue }
            if CTFontGetSymbolicTraits(font).contains(.boldTrait) {
                boldName = boldName ?? fullName
            } else {
                regularName = regularName ?? fullName
            }
        }
        guard let regularName = regularName ?? boldName else { return nil }
        return (regularName, boldName ?? regularName)
    }

    static let zoteroGecko32UserJS = """
    user_pref("app.normandy.enabled", false);
    user_pref("app.shield.optoutstudies.enabled", false);
    user_pref("browser.aboutwelcome.enabled", false);
    user_pref("browser.shell.checkDefaultBrowser", false);
    user_pref("browser.startup.homepage", "about:blank");
    user_pref("browser.startup.page", 0);
    user_pref("browser.tabs.remote.autostart", false);
    user_pref("datareporting.healthreport.uploadEnabled", false);
    user_pref("datareporting.policy.dataSubmissionEnabled", false);
    user_pref("dom.ipc.processPrelaunch.enabled", false);
    user_pref("dom.ipc.processCount", 1);
    user_pref("extensions.getAddons.cache.enabled", false);
    user_pref("extensions.update.enabled", false);
    user_pref("gfx.canvas.azure.backends", "skia");
    user_pref("gfx.content.azure.backends", "skia");
    user_pref("gfx.direct2d.disabled", true);
    user_pref("gfx.direct2d.force-enabled", false);
    user_pref("gfx.direct3d11.reuse-decoder-device", false);
    user_pref("gfx.webrender.all", false);
    user_pref("gfx.webrender.compositor", false);
    user_pref("gfx.webrender.compositor.force-enabled", false);
    user_pref("gfx.webrender.enabled", false);
    user_pref("gfx.webrender.force-disabled", true);
    user_pref("gfx.webrender.max-partial-present-rects", 0);
    user_pref("gfx.webrender.software", false);
    user_pref("gfx.webrender.software.d3d11", false);
    user_pref("gfx.webrender.software.force", false);
    user_pref("gfx.webrender.software.opengl", false);
    user_pref("gfx.webrender.software.unaccelerated-widget.force", false);
    user_pref("layers.acceleration.disabled", true);
    user_pref("layers.gpu-process.enabled", false);
    user_pref("layers.offmainthreadcomposition.enabled", false);
    user_pref("media.gmp-manager.updateEnabled", false);
    user_pref("media.gmp-provider.enabled", false);
    user_pref("media.hardware-video-decoding.enabled", false);
    user_pref("media.rdd-process.enabled", false);
    user_pref("network.captive-portal-service.enabled", false);
    user_pref("network.connectivity-service.enabled", false);
    user_pref("network.dns.disableIPv6", true);
    user_pref("network.http.http3.enabled", false);
    user_pref("network.predictor.enabled", false);
    user_pref("network.prefetch-next", false);
    user_pref("network.trr.mode", 5);
    user_pref("security.sandbox.content.level", 0);
    user_pref("security.sandbox.gpu.level", 0);
    user_pref("toolkit.telemetry.enabled", false);
    user_pref("toolkit.telemetry.unified", false);
    user_pref("toolkit.winRegisterApplicationRestart", false);
    """

    static let geckoBrowserUserJS = """
    user_pref("app.normandy.enabled", false);
    user_pref("app.shield.optoutstudies.enabled", false);
    user_pref("browser.aboutwelcome.enabled", false);
    user_pref("browser.shell.checkDefaultBrowser", false);
    user_pref("browser.startup.homepage", "about:blank");
    user_pref("browser.startup.page", 0);
    user_pref("datareporting.healthreport.uploadEnabled", false);
    user_pref("datareporting.policy.dataSubmissionEnabled", false);
    user_pref("dom.ipc.processPrelaunch.enabled", false);
    user_pref("dom.ipc.processCount", 1);
    user_pref("gfx.direct2d.disabled", true);
    user_pref("gfx.direct2d.force-enabled", false);
    user_pref("gfx.webrender.all", false);
    user_pref("gfx.webrender.compositor", false);
    user_pref("gfx.webrender.enabled", false);
    user_pref("gfx.webrender.force-disabled", true);
    user_pref("gfx.webrender.software", false);
    user_pref("gfx.webrender.software.force", false);
    user_pref("layers.acceleration.disabled", true);
    user_pref("layers.gpu-process.enabled", false);
    user_pref("media.gmp-manager.updateEnabled", false);
    user_pref("media.gmp-provider.enabled", false);
    user_pref("media.hardware-video-decoding.enabled", false);
    user_pref("media.rdd-process.enabled", false);
    user_pref("network.captive-portal-service.enabled", false);
    user_pref("network.connectivity-service.enabled", false);
    user_pref("network.dns.disableIPv6", true);
    user_pref("network.http.http3.enabled", false);
    user_pref("network.predictor.enabled", false);
    user_pref("toolkit.telemetry.enabled", false);
    user_pref("toolkit.telemetry.unified", false);
    user_pref("widget.disable-native-theme-for-content", true);
    """

    private static func iniText(
        _ text: String,
        setting key: String,
        value: String,
        inSection section: String
    ) -> String {
        let valueLine = "\(key)=\(value)"
        var output: [String] = []
        var isInTargetSection = false
        var foundTargetSection = false
        var wroteValue = false
        var changed = false

        func finishSectionIfNeeded() {
            if isInTargetSection, !wroteValue {
                output.append(valueLine)
                wroteValue = true
                changed = true
            }
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                finishSectionIfNeeded()
                let start = trimmed.index(after: trimmed.startIndex)
                let end = trimmed.index(before: trimmed.endIndex)
                isInTargetSection = String(trimmed[start..<end]) == section
                if isInTargetSection {
                    foundTargetSection = true
                    wroteValue = false
                }
                output.append(line)
                continue
            }

            if isInTargetSection,
               (trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix("\(key) =")) {
                output.append(valueLine)
                wroteValue = true
                if line != valueLine {
                    changed = true
                }
                continue
            }

            output.append(line)
        }

        finishSectionIfNeeded()

        if !foundTargetSection {
            if output.last?.isEmpty == false {
                output.append("")
            }
            output.append("[\(section)]")
            output.append(valueLine)
            changed = true
        }

        return changed ? output.joined(separator: "\n") : text
    }

    private static func iniText(_ text: String, removingSections removedSections: Set<String>) -> String {
        var output: [String] = []
        var isInRemovedSection = false
        var changed = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                let start = trimmed.index(after: trimmed.startIndex)
                let end = trimmed.index(before: trimmed.endIndex)
                isInRemovedSection = removedSections.contains(String(trimmed[start..<end]))
                if isInRemovedSection {
                    changed = true
                    continue
                }
            }

            if isInRemovedSection {
                changed = true
                continue
            }

            output.append(line)
        }

        return changed ? output.joined(separator: "\n") : text
    }

    private func runWineRegistryStringUpdate(
        request: WineRunRequest,
        environment: [String: String],
        registryPath: String,
        name: String,
        value: String
    ) {
        runWineRegistryUpdate(
            request: request,
            environment: environment,
            arguments: [
                registryPath,
                "/v",
                name,
                "/t",
                "REG_SZ",
                "/d",
                value,
                "/f"
            ]
        )
    }

    private func runWineRegistryDefaultStringUpdate(
        request: WineRunRequest,
        environment: [String: String],
        registryPath: String,
        value: String
    ) {
        runWineRegistryUpdate(
            request: request,
            environment: environment,
            arguments: [
                registryPath,
                "/ve",
                "/d",
                value,
                "/f"
            ]
        )
    }

    private func runWineRegistryDWORDUpdate(
        request: WineRunRequest,
        environment: [String: String],
        registryPath: String,
        name: String,
        value: UInt32
    ) {
        runWineRegistryUpdate(
            request: request,
            environment: environment,
            arguments: [
                registryPath,
                "/v",
                name,
                "/t",
                "REG_DWORD",
                "/d",
                String(value),
                "/f"
            ]
        )
    }

    private func runWineRegistryUpdate(
        request: WineRunRequest,
        environment: [String: String],
        arguments: [String],
        timeoutSeconds: TimeInterval = 5
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", request.engine.winePath, "reg", "add"] + arguments
        process.environment = environment
        process.currentDirectoryURL = paths.bottleDirectory(id: request.bottle.id)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completed.signal()
        }
        do {
            try process.run()
        } catch {
            return
        }

        if !Self.waitForSignal(completed, timeoutSeconds: timeoutSeconds) {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            terminateWineServerForRegistryTimeout(request: request, environment: environment)
        }
    }

    private func terminateRuntimeProcessesStartedAfterLaunch(
        excluding existingProcessIdentifiers: Set<Int32>
    ) -> RuntimeProcessTerminationReport {
        let terminator = RuntimeProcessTerminator()
        var requested = 0
        var stopped: Set<Int32> = []
        var failed: Set<Int32> = []
        var consecutiveEmptyScans = 0
        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            let report = RuntimeProcessAuditService().makeReport()
            let entries = report.entries.filter {
                !existingProcessIdentifiers.contains($0.processIdentifier)
                    && !stopped.contains($0.processIdentifier)
            }
            if entries.isEmpty {
                consecutiveEmptyScans += 1
                if consecutiveEmptyScans >= 2 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            consecutiveEmptyScans = 0
            if !entries.isEmpty {
                let result = terminator.terminate(entries: entries)
                requested += result.requestedCount
                stopped.formUnion(result.stoppedProcessIdentifiers)
                failed.formUnion(result.failedProcessIdentifiers)
            }
            Thread.sleep(forTimeInterval: 0.75)
        }

        return RuntimeProcessTerminationReport(
            requestedCount: requested,
            stoppedProcessIdentifiers: stopped.sorted(),
            failedProcessIdentifiers: failed.sorted()
        )
    }

    private func terminateDetachedRuntimeProcesses(
        inWinePrefix prefixPath: String
    ) -> RuntimeProcessTerminationReport {
        let report = RuntimeProcessAuditService().makeReport()
        return RuntimeProcessTerminator().terminateDetachedWineSystemProcesses(
            in: report,
            winePrefixPath: prefixPath
        )
    }

    private func writeRuntimePreflightCleanupReport(
        _ cleanup: RuntimeProcessTerminationReport,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: Data("runtimePreflightCleanupRequested=\(cleanup.requestedCount)\n".utf8))
        if !cleanup.stoppedProcessIdentifiers.isEmpty {
            try handle.write(contentsOf: Data("runtimePreflightCleanupStopped=\(cleanup.stoppedProcessIdentifiers.map(String.init).joined(separator: ","))\n".utf8))
        }
        if !cleanup.failedProcessIdentifiers.isEmpty {
            try handle.write(contentsOf: Data("runtimePreflightCleanupFailed=\(cleanup.failedProcessIdentifiers.map(String.init).joined(separator: ","))\n".utf8))
        }
    }

    private func writeRuntimeCleanupReport(
        _ cleanup: RuntimeProcessTerminationReport,
        to handle: FileHandle
    ) throws {
        guard cleanup.requestedCount > 0 else { return }
        try handle.write(contentsOf: Data("runtimeCleanupRequested=\(cleanup.requestedCount)\n".utf8))
        try handle.write(contentsOf: Data("runtimeCleanupStopped=\(cleanup.stoppedProcessIdentifiers.map(String.init).joined(separator: ","))\n".utf8))
        if !cleanup.failedProcessIdentifiers.isEmpty {
            try handle.write(contentsOf: Data("runtimeCleanupFailed=\(cleanup.failedProcessIdentifiers.map(String.init).joined(separator: ","))\n".utf8))
        }
    }

    @discardableResult
    private func terminateWineServerForRegistryTimeout(
        request: WineRunRequest,
        environment: [String: String],
        timeoutSeconds: TimeInterval = 5
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", request.engine.wineserverPath, "-k"]
        process.environment = environment
        process.currentDirectoryURL = paths.bottleDirectory(id: request.bottle.id)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completed.signal()
        }
        do {
            try process.run()
        } catch {
            return false
        }
        if !Self.waitForSignal(completed, timeoutSeconds: timeoutSeconds) {
            Darwin.kill(process.processIdentifier, SIGTERM)
            Thread.sleep(forTimeInterval: 0.5)
            if !Self.waitForSignal(completed, timeoutSeconds: 0.5, pollInterval: 0.05) {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            return false
        }
        return process.terminationStatus == 0
    }

    private static func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeoutSeconds: TimeInterval,
        pollInterval: TimeInterval = 0.1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 0))
        let boundedPoll = max(min(pollInterval, 0.25), 0.01)
        repeat {
            if semaphore.wait(timeout: .now()) == .success {
                return true
            }
            Thread.sleep(forTimeInterval: min(boundedPoll, max(deadline.timeIntervalSinceNow, 0)))
        } while Date() < deadline
        return semaphore.wait(timeout: .now()) == .success
    }

    private func chromiumVersionWorkingDirectory(for request: WineRunRequest) -> URL? {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return nil }
        let applicationDirectory = executableURL.deletingLastPathComponent()
        let executableName = executableURL.lastPathComponent.lowercased()
        guard ["brave.exe", "chrome.exe", "msedge.exe", "vivaldi.exe"].contains(executableName) else {
            return nil
        }
        guard fileManager.fileExists(atPath: applicationDirectory.path) else { return nil }
        let versionDirectories = (try? fileManager.contentsOfDirectory(
            at: applicationDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return versionDirectories
            .filter { directory in
                let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return false }
                return BottleService.chromiumRootDLLNames.contains { fileName in
                    fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
                }
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
            }
            .first
    }

    private func executableWorkingDirectory(for request: WineRunRequest) -> URL? {
        guard let executableURL = executableURL(for: request.exe, in: request.bottle) else { return nil }
        let applicationDirectory = executableURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: applicationDirectory.path) else { return nil }
        return applicationDirectory
    }

    private func executableURL(for path: String, in bottle: BottleManifest) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        let lowercased = normalized.lowercased()
        if lowercased.hasPrefix("c:/") {
            let relative = normalized.dropFirst(3)
                .split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/")
            return paths.bottleDriveCURL(id: bottle.id).appendingPathComponent(relative)
        }
        return nil
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "")
    }

    private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let name = String(mapped).split(separator: "-").joined(separator: "-")
        return name.isEmpty ? "launch" : name
    }

    private static func launchRecord(
        id: String,
        request: WineRunRequest,
        mode: WineLaunchMode,
        state: WineLaunchState,
        logURL: URL,
        commandLine: [String],
        environment: [String: String],
        workingDirectory: URL,
        startedAt: Date,
        endedAt: Date? = nil,
        processIdentifier: Int32? = nil,
        exitCode: Int32? = nil,
        errorMessage: String? = nil
    ) -> WineLaunchRecord {
        WineLaunchRecord(
            id: id,
            mode: mode,
            state: state,
            logPath: logURL.path,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: endedAt.map { max(0, Int($0.timeIntervalSince(startedAt) * 1000)) },
            processIdentifier: processIdentifier,
            exitCode: exitCode,
            bottleId: request.bottle.id,
            bottleName: request.bottle.name,
            engineId: request.engine.id,
            winePath: request.engine.winePath,
            exe: request.exe,
            args: request.args,
            commandLine: commandLine,
            workingDirectory: workingDirectory.path,
            environment: selectedEnvironment(from: environment),
            errorMessage: errorMessage
        )
    }

    private static func saveLaunchRecord(
        _ record: WineLaunchRecord,
        to url: URL
    ) throws {
        try JSONStore().save(record, to: url)
    }

    private static func selectedEnvironment(from environment: [String: String]) -> [String: String] {
        var selected: [String: String] = [:]
        for key in loggedEnvironmentKeys {
            if let value = environment[key] {
                selected[key] = value
            }
        }
        return selected
    }

    private static func logHeader(
        request: WineRunRequest,
        commandLine: [String],
        environment: [String: String],
        workingDirectory: URL,
        startedAt: Date,
        detached: Bool
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        let command = commandLine.joined(separator: " ")
        var lines = [
            "----- MacWin launch -----",
            "startedAt=\(formatter.string(from: startedAt))",
            "detached=\(detached)",
            "bottleId=\(request.bottle.id)",
            "bottleName=\(request.bottle.name)",
            "engineId=\(request.engine.id)",
            "exe=\(request.exe)",
            "workingDirectory=\(workingDirectory.path)",
            "command=\(command)"
        ]
        for key in loggedEnvironmentKeys {
            guard let value = environment[key] else { continue }
            lines.append("env.\(key)=\(value)")
        }
        lines.append("-------------------------")
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func logFooter(exitCode: Int32, endedAt: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        return Data("""

        ----- MacWin result -----
        endedAt=\(formatter.string(from: endedAt))
        exitCode=\(exitCode)
        -------------------------

        """.utf8)
    }

    private static let loggedEnvironmentKeys = [
        "_JAVA_OPTIONS",
        "WINEPREFIX",
        "WINEARCH",
        "WINE_D3D_CONFIG",
        "WINEDEBUG",
        "WINEDLLOVERRIDES",
        "WINEDLLPATH",
        "ROSETTA_X87_PATH",
        "GALLIUM_DRIVER",
        "LIBGL_ALWAYS_SOFTWARE",
        "MESA_LOADER_DRIVER_OVERRIDE",
        "MESA_GLSL_VERSION_OVERRIDE",
        "MESA_GL_VERSION_OVERRIDE",
        "CHROME_HEADLESS",
        "CHROMIUM_USER_FLAGS",
        "MACWIN_COMPAT_PROFILE",
        "MACWIN_AUTOMATED_UI_CLICK_REPAIR",
        "MACWIN_CHROMIUM_HELPER_ARGS",
        "MACWIN_COM_PROXY_REPAIR",
        "MACWIN_STEAMWEBHELPER_ARGS",
        "MACWIN_GRAPHICS_PRESET",
        "MACWIN_ACTIVATE_WINE_APP",
        "MACWIN_APP_MODE_INPUT_REPAIR",
        "MACWIN_BORDERLESS_APP_MODE",
        "MACWIN_BAMBU_STUDIO_RUNTIME_REPAIR",
        "MACWIN_BLENDER_SOFTWARE_OPENGL_REPAIR",
        "MACWIN_CLICK_THROUGH_REPAIR",
        "MACWIN_DISABLE_DWM_COMPOSITION",
        "MACWIN_DISABLE_WINE_APP_ACTIVATION",
        "MACWIN_DISABLE_WINE_D3D_CONFIG",
        "MACWIN_FONTCONFIG_REPAIR",
        "MACWIN_FORCE_MOUSE_FOCUS",
        "MACWIN_FORCE_OPAQUE_LAYERED_WINDOWS",
        "MACWIN_RECENTER_OFFSCREEN_WINDOWS",
        "MACWIN_GECKO_PROFILE_REPAIR",
        "MACWIN_HOYOPLAY_TEXT_REPAIR",
        "MACWIN_IPHLPAPI_FORCE_FALLBACK",
        "MACWIN_FREECAD_PYTHON_REPAIR",
        "MACWIN_JABREF_JAVAFX_REPAIR",
        "MACWIN_JASP_QRC_REPAIR",
        "MACWIN_JASP_STARTUP_REPAIR",
        "MACWIN_LENOVO_BLACK_SCREEN_REPAIR",
        "MACWIN_LIBRECAD_PROFILE_REPAIR",
        "MACWIN_OPENSCAD_SOFTWARE_OPENGL_REPAIR",
        "MACWIN_SWEETHOME3D_OPENGL_REPAIR",
        "MACWIN_MESHLAB_SOFTWARE_OPENGL_REPAIR",
        "MACWIN_ONLYOFFICE_RENDERER_FONT_REPAIR",
        "MACWIN_DOTNET_DESKTOP10_RUNTIME_REPAIR",
        "MACWIN_LAUNCH_CWD",
        "MACWIN_MOUSE_FOCUS_CLICK_AUTOMATION",
        "MACWIN_MREMOTENG_REPAIR",
        "MACWIN_MUSESCORE_WELCOME_CLICK_AUTOMATION",
        "MACWIN_MUSESCORE_WELCOME_REPAIR",
        "MACWIN_QTWEBENGINE_REPAIR",
        "MACWIN_RETINA_INPUT_REPAIR",
        "MACWIN_FONT_FALLBACK_REPAIR",
        "MACWIN_SOFTMAKER_OFFICE_REPAIR",
        "MACWIN_TEXSTUDIO_QT6_REPAIR",
        "MACWIN_DIAGNOSTIC_LAUNCH",
        "MACWIN_TEXT_RENDERING_REPAIR",
        "MACWIN_WINHTTP_IGNORE_UNKNOWN_CA",
        "MACWIN_WOW64_BROWSER_REPAIR",
        "MACWIN_ZOTERO_GECKO32_REPAIR",
        "MACWIN_DOCK_POLICY",
        "MACWIN_ALLOW_WINE_MENU_BUILDER",
        "ELECTRON_ENABLE_LOGGING",
        "ELECTRON_FORCE_IS_PACKAGED",
        "FREETYPE_PROPERTIES",
        "LANGUAGE",
        "JAVA_TOOL_OPTIONS",
        "MOZ_ACCELERATED",
        "MOZ_CRASHREPORTER",
        "MOZ_CRASHREPORTER_DISABLE",
        "MOZ_CRASHREPORTER_NO_REPORT",
        "MOZ_DISABLE_CONTENT_SANDBOX",
        "MOZ_DISABLE_GPU_SANDBOX",
        "MOZ_DISABLE_GMP_SANDBOX",
        "MOZ_DISABLE_RDD_SANDBOX",
        "MOZ_DISABLE_SOCKET_PROCESS_SANDBOX",
        "MOZ_WEBRENDER",
        "PANGOCAIRO_BACKEND",
        "QML2_IMPORT_PATH",
        "QTWEBENGINE_DISABLE_SANDBOX",
        "QTWEBENGINE_CHROMIUM_FLAGS",
        "QTWEBENGINE_LOCALES_PATH",
        "QTWEBENGINEPROCESS_PATH",
        "QTWEBENGINE_RESOURCES_PATH",
        "QT_ACCESSIBILITY",
        "QT_AUTO_SCREEN_SCALE_FACTOR",
        "QT_ENABLE_HIGHDPI_SCALING",
        "QT_FONT_DPI",
        "QT_FONT_FAMILY",
        "QT_LOGGING_RULES",
        "QT_OPENGL",
        "QT_PLUGIN_PATH",
        "QT_QPA_PLATFORM_PLUGIN_PATH",
        "QT_QUICK_BACKEND",
        "QT_QUICK_CONTROLS_STYLE",
        "QT_RHI_BACKEND",
        "QT_SCALE_FACTOR",
        "QT_STYLE_OVERRIDE",
        "QML_DISABLE_DISK_CACHE",
        "QMLSCENE_DEVICE",
        "QSG_RENDER_LOOP",
        "QSG_RHI_BACKEND",
        "FONTCONFIG_FILE",
        "FONTCONFIG_PATH",
        "FC_LANG",
        "MACWIN_HOST_IPV4",
        "MACWIN_GATEWAY_IPV4",
        "MACWIN_DNS_IPV4",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "DOTNET_ROOT",
        "DOTNET_ROOT_X64",
        "PATH"
    ]

    static let jaspManagedPatchHash =
        "be5aa4c652729a61b3205e19ce90e7ae12a7b4c16511ab54b8e417a7165d380e"
    static let jaspManagedPatchSourceHashes: Set<String> = [
        "48ff096ac93c0cc10bbf5bd95ea9b809609b3609796777fe2c75c433eca700e4",
        "db5c6bf993cbe17abb8de5c35825caf8220bacbf9c411f7a2e702eaf0c8af136"
    ]

    private static let chromiumFlagEnvironmentKeys: Set<String> = [
        "MACWIN_CHROMIUM_HELPER_ARGS",
        "MACWIN_STEAMWEBHELPER_ARGS",
        "CHROMIUM_USER_FLAGS",
        "QTWEBENGINE_CHROMIUM_FLAGS"
    ]

    private static let dxvkMacOSDLLNames = [
        "dxgi.dll",
        "d3d11.dll",
        "d3d10core.dll"
    ]

    private static let hostProxyEnvironmentKeys: Set<String> = [
        "ALL_PROXY",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
        "all_proxy",
        "http_proxy",
        "https_proxy",
        "no_proxy"
    ]

    private static func sanitizedChromiumFlagString(_ value: String) -> String {
        let arguments = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return ApplicationCompatibilityProfile.sanitizedLaunchArguments(arguments).joined(separator: " ")
    }

    private static func sanitizedDLLOverrides(_ value: String) -> String {
        value.split(separator: ";")
            .compactMap { group -> String? in
                let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let names = parts.first?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !obsoleteBuiltinTextDLLOverrides.contains($0.lowercased()) } ?? []
                guard !names.isEmpty else { return nil }
                guard parts.count == 2 else {
                    return names.joined(separator: ",")
                }
                return "\(names.joined(separator: ","))=\(parts[1])"
            }
            .joined(separator: ";")
    }

    private static func dllOverrides(_ value: String?, ensuring override: String) -> String {
        let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOverride.isEmpty else {
            return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let requestedNames = dllOverrideNames(in: trimmedOverride)
        let existing = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !existing.isEmpty else { return trimmedOverride }

        let existingNames = existing
            .split(separator: ";")
            .flatMap { dllOverrideNames(in: String($0)) }
        if !requestedNames.isEmpty,
           requestedNames.allSatisfy({ requestedName in
               existingNames.contains { existingName in
                   existingName.caseInsensitiveCompare(requestedName) == .orderedSame
               }
           }) {
            return existing
        }
        return "\(existing);\(trimmedOverride)"
    }

    private static func dllOverrideNames(in group: String) -> [String] {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty } ?? []
    }

    private static let obsoleteBuiltinTextDLLOverrides: Set<String> = [
        "dwrite",
        "usp10"
    ]
}

private final class WineRunnerProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
