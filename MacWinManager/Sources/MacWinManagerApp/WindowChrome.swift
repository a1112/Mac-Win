import AppKit
import Combine
import MacWinCore
import SwiftUI

@MainActor
final class MacWinWindowReference: ObservableObject {
    weak var window: NSWindow?

    enum Action { case close, minimize, zoom, fullScreen }

    func perform(_ action: Action) {
        // A modal child owns interaction until it is dismissed.
        guard let window, window.attachedSheet == nil else { return }
        switch action {
        case .close: WindowCloseRequest.perform(on: NativeWindowCloseTarget(window))
        case .minimize: window.miniaturize(nil)
        case .zoom:
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            else { window.zoom(nil) }
        case .fullScreen: window.toggleFullScreen(nil)
        }
    }
}

@MainActor
private final class NativeWindowCloseTarget: WindowCloseTarget {
    private let window: NSWindow
    init(_ window: NSWindow) { self.window = window }
    var hasAttachedSheet: Bool { window.attachedSheet != nil }
    var hasNativeCloseButton: Bool { window.standardWindowButton(.closeButton) != nil }
    func requestNativeClose() { window.performClose(nil) }
    func delegateAllowsClosing() -> Bool { window.delegate?.windowShouldClose?(window) ?? true }
    func closeWithoutButton() { window.close() }
}

final class MacWinFramelessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
enum MacWinWindowChrome {
    enum Role { case main, sheet }
    private static let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private static let minimumContentSize = NSSize(width: 960, height: 620)
    static let sidebarWidth: CGFloat = 216
    static let titlebarHeight: CGFloat = 48

    /// Called on attachment, not on move/resize/focus. AppKit keeps native resize,
    /// fullscreen, key view loop, autosave and close semantics.
    static func configure(_ window: NSWindow?, role: Role = .main) {
        guard let window, !configuredWindows.contains(window) else { return }
        configuredWindows.add(window)
        let frame = window.frame
        // Visually frameless; retain AppKit's public titled/resizable mechanism
        // for SwiftUI's window class, keyboard eligibility and native edge resize.
        // Do not swizzle or replace a SwiftUI-owned NSWindow subclass.
        window.styleMask.formUnion([.titled, .closable, .resizable, .fullSizeContentView])
        window.styleMask.remove(.unifiedTitleAndToolbar)
        if role == .main { window.styleMask.insert(.miniaturizable) }
        else { window.styleMask.remove(.miniaturizable) }
        // Changing the style mask can rebuild the frame view. Keep the original
        // geometry and configure the new content layer after this change.
        if window.frame != frame { window.setFrame(frame, display: false) }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.setContentBorderThickness(0, for: .minY)
        window.setContentBorderThickness(0, for: .maxY)
        hideStandardButtons(window)
        window.isMovableByWindowBackground = false
        window.isMovable = role == .main
        window.isOpaque = false // transparent clipped corners, even with a solid interior
        window.backgroundColor = .clear
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        window.autorecalculatesKeyViewLoop = true
        window.tabbingMode = .disallowed
        window.animationBehavior = role == .main ? .documentWindow : .default
        if role == .main {
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            // Preserve the sizing branch's restored frame and smaller saved minima.
            // Never clear constraints or restore a saved normal frame into a native
            // fullscreen/zoomed window. The coordinator refreshes after restoration.
            if !window.styleMask.contains(.fullScreen), !window.isZoomed {
                window.minSize = .zero
                window.contentMinSize = .zero
                let restored = window.setFrameUsingName("MacWinMainWindow")
                if !restored && (window.frame.width <= 1 || window.frame.height <= 1) {
                    window.setContentSize(NSSize(width: 1080, height: 720))
                    window.center()
                }
                fitInitialGeometry(window)
            }
            _ = window.setFrameAutosaveName("MacWinMainWindow")
        }
        updateSurface(window)
    }

    private static func fitInitialGeometry(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let screen = window.screen ?? NSScreen.main else { return }
        let frame = CompactWindowGeometry.fittedFrame(
            window.frame, screens: NSScreen.screens.map(\.visibleFrame), fallback: screen.visibleFrame
        )
        if frame != window.frame { window.setFrame(frame, display: false) }
        updateMinimum(window)
    }

    static func updateMinimum(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let screen = window.screen ?? NSScreen.main else { return }
        let available = window.contentRect(forFrameRect: screen.visibleFrame.insetBy(dx: 24, dy: 24)).size
        let current = window.contentRect(forFrameRect: window.frame).size
        let minimum = CompactWindowGeometry.minimumContentSize(
            nominal: minimumContentSize, available: available, current: current
        )
        if window.contentMinSize != minimum { window.contentMinSize = minimum }
    }

    static func recoverAfterScreenChange(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let screen = window.screen ?? NSScreen.main else { return }
        // Lower stale constraints first; otherwise they may reject a recovery
        // frame on a smaller display before the new minimum has been applied.
        updateMinimum(window)
        let frame = CompactWindowGeometry.recoverDisconnectedFrame(
            window.frame, screens: NSScreen.screens.map(\.visibleFrame), fallback: screen.visibleFrame
        )
        if frame != window.frame { window.setFrame(frame, display: false) }
        updateMinimum(window)
    }

    static func updateSurface(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let policy = WindowSurfacePolicy(effectsEnabled: false, reduceTransparency: false, increaseContrast: false,
            fullScreen: window.styleMask.contains(.fullScreen), zoomed: window.isZoomed)
        content.wantsLayer = true
        guard let layer = content.layer else { return }
        // didResize may arrive many times. Unchanged state causes no layer writes
        // and no shadow invalidation; live resizing stays with AppKit.
        if layer.cornerRadius != policy.cornerRadius || !layer.masksToBounds {
            layer.cornerCurve = .continuous
            layer.cornerRadius = policy.cornerRadius
            layer.masksToBounds = true
            layer.isOpaque = false
            layer.backgroundColor = NSColor.clear.cgColor
            window.invalidateShadow()
        }
        if window.hasShadow != policy.hasShadow { window.hasShadow = policy.hasShadow }
    }

    static func hideStandardButtons(_ window: NSWindow) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            // Keep the native close target (and its framework lifecycle) alive.
            // Hidden is distinct from disabled, so performClose remains available.
            window.standardWindowButton(kind)?.isHidden = true
        }
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    let reference: MacWinWindowReference
    var role: MacWinWindowChrome.Role = .main

    func makeCoordinator() -> Coordinator { Coordinator(reference: reference, role: role) }

    func makeNSView(context: Context) -> WindowChromeProbeView {
        let view = WindowChromeProbeView()
        view.onWindowChanged = { [weak coordinator = context.coordinator, weak view] _ in
            // Style-mask changes rebuild AppKit's frame view. Defer attachment
            // until viewDidMoveToWindow/layout has completed, then use its current window.
            DispatchQueue.main.async { [weak coordinator, weak view] in coordinator?.attach(view?.window) }
        }
        return view
    }

    func updateNSView(_ nsView: WindowChromeProbeView, context: Context) {
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak nsView] in
            coordinator?.attach(nsView?.window)
        }
    }

    static func dismantleNSView(_ nsView: WindowChromeProbeView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator {
        private let reference: MacWinWindowReference
        private let role: MacWinWindowChrome.Role
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var isActive = true
        private var geometryRefresh = WindowGeometryRefresh()

        init(reference: MacWinWindowReference, role: MacWinWindowChrome.Role) {
            self.reference = reference
            self.role = role
        }

        func attach(_ newWindow: NSWindow?) {
            guard isActive, window !== newWindow else { return }
            stopObserving()
            window = newWindow
            reference.window = newWindow
            guard let newWindow else { return }
            MacWinWindowChrome.configure(newWindow, role: role)
            refreshGeometry(.attachment, for: newWindow)
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                let isFullScreenTransition = name == NSWindow.didEnterFullScreenNotification || name == NSWindow.didExitFullScreenNotification
                observers.append(center.addObserver(forName: name, object: newWindow, queue: .main) {
                    [weak self, weak newWindow] _ in
                    MainActor.assumeIsolated {
                        if let newWindow {
                            MacWinWindowChrome.updateSurface(newWindow)
                            if isFullScreenTransition {
                                MacWinWindowChrome.hideStandardButtons(newWindow)
                            }
                            self?.refreshGeometry(.stateChanged, for: newWindow)
                        }
                    }
                })
            }
            guard role == .main else { return }
            observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: newWindow, queue: .main) {
                [weak self, weak newWindow] _ in
                MainActor.assumeIsolated {
                    if let newWindow { self?.refreshGeometry(.screenChanged, for: newWindow) }
                }
            })
            observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
                [weak self, weak newWindow] _ in
                MainActor.assumeIsolated {
                    if let newWindow { self?.refreshGeometry(.screenParametersChanged, for: newWindow) }
                }
            })
        }

        private func refreshGeometry(_ event: WindowGeometryRefresh.Event, for window: NSWindow) {
            guard role == .main else { return }
            let mode: WindowGeometryRefresh.Mode = window.styleMask.contains(.fullScreen)
                ? .fullScreen : window.isZoomed ? .zoomed : .normal
            // receive() clears pending work before any AppKit setter can emit a
            // reentrant resize notification. Normal resize events return .none.
            switch geometryRefresh.receive(event, mode: mode, isLiveResizing: window.inLiveResize) {
            case .none: break
            case .updateMinimum: MacWinWindowChrome.updateMinimum(window)
            case .recoverReachableFrame: MacWinWindowChrome.recoverAfterScreenChange(window)
            }
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = nil
            reference.window = nil
            geometryRefresh = WindowGeometryRefresh()
        }

        func invalidate() {
            isActive = false
            stopObserving()
        }
    }
}

final class WindowChromeProbeView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableTitlebarView { DraggableTitlebarView() }
    func updateNSView(_ nsView: DraggableTitlebarView, context: Context) {}
}

final class DraggableTitlebarView: NSView {
    override var mouseDownCanMoveWindow: Bool { false } // explicit native performDrag below
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window, window.attachedSheet == nil else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

struct MacWinWindowControls: View {
    @EnvironmentObject private var store: MacWinStore
    let reference: MacWinWindowReference

    var body: some View {
        HStack(spacing: 6) {
            control(.close, symbol: "xmark", color: .red, label: store.language == .en ? "Close window" : "关闭窗口")
                .keyboardShortcut("w")
            control(.minimize, symbol: "minus", color: .yellow, label: store.language == .en ? "Minimize window" : "最小化窗口")
                .keyboardShortcut("m")
            control(.zoom, symbol: "plus", color: .green, label: store.language == .en ? "Zoom or restore window" : "最大化或还原窗口")
        }
    }

    private func control(_ action: MacWinWindowReference.Action, symbol: String, color: Color, label: String) -> some View {
        Button { reference.perform(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(width: 18, height: 18)
                .background(color.opacity(0.72), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

@MainActor
final class MacWinWindowEffects: ObservableObject {
    static let shared = MacWinWindowEffects()
    private static let preferenceKey = "MacWinWindowEffectsEnabled"
    @Published private(set) var enabled: Bool
    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool
    private var observer: NSObjectProtocol?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        // A process-lifetime singleton owns this one observer. Never attached to
        // move/resize notifications and never writes system preferences.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let workspace = NSWorkspace.shared
                let reduce = workspace.accessibilityDisplayShouldReduceTransparency
                let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
                if self.reduceTransparency != reduce { self.reduceTransparency = reduce }
                if self.increaseContrast != contrast { self.increaseContrast = contrast }
            }
        }
    }

    var usesMaterial: Bool {
        WindowSurfacePolicy(effectsEnabled: enabled, reduceTransparency: reduceTransparency,
                            increaseContrast: increaseContrast).usesMaterial
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    @ObservedObject private var effects = MacWinWindowEffects.shared

    func makeNSView(context: Context) -> MacWinMaterialView {
        let view = MacWinMaterialView()
        view.configure(material: material, blendingMode: blendingMode, enabled: effects.usesMaterial)
        return view
    }
    func updateNSView(_ nsView: MacWinMaterialView, context: Context) {
        nsView.configure(material: material, blendingMode: blendingMode, enabled: effects.usesMaterial)
    }
}

final class MacWinMaterialView: NSView {
    private let materialView = NSVisualEffectView()
    private var materialEnabled: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.state = .followsWindowActiveState
        addSubview(materialView)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func configure(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode, enabled: Bool) {
        if materialView.material != material { materialView.material = material }
        if materialView.blendingMode != blendingMode { materialView.blendingMode = blendingMode }
        if materialEnabled != enabled {
            materialEnabled = enabled
            materialView.isHidden = !enabled
            updateBackground()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (materialEnabled == true ? NSColor.clear : NSColor.windowBackgroundColor).cgColor
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
