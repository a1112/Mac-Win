/// A native close button can run framework-specific close handling. Preserve that
/// path when present; an app-owned frameless surface without one still consults
/// its delegate. This adapter boundary is testable without creating NSApplication.
@MainActor
public protocol WindowCloseTarget: AnyObject {
    var hasAttachedSheet: Bool { get }
    var hasNativeCloseButton: Bool { get }
    func requestNativeClose()
    func delegateAllowsClosing() -> Bool
    func closeWithoutButton()
}

public enum WindowCloseRequest {
    @MainActor
    public static func perform(on target: any WindowCloseTarget) {
        guard !target.hasAttachedSheet else { return }
        if target.hasNativeCloseButton {
            target.requestNativeClose()
        } else if target.delegateAllowsClosing() {
            target.closeWithoutButton()
        }
    }
}
