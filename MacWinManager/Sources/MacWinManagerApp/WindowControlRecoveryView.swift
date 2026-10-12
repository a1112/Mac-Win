import AppKit
import MacWinCore
import SwiftUI

/// Contextual recovery for the existing optional Wine focus/repair operation.
struct WindowControlRecoveryView: View {
    @EnvironmentObject private var store: MacWinStore
    @State private var status = WindowControlPermission.status()
    @State private var requesting = false
    @State private var accessibilityRequestStarted = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = store.windowControlWarning {
                Text(warning).foregroundStyle(.orange).textSelection(.enabled)
                Button("Dismiss warning") { store.windowControlWarning = nil }
            }
            Text("Optional window focus and repair use Accessibility and System Events automation. Launching and manual window control remain available without them.")
            if let requestID = store.windowControlRequestID {
                Text("Run the prepared focus/repair action only for the most recent, still-running Wine process. This action may show macOS consent prompts. Parent permission checks below do not block it. Delegated or closed processes may need manual focus.")
                HStack {
                    Button("Run window control") { WindowControlPermission.runPending(id: requestID) }
                        .disabled(requesting)
                    Button("Cancel queued action") { WindowControlPermission.cancelPending(id: requestID) }
                }
            } else {
                Text("No queued action. Launch a Wine application to prepare optional window control, or use its window manually.")
            }
            Text("Accessibility: \(status.accessibilityTrusted ? "granted to this process" : "not granted to this process")")
            Text("System Events: \(automationLabel)")
            Text("Checks describe MacWin Manager; a launched helper may have a different responsible identity. A successful check is not proof that the window operation succeeded.")
                .font(.caption)
            HStack {
                Button("Request Accessibility") {
                    accessibilityRequestStarted = true
                    _ = WindowControlPermission.requestAccessibility()
                    refresh()
                    message = "The system request is asynchronous. Return here after changing access to recheck."
                }.disabled(requesting || status.accessibilityTrusted || accessibilityRequestStarted)
                Button("Request System Events") {
                    requesting = true
                    Task {
                        let result = await Task.detached { WindowControlPermission.requestAutomation() }.value
                        status.automation = result
                        requesting = false
                        refresh()
                    }
                }.disabled(requesting || status.automation == .granted)
                Button("Recheck") { refresh() }.disabled(requesting)
            }
            HStack {
                Button("Accessibility Settings") { openSettings("Privacy_Accessibility") }
                Button("Automation Settings") { openSettings("Privacy_Automation") }
            }
            Text("If a Settings shortcut does not open the right page, navigate to System Settings → Privacy & Security → Accessibility or Automation. Enable the installed MacWin Manager app and System Events where listed, then retry your original launch action. Development hosts and ad-hoc rebuilds can have different identities.")
                .font(.caption)
            if let message { Text(message).font(.caption) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var automationLabel: String {
        switch status.automation {
        case .granted: "granted to this process"
        case .needsUserConsent: "a user request is needed"
        case .notAuthorized: "not authorized; check Settings, packaging or policy"
        case .unknown(let code): "unknown (native error \(code))"
        }
    }

    private func refresh() { status = WindowControlPermission.status() }

    private func openSettings(_ anchor: String) {
        guard ["Privacy_Accessibility", "Privacy_Automation"].contains(anchor) else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        if !NSWorkspace.shared.open(url) {
            let fallback = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            if !NSWorkspace.shared.open(fallback) {
                message = "Could not open System Settings. Follow the manual navigation instructions above."
            }
        }
    }
}
