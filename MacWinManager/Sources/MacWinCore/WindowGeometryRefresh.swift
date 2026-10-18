/// Coalesces geometry maintenance across native window states. A fullscreen or
/// zoomed frame must not become the basis for the normal window's minimum size.
/// Ordinary live resize and cross-display dragging never request frame fitting.
public struct WindowGeometryRefresh: Sendable {
    public enum Mode: Equatable, Sendable { case normal, zoomed, fullScreen }
    public enum Event: Sendable { case attachment, stateChanged, screenChanged, screenParametersChanged }
    public enum Action: Equatable, Sendable { case none, updateMinimum, recoverReachableFrame }

    private var previousMode: Mode?
    private var needsMinimum = false
    private var needsRecovery = false

    public init() {}

    public mutating func receive(_ event: Event, mode: Mode, isLiveResizing: Bool = false) -> Action {
        let returnedToNormal = mode == .normal && previousMode != nil && previousMode != .normal
        previousMode = mode
        switch event {
        case .attachment:
            needsMinimum = true
            needsRecovery = mode != .normal
        case .stateChanged:
            needsMinimum = needsMinimum || returnedToNormal
        case .screenChanged:
            needsMinimum = true
            // A normal cross-screen drag stays exactly where the user places it.
            // A screen change while suspended is checked after normal restoration.
            needsRecovery = needsRecovery || mode != .normal
        case .screenParametersChanged:
            needsRecovery = true
        }
        guard mode == .normal, !isLiveResizing else { return .none }
        if needsRecovery {
            needsRecovery = false
            needsMinimum = false
            return .recoverReachableFrame
        }
        if needsMinimum {
            needsMinimum = false
            return .updateMinimum
        }
        return .none
    }
}
