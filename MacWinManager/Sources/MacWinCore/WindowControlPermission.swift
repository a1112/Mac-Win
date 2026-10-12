import ApplicationServices
import Foundation

/// Permission checks describe this caller. The launched osascript helper can
/// still fail under a different responsible identity; always inspect its result.
public enum WindowControlPermission {
    public static let warningNotification = Notification.Name("MacWinWindowControlWarning")
    public static let pendingNotification = Notification.Name("MacWinWindowControlPending")
    private static let pending = PendingWindowControl()

    public static var pendingRequestID: UUID? { pending.requestID }

    static func prepare(isCurrent: @escaping @Sendable () -> Bool, operation: @escaping @Sendable () -> Void) {
        _ = pending.prepare(isCurrent: isCurrent, operation: operation)
        NotificationCenter.default.post(name: pendingNotification, object: nil)
    }

    public static func runPending(id: UUID) {
        let result = pending.run(id: id)
        NotificationCenter.default.post(name: pendingNotification, object: nil)
        if result != .started {
            report("The queued window-control action expired or was replaced. No helper was started. Select the Wine window manually or launch again to prepare a new action.")
        }
    }

    public static func cancelPending(id: UUID) {
        pending.cancel(id: id)
        NotificationCenter.default.post(name: pendingNotification, object: nil)
    }

    public enum AutomationState: Equatable, Sendable {
        case granted
        case needsUserConsent
        case notAuthorized
        case unknown(Int32)
    }

    public struct Status: Equatable, Sendable {
        public var accessibilityTrusted: Bool
        public var automation: AutomationState
    }

    public enum Failure: Equatable, Sendable {
        case accessibility
        case automation
        case operation
    }

    public static func automationState(code: Int32) -> AutomationState {
        switch code {
        case 0: .granted
        case -1744: .needsUserConsent
        case -1743: .notAuthorized
        default: .unknown(code)
        }
    }

    public static func status() -> Status {
        Status(accessibilityTrusted: AXIsProcessTrusted(), automation: automationState(code: automationCode(request: false)))
    }

    /// Only call from an explicit user action. The return is current trust;
    /// the asynchronous system prompt is not the user's final decision.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Only call from an explicit user action, off the UI thread.
    public static func requestAutomation() -> AutomationState {
        automationState(code: automationCode(request: true))
    }

    private static func automationCode(request: Bool) -> Int32 {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let address = target.aeDesc else { return -50 } // paramErr, not a denial
        return withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, request)
        }
    }

    public static func classify(stderr: String) -> Failure {
        let message = stderr.lowercased()
        if message.contains("(-1743)") || message.contains("not authorized to send apple events") {
            return .automation
        }
        if message.contains("(-25211)") || message.contains("not allowed assistive access") {
            return .accessibility
        }
        return .operation
    }

    public static func recovery(for failure: Failure) -> String {
        switch failure {
        case .accessibility:
            "Window control could not use Accessibility. In System Settings → Privacy & Security → Accessibility, enable the responsible MacWin Manager app (or development host), then return and retry."
        case .automation:
            "System Events automation was not authorized (-1743). Check System Settings → Privacy & Security → Automation for MacWin Manager and System Events. Packaging or policy restrictions can also cause this error."
        case .operation:
            "Automatic window focus/repair did not complete. Open the Wine app from the Dock or select its window manually."
        }
    }

    public static func report(_ message: String) {
        // The app observes this on the main run loop; CLI callers retain stderr.
        FileHandle.standardError.write(Data(("MacWin window control: " + message + "\n").utf8))
        NotificationCenter.default.post(name: warningNotification, object: message)
    }

    /// Attribute/title probes can fail normally. Permission errors must escape
    /// every tolerant AppleScript catch so a denied operation is never silent.
    static func preservingPermissionErrors(in script: String) -> String {
        let handler = """
        on propagatePermissionError(errorMessage, errorNumber)
            if errorNumber is -1743 or errorNumber is -25211 or errorMessage contains "not allowed assistive access" then
                error errorMessage number errorNumber
            end if
            log errorMessage & " (" & errorNumber & ")"
        end propagatePermissionError

        """
        let trackedScript = script.replacingOccurrences(
            of: "if windowMatches is true then",
            with: "if windowMatches is true then\nset targetWindowFound to true"
        )
        return handler + "set targetWindowFound to false\n" + trackedScript.replacingOccurrences(of: "end try", with: """
        on error errorMessage number errorNumber
            my propagatePermissionError(errorMessage, errorNumber)
        end try
        """) + """

        if targetWindowFound then
            error "A Wine window was found, but optional focus/repair did not finish before the retry limit. Complete any welcome steps manually." number -1712
        else
            error "No matching Wine window was found; select the window manually." number -1728
        end if

        """
    }
}

/// One-shot, process-bound actions. Caller permission checks are informational;
/// only an explicit user action consumes a matching request and starts a helper.
final class PendingWindowControl: @unchecked Sendable {
    enum Outcome: Equatable { case started, superseded, expired }
    private struct Action {
        var id: UUID
        var isCurrent: @Sendable () -> Bool
        var operation: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var action: Action?
    private var generation: UUID?

    var requestID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return action?.id
    }

    func prepare(isCurrent: @escaping @Sendable () -> Bool, operation: @escaping @Sendable () -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        generation = id
        action = Action(id: id, isCurrent: isCurrent, operation: operation)
        return id
    }

    func cancel(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == id else { return }
        action = nil
        generation = nil
    }

    func run(id: UUID) -> Outcome {
        lock.lock()
        guard let selected = action, selected.id == id else {
            lock.unlock()
            return .superseded
        }
        action = nil // Consume before checking/spawning; repeated clicks cannot run twice.
        lock.unlock()
        guard selected.isCurrent() else { return .expired }
        lock.lock()
        let current = generation == id
        lock.unlock()
        guard current else { return .superseded }
        selected.operation()
        return .started
    }
}
