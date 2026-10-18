import Foundation

/// Native chrome decisions independent of AppKit, so accessibility and window-state
/// transitions can be tested without launching a GUI or touching user preferences.
public struct WindowSurfacePolicy: Equatable, Sendable {
    public let usesMaterial: Bool
    public let cornerRadius: CGFloat
    public let hasShadow: Bool

    public init(effectsEnabled: Bool, reduceTransparency: Bool, increaseContrast: Bool,
                fullScreen: Bool = false, zoomed: Bool = false) {
        usesMaterial = effectsEnabled && !reduceTransparency && !increaseContrast
        cornerRadius = fullScreen || zoomed ? 0 : 12
        hasShadow = !fullScreen && !zoomed
    }
}
