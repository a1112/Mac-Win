import AppKit
import MacWinCore
import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    static let macWinReadableSecondaryText = Color(nsColor: .secondaryLabelColor)
}

struct ContentView: View {
    @EnvironmentObject private var store: MacWinStore
    @State private var titlebarLeadingInset: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            UnifiedTitleBar(leadingInset: titlebarLeadingInset)
                .frame(height: MacWinWindowChrome.titlebarHeight)
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: MacWinWindowChrome.sidebarWidth)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.42))
                    .frame(width: 0.5)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    currentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    StatusBar()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            VisualEffectBackground(material: .windowBackground, blendingMode: .withinWindow)
                .allowsHitTesting(false)
        }
        .background(WindowChromeConfigurator(leadingInset: $titlebarLeadingInset))
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: Binding(get: {
            store.pendingExternalExecutable
        }, set: { value in
            store.pendingExternalExecutable = value
        })) { request in
            ExternalExecutableOpenView(request: request)
                .environmentObject(store)
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    @Binding var leadingInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(leadingInset: $leadingInset)
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowChromeProbeView()
        DispatchQueue.main.async {
            context.coordinator.observe(view.window)
            context.coordinator.configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.leadingInset = $leadingInset
        DispatchQueue.main.async {
            context.coordinator.observe(nsView.window)
            context.coordinator.configure(nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        var leadingInset: Binding<CGFloat>
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(leadingInset: Binding<CGFloat>) {
            self.leadingInset = leadingInset
        }

        func observe(_ newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            stopObserving()
            window = newWindow
            guard let newWindow else { return }

            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification
            ] {
                observers.append(center.addObserver(
                    forName: name,
                    object: newWindow,
                    queue: .main
                ) { [weak self, weak newWindow] _ in
                    Task { @MainActor in
                        self?.configure(newWindow)
                    }
                })
            }
        }

        func configure(_ window: NSWindow?) {
            let measuredInset = MacWinWindowChrome.configure(window)
            if abs(leadingInset.wrappedValue - measuredInset) > 0.5 {
                leadingInset.wrappedValue = measuredInset
            }
        }

        func stopObserving() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            window = nil
        }
    }
}

private final class WindowChromeProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
enum MacWinWindowChrome {
    private static let defaultContentSize = NSSize(width: 1080, height: 720)
    private static let minimumContentSize = NSSize(width: 960, height: 620)
    private static let windowCornerRadius: CGFloat = 0
    private static let initiallySizedWindows = NSHashTable<NSWindow>.weakObjects()
    static let sidebarWidth: CGFloat = 216
    static let titlebarHeight: CGFloat = 48

    static func configure(_ window: NSWindow?) -> CGFloat {
        guard let window else { return 84 }

        configureWindowBehavior(window)
        let isFullScreen = window.styleMask.contains(.fullScreen)
        configureContentSurface(for: window)

        if !initiallySizedWindows.contains(window) {
            if let screen = window.screen ?? NSScreen.main {
                let safeFrame = screen.visibleFrame.insetBy(dx: 24, dy: 24)
                window.contentMinSize = NSSize(
                    width: min(minimumContentSize.width, safeFrame.width),
                    height: min(minimumContentSize.height, safeFrame.height)
                )
                window.minSize = window.contentMinSize
                _ = window.setFrameAutosaveName("MacWinMainWindow")
                _ = window.setFrameUsingName("MacWinMainWindow")
                var frame = window.frame
                frame.size.width = min(frame.width, safeFrame.width)
                frame.size.height = min(frame.height, safeFrame.height)
                frame.origin.x = min(max(frame.minX, safeFrame.minX), safeFrame.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, safeFrame.minY), safeFrame.maxY - frame.height)
                if !screen.visibleFrame.contains(window.frame) { window.setFrame(frame, display: false) }
            }
        }
        initiallySizedWindows.add(window)
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        if !isFullScreen {
            for buttonType in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton
            ] {
                let button = window.standardWindowButton(buttonType)
                button?.isHidden = false
                button?.alphaValue = 1
                button?.isEnabled = true
                button?.refusesFirstResponder = true
            }
        }

        guard !isFullScreen,
              let zoomButton = window.standardWindowButton(.zoomButton),
              let buttonContainer = zoomButton.superview,
              let contentView = window.contentView else {
            return 16
        }
        let buttonFrame = buttonContainer.convert(zoomButton.frame, to: contentView)
        return max(84, buttonFrame.maxX + 12)
    }

    private static func configureWindowBehavior(_ window: NSWindow) {
        window.styleMask.formUnion([
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ])
        window.styleMask.remove(.unifiedTitleAndToolbar)
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.setContentBorderThickness(0, for: .minY)
        window.setContentBorderThickness(0, for: .maxY)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.isMovable = true
        window.isRestorable = false
        window.hasShadow = false
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? minimumContentSize
        let minimum = NSSize(width: min(minimumContentSize.width, max(1, available.width - 48)),
                             height: min(minimumContentSize.height, max(1, available.height - 48)))
        window.minSize = minimum
        window.contentMinSize = minimum
        window.minFullScreenContentSize = minimumContentSize
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.alphaValue = 1
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        window.autorecalculatesKeyViewLoop = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
    }

    private static func configureContentSurface(for window: NSWindow) {
        guard let contentView = window.contentView else { return }
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.cornerRadius = 0
        contentView.layer?.masksToBounds = false
        contentView.layer?.borderWidth = 0
        contentView.layer?.borderColor = nil
        contentView.layer?.isOpaque = true
        window.invalidateShadow()
    }
}

private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableTitlebarView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggableTitlebarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                window.miniaturize(nil)
            case "None":
                break
            default:
                window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

struct UnifiedTitleBar: View {
    @EnvironmentObject private var store: MacWinStore
    let leadingInset: CGFloat

    var body: some View {
        ZStack {
            WindowDragRegion()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(-1)

            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    Color.clear
                        .frame(width: leadingInset)
                        .allowsHitTesting(false)

                    MacWinAppIconImage(size: 25)
                        .allowsHitTesting(false)

                    Spacer(minLength: 8)
                }
                .frame(width: MacWinWindowChrome.sidebarWidth)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.32))
                    .frame(width: 0.5)
                    .allowsHitTesting(false)

                HStack(spacing: 7) {
                    Spacer(minLength: 12)

                    WorkspaceModeControl()

                    Menu {
                        ForEach(store.bottles) { bottle in
                            Button {
                                store.selectedBottleId = bottle.id
                            } label: {
                                Label(
                                    bottle.name,
                                    systemImage: store.selectedBottleId == bottle.id
                                        ? "checkmark.circle.fill"
                                        : "shippingbox"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(.tint)
                            Text(activeBottle?.name ?? store.text(.bottle))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                        }
                        .padding(.horizontal, 9)
                        .frame(minWidth: 104, maxWidth: 172, minHeight: 27)
                        .background(
                            Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help(store.text(.currentBottle))

                    if let bottle = activeBottle {
                        Button {
                            Task { await store.launchWindows11Desktop(for: bottle) }
                        } label: {
                            Image(systemName: "macwindow.badge.plus")
                        }
                        .buttonStyle(TitlebarIconButtonStyle())
                        .disabled(bottle.windowsVersion != "win11")
                        .help(store.text(.windows11Desktop))
                    }

                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(TitlebarIconButtonStyle())
                    .help(store.text(.toggleFullScreen))

                    if let engine = activeEngine {
                        Text(engine.wineVersion)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.leading, 2)
                    }
                }
                .padding(.horizontal, 12)
            }
            .zIndex(1)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.38))
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private var activeBottle: BottleManifest? {
        store.selectedBottle ?? store.defaultPerformanceBottle ?? store.bottles.first
    }

    private var activeEngine: EngineManifest? {
        guard let bottle = activeBottle else { return store.engines.first }
        return store.engines.first { $0.id == bottle.engineId } ?? store.engines.first
    }
}

private struct WorkspaceModeControl: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        HStack(spacing: 2) {
            modeButton(
                .apps,
                systemImage: "square.grid.2x2",
                label: store.text(.appMode)
            )
            modeButton(
                .desktop,
                systemImage: "rectangle.inset.filled",
                label: store.text(.desktopMode)
            )
        }
        .padding(2)
        .frame(width: 68, height: 28)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .help(store.text(.workspaceMode))
    }

    private func modeButton(
        _ mode: WorkspaceMode,
        systemImage: String,
        label: String
    ) -> some View {
        let isSelected = store.workspaceMode == mode
        return Button {
            guard store.workspaceMode != mode else { return }
            store.workspaceMode = mode
            store.selection = .desktop
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color(nsColor: .selectedControlTextColor) : Color.macWinReadableSecondaryText)
                .frame(width: 29, height: 22)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "已选择" : "")
    }
}

private struct TitlebarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.macWinReadableSecondaryText)
            .frame(width: 28, height: 26)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.045))
            }
            .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .followsWindowActiveState
    }
}

struct MacWinAppIconImage: View {
    var size: CGFloat

    var body: some View {
        if let image = Self.iconImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: size * 0.72, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(.tint)
        }
    }

    private static let iconImage: NSImage? = {
        guard let url = Bundle.module.url(
            forResource: "MacWinAppMark",
            withExtension: "png",
            subdirectory: "Icons"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

struct MainWorkspaceView: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        switch store.workspaceMode {
        case .apps:
            AppLauncherView()
        case .desktop:
            ImmersiveWorkspaceView()
        }
    }
}

extension ContentView {
    @ViewBuilder
    fileprivate var currentView: some View {
        switch store.selection {
        case .desktop:
            MainWorkspaceView()
        case .home:
            HomeView()
        case .market:
            MarketView()
        case .bottles:
            BottlesView()
        case .diagnostics:
            DiagnosticsView()
        case .settings:
            SettingsView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                ForEach(SidebarSection.allCases) { section in
                    Button {
                        store.selection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbolName)
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 22)
                            Text(store.text(section.titleKey))
                                .font(.system(size: 14, weight: .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .foregroundStyle(Color.primary)
                    .background {
                        if store.selection == section {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(store.text(section.titleKey))
            }
        }
            .padding(.horizontal, 10)
            .padding(.top, 14)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label(store.engines.first?.wineVersion ?? "-", systemImage: "cpu")
                    .lineLimit(1)
                Label("\(store.bottles.count) \(store.text(.bottles))", systemImage: "folder")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(Color.macWinReadableSecondaryText)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background {
            VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
                .allowsHitTesting(false)
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        HStack(spacing: 10) {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
                Text(store.lastError ?? store.statusMessage)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(store.lastError == nil ? Color.macWinReadableSecondaryText : Color.red)
            Spacer()
            Button {
                store.openLogs()
            } label: {
                Label(store.text(.logs), systemImage: "doc.text.magnifyingglass")
            }
            .help(store.text(.openLogs))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: store.text(.home), subtitle: store.text(.launcherCount, store.homeLaunchers.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HomeFoundationStatusCard()
                    if store.homeLaunchers.isEmpty {
                        EmptyState(systemImage: "sparkles.rectangle.stack", title: store.text(.noLaunchersYet), actionTitle: store.text(.openMarket)) {
                            store.selection = .market
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        LazyVStack(spacing: 8) {
                        ForEach(store.homeLaunchers, id: \.1.id) { bottle, launcher in
                            HStack(spacing: 12) {
                                LauncherIconView(
                                    title: launcher.displayName,
                                    iconPath: launcher.iconPath,
                                    systemImage: "app.fill",
                                    tint: .accentColor,
                                    size: 40
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(launcher.displayName)
                                        .font(.headline)
                                    Text(bottle.name)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.macWinReadableSecondaryText)
                                }
                                Spacer()
                                Button {
                                    Task { await store.runLauncher(launcher, in: bottle) }
                                } label: {
                                    Label(store.text(.run), systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

struct HomeFoundationStatusCard: View {
    @EnvironmentObject private var store: MacWinStore

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        SectionPanel(title: store.text(.foundationStatus)) {
            if let snapshot = store.foundationStatusSnapshot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Label(stateTitle(snapshot.state), systemImage: stateIcon(snapshot.state))
                            .font(.headline)
                            .foregroundStyle(stateColor(snapshot.state))
                        Spacer()
                        Text(store.text(.foundationStatusSummary, stateTitle(snapshot.state), snapshot.blockerCount, snapshot.warningCount))
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        SoftwarePlanMetric(
                            title: store.text(.foundationStatusCatalog),
                            value: "\(snapshot.catalogRecipeCount)",
                            systemImage: "shippingbox",
                            tint: snapshot.catalogRecipeCount > 0 ? .blue : .red
                        )
                        SoftwarePlanMetric(
                            title: store.text(.foundationStatusInstallers),
                            value: "\(snapshot.cachedInstallerCount)/\(snapshot.downloadableInstallerCount)",
                            systemImage: "arrow.down.circle",
                            tint: snapshot.missingInstallerCount == 0 ? .green : .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.foundationStatusTests),
                            value: "\(snapshot.presentTestExecutableCount)/\(snapshot.requiredTestExecutableCount)",
                            systemImage: "testtube.2",
                            tint: snapshot.missingRequiredTestExecutableCount == 0 ? .green : .red
                        )
                        SoftwarePlanMetric(
                            title: store.text(.foundationStatusRuntime),
                            value: "\(snapshot.runtimeProcessCount)",
                            systemImage: "cpu",
                            tint: snapshot.runtimeProcessFindingCount == 0 ? .secondary : .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.foundationStatusLogs),
                            value: "\(snapshot.failedLogCount)/\(snapshot.recentLogCount)",
                            systemImage: "doc.text.magnifyingglass",
                            tint: snapshot.failedLogCount == 0 ? .green : .orange
                        )
                    }
                    if !snapshot.topFindings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(snapshot.topFindings.prefix(3))) { finding in
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(finding.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text(finding.recommendedAction)
                                            .font(.caption)
                                            .foregroundStyle(Color.macWinReadableSecondaryText)
                                            .lineLimit(2)
                                    }
                                } icon: {
                                    Image(systemName: icon(for: finding.severity))
                                        .foregroundStyle(color(for: finding.severity))
                                }
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.foundationStatusNoSnapshot), systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }

    private func stateTitle(_ state: FoundationStatusState) -> String {
        switch state {
        case .ready: store.text(.foundationStatusReady)
        case .attention: store.text(.foundationStatusAttention)
        case .blocked: store.text(.foundationStatusBlocked)
        }
    }

    private func stateIcon(_ state: FoundationStatusState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private func stateColor(_ state: FoundationStatusState) -> Color {
        switch state {
        case .ready: .green
        case .attention: .orange
        case .blocked: .red
        }
    }

    private func icon(for severity: FoundationStatusSeverity) -> String {
        switch severity {
        case .blocker: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func color(for severity: FoundationStatusSeverity) -> Color {
        switch severity {
        case .blocker: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

struct MarketView: View {
    @EnvironmentObject private var store: MacWinStore
    @State private var recipeAwaitingInstaller: RecipeManifest?
    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: store.text(.market), subtitle: store.text(.defaultInstallTarget))
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.recipes) { recipe in
                        RecipeRow(recipe: recipe) {
                            if recipe.installer.mode == .localFile {
                                recipeAwaitingInstaller = recipe
                                isImporterPresented = true
                            } else {
                                Task { await store.install(recipe: recipe) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard let recipe = recipeAwaitingInstaller else { return }
            if case .success(let urls) = result, let url = urls.first {
                Task { await store.install(recipe: recipe, localInstaller: url) }
            }
            recipeAwaitingInstaller = nil
        }
    }
}

struct RecipeRow: View {
    @EnvironmentObject private var store: MacWinStore
    var recipe: RecipeManifest
    var install: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            LauncherIconView(
                title: recipe.name,
                iconPath: nil,
                systemImage: iconName,
                tint: iconTint,
                size: 44
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(recipe.name)
                        .font(.headline)
                    Text(AppText.rating(recipe.compatibilityRating, language: store.language))
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    if recipe.engineRequirements.requiresWin32 {
                        Text(store.text(.requiresWin32))
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(.blue)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                    }
                }
                Text("\(recipe.publisher) · \(AppText.category(recipe.category, language: store.language))")
                    .font(.subheadline)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                if let disabledReason = disabledReason {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let warning = recipe.warnings.first {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Button(action: install) {
                Label(buttonTitle, systemImage: recipe.installer.mode == .localFile ? "folder" : "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(recipe.disabledReason != nil)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch recipe.category {
        case "Diagnostics": "waveform.path.ecg.rectangle"
        case "Game Tests": "gamecontroller"
        case "Utilities": "wrench.and.screwdriver"
        case "Developer Tools": "curlybraces.square"
        case "Media": "play.rectangle"
        default: "gamecontroller"
        }
    }

    private var iconTint: Color {
        switch recipe.category {
        case "Diagnostics": .mint
        case "Game Tests": .blue
        case "Utilities": .orange
        case "Developer Tools": .indigo
        case "Media": .pink
        default: .green
        }
    }

    private var buttonTitle: String {
        if recipe.disabledReason != nil {
            return store.text(.staged)
        }
        switch recipe.installer.mode {
        case .localFile:
            return store.text(.choose)
        case .download, .alreadyInstalled, .none:
            return store.text(.install)
        }
    }

    private var disabledReason: String? {
        guard recipe.disabledReason != nil else { return nil }
        if store.language == .zhHans, recipe.id == "vlc" {
            return "已下载并校验，但 MSI 静默安装在当前 win64-only 容器中会卡住。"
        }
        return recipe.disabledReason
    }
}

struct BottlesView: View {
    @EnvironmentObject private var store: MacWinStore
    @State private var newBottleName = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Header(title: store.text(.bottles), subtitle: store.text(.bottleCount, store.bottles.count))
                HStack(spacing: 10) {
                    TextField(store.text(.bottleNamePlaceholder), text: $newBottleName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let name = newBottleName.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await store.createBottle(named: name.isEmpty ? store.text(.defaultBottleName) : name) }
                    } label: {
                        Label(store.text(.create), systemImage: "plus")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.bottles) { bottle in
                            BottleRow(bottle: bottle, selected: store.selectedBottleId == bottle.id) {
                                store.selectedBottleId = bottle.id
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 460)

            Divider()

            if let bottle = store.selectedBottle {
                BottleDetailView(bottle: bottle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(systemImage: "folder.badge.plus", title: store.text(.noBottleSelected), actionTitle: store.text(.createBottle)) {
                    Task { await store.createBottle(named: store.text(.defaultBottleName)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct BottleRow: View {
    @EnvironmentObject private var store: MacWinStore
    var bottle: BottleManifest
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .frame(width: 24)
                    .foregroundStyle(selected ? Color(nsColor: .selectedControlTextColor) : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bottle.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? Color(nsColor: .selectedControlTextColor).opacity(0.86) : Color.macWinReadableSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .foregroundStyle(selected ? Color(nsColor: .selectedControlTextColor) : Color.primary)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [bottle.windowsVersion, bottle.arch.rawValue]
        if let engine = store.engines.first(where: { $0.id == bottle.engineId }), engine.supportsWin32 {
            parts.append(store.text(.win32Supported))
        }
        return parts.joined(separator: " · ")
    }
}

struct BottleDetailView: View {
    @EnvironmentObject private var store: MacWinStore
    var bottle: BottleManifest
    @State private var command = ""
    @State private var arguments = ""

    private let toolColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: bottle.name, subtitle: bottle.id)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionPanel(title: store.text(.launchers)) {
                        HStack {
                            Spacer()
                            Button {
                                Task { await store.scanInstalledApps(in: bottle) }
                            } label: {
                                Label(store.text(.scanInstalledApps), systemImage: "sparkle.magnifyingglass")
                            }
                            .controlSize(.small)
                            Button {
                                Task { await store.repairBottle(bottle) }
                            } label: {
                                Label(store.text(.repairBottle), systemImage: "wrench.and.screwdriver")
                            }
                            .controlSize(.small)
                        }
                        if bottle.installedApps.isEmpty {
                            Text(store.text(.noLaunchers))
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(bottle.installedApps) { launcher in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label(launcher.displayName, systemImage: "play.square")
                                        Spacer()
                                        CompatibilityProfileMenu(launcher: launcher, bottle: bottle, currentProfile: store.compatibilityProfile(for: launcher))
                                        Button {
                                            Task { await store.runLauncherWithDiagnostics(launcher, in: bottle) }
                                        } label: {
                                            Label(store.text(.runWithDiagnostics), systemImage: "stethoscope")
                                        }
                                        .controlSize(.small)
                                        .help(store.text(.runWithDiagnostics))
                                        Button {
                                            Task { await store.runLauncher(launcher, in: bottle) }
                                        } label: {
                                            Label(store.text(.run), systemImage: "play.fill")
                                        }
                                    }
                                    if let profile = store.compatibilityProfile(for: launcher) {
                                        Label(
                                            "\(store.text(.compatibilityProfile)): \(AppText.compatibilityProfileName(profile, language: store.language))",
                                            systemImage: "checkmark.shield"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(Color.macWinReadableSecondaryText)
                                    }
                                }
                                if launcher.id != bottle.installedApps.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }

                    SectionPanel(title: store.text(.graphicsPreset)) {
                        GraphicsPresetSelector(bottle: bottle)
                    }

                    SectionPanel(title: store.text(.nativeUIIntegration)) {
                        NativeUIIntegrationSelector(bottle: bottle)
                    }

                    SectionPanel(title: store.text(.runCommand)) {
                        TextField(store.text(.executablePlaceholder), text: $command)
                            .textFieldStyle(.roundedBorder)
                        TextField(store.text(.arguments), text: $arguments)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button {
                                Task { await store.runCommand(command, args: splitArguments(arguments), in: bottle) }
                            } label: {
                                Label(store.text(.run), systemImage: "terminal")
                            }
                            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Spacer()
                        }
                    }

                    SectionPanel(title: store.text(.tools)) {
                        LazyVGrid(columns: toolColumns, alignment: .leading, spacing: 10) {
                            Button {
                                Task { await store.launchWindows11Desktop(for: bottle) }
                            } label: {
                                Label(store.text(.windows11Desktop), systemImage: "macwindow")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(bottle.windowsVersion != "win11")
                            Button { store.openDriveC(for: bottle) } label: {
                                Label(store.text(.driveC), systemImage: "externaldrive")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { store.openBottleDirectory(bottle) } label: {
                                Label(store.text(.bottle), systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { store.openLogs() } label: {
                                Label(store.text(.logs), systemImage: "doc.text")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                Task { await store.repairBottle(bottle) }
                            } label: {
                                Label(store.text(.repairBottle), systemImage: "wrench.and.screwdriver")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                Task { await store.scanInstalledApps(in: bottle) }
                            } label: {
                                Label(store.text(.scanInstalledApps), systemImage: "sparkle.magnifyingglass")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                Task { await store.stopBottleProcesses(bottle) }
                            } label: {
                                Label(store.text(.stopBottleProcesses), systemImage: "stop.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                Task { await store.restartBottle(bottle) }
                            } label: {
                                Label(store.text(.restartBottle), systemImage: "arrow.clockwise.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(role: .destructive) {
                                Task { await store.deleteBottle(bottle) }
                            } label: {
                                Label(store.text(.delete), systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private func splitArguments(_ value: String) -> [String] {
        value.split(separator: " ").map(String.init)
    }
}

struct CompatibilityProfileMenu: View {
    @EnvironmentObject private var store: MacWinStore
    var launcher: LauncherManifest
    var bottle: BottleManifest
    var currentProfile: ApplicationCompatibilityProfile?

    var body: some View {
        Menu {
            Button {
                Task { await store.clearCompatibilityProfile(from: launcher, in: bottle) }
            } label: {
                Label(
                    store.text(.noCompatibilityProfile),
                    systemImage: currentProfile == nil ? "checkmark.circle.fill" : "circle"
                )
            }
            Divider()
            ForEach(ApplicationCompatibilityProfile.allCases, id: \.self) { profile in
                Button {
                    Task { await store.applyCompatibilityProfile(profile, to: launcher, in: bottle) }
                } label: {
                    Label(
                        AppText.compatibilityProfileName(profile, language: store.language),
                        systemImage: currentProfile == profile ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            Label(store.text(.compatibilityProfile), systemImage: "checkmark.shield")
        }
        .controlSize(.small)
        .help(store.text(.clearCompatibilityProfile))
    }
}

struct GraphicsPresetSelector: View {
    @EnvironmentObject private var store: MacWinStore
    var bottle: BottleManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GraphicsPreset.allCases, id: \.self) { preset in
                let selected = store.graphicsPreset(for: currentBottle) == preset
                let available = store.graphicsPresetAvailable(preset, for: currentBottle)

                Button {
                    Task { await store.applyGraphicsPreset(preset, to: currentBottle) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.macWinReadableSecondaryText)
                            .frame(width: 20, height: 20)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(AppText.graphicsPresetName(preset, language: store.language))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if !available {
                                    Text(store.text(.gptkMissing))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .lineLimit(1)
                                }
                            }

                            Text(AppText.graphicsPresetHelp(preset, language: store.language))
                                .font(.caption)
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selected || !available)
            }

            if let engine = engineForBottle {
                Divider()
                HStack(spacing: 8) {
                    Text(store.text(.gptkStatus))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    Text(GraphicsPreset.gptkD3DMetal.isAvailable(engine: engine) ? store.text(.gptkAvailable) : store.text(.gptkMissing))
                        .font(.caption)
                        .foregroundStyle(GraphicsPreset.gptkD3DMetal.isAvailable(engine: engine) ? .green : .orange)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var currentBottle: BottleManifest {
        store.bottles.first { $0.id == bottle.id } ?? bottle
    }

    private var engineForBottle: EngineManifest? {
        store.engines.first { $0.id == currentBottle.engineId } ?? store.engines.first
    }
}

struct NativeUIIntegrationSelector: View {
    @EnvironmentObject private var store: MacWinStore
    var bottle: BottleManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(NativeUIIntegrationPreset.allCases, id: \.self) { preset in
                let selected = store.nativeUIIntegrationPreset(for: currentBottle) == preset
                Button {
                    Task { await store.applyNativeUIIntegrationPreset(preset, to: currentBottle) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.macWinReadableSecondaryText)
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppText.nativeUIIntegrationPresetName(preset, language: store.language))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(AppText.nativeUIIntegrationPresetHelp(preset, language: store.language))
                                .font(.caption)
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selected)
            }
        }
    }

    private var currentBottle: BottleManifest {
        store.bottles.first(where: { $0.id == bottle.id }) ?? bottle
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: store.text(.diagnostics), subtitle: store.text(.diagnosticSubtitle))
            HStack(spacing: 10) {
                Button {
                    Task { await store.runDiagnostics() }
                } label: {
                    Label(store.text(.runProbeSuite), systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    store.refreshRecentLogs()
                } label: {
                    Label(store.text(.refreshLogs), systemImage: "arrow.clockwise")
                }
                Button {
                    store.openLogs()
                } label: {
                    Label(store.text(.logs), systemImage: "doc.text")
                }
                Button {
                    store.exportCapabilityReport()
                } label: {
                    Label(store.text(.exportCapabilityReport), systemImage: "square.and.arrow.up")
                }
                Button {
                    store.exportHostEnvironmentCSV()
                } label: {
                    Label(store.text(.exportHostEnvironmentCSV), systemImage: "desktopcomputer")
                }
                Button {
                    store.exportSupportBundle()
                } label: {
                    Label(store.text(.exportSupportBundle), systemImage: "shippingbox.and.arrow.backward")
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    SupportTriageSummarySection()
                    NativeUIProbeSection()
                    NativeUIApplicationMatrixSection()
                    TestAssetSummarySection()
                    BottleHealthSummarySection()
                    RuntimeProcessSummarySection()
                    TestExecutionPlanSummarySection()
                    TestCoverageSummarySection()
                    SoftwareSampleCatalogSection()
                    SoftwareSampleLogCorrelationSection()
                    SoftwareCollectionAcceptanceSection()
                    SoftwareCollectionSection()
                    InstallerAssetSummarySection()
                    InstallerDownloadHistorySection()
                    SoftwareTestPlanSection()
                    SoftwareSmokeMatrixSection()
                    ActivityTimelineSection()
                    CompatibilityRepairAuditSection()
                    DiagnosticHistorySection()
                    DiagnosticArtifactIndexSection()

                    if let report = store.diagnosticReport {
                        SectionPanel(title: store.text(.result)) {
                            LabeledContent(store.text(.exitCode), value: "\(report.exitCode)")
                            LabeledContent(store.text(.log), value: report.logURL.path)
                        }
                        SectionPanel(title: store.text(.checks)) {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(diagnosticCategories(in: report), id: \.self) { category in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(AppText.diagnosticCategory(category, language: store.language))
                                                .font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(categorySummary(category, in: report))
                                                .font(.caption)
                                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                        }
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                                            ForEach(report.items.filter { $0.category == category }) { item in
                                                DiagnosticCard(item: item)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        SectionPanel(title: store.text(.result)) {
                            HStack {
                                Text(store.text(.noDiagnosticRun))
                                    .foregroundStyle(Color.macWinReadableSecondaryText)
                                Spacer()
                                Button {
                                    Task { await store.runDiagnostics() }
                                } label: {
                                    Label(store.text(.run), systemImage: "play.fill")
                                }
                            }
                        }
                    }

                    LogMaintenanceSection()
                    LogIssueSummarySection()
                    RecentLogsSection()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            store.refreshDiagnosticsPage()
        }
    }

    private func diagnosticDetail(_ item: DiagnosticItem) -> String {
        AppText.diagnosticStatus(item.status, language: store.language)
    }

    private func diagnosticCategories(in report: DiagnosticReport) -> [DiagnosticCategory] {
        DiagnosticCategory.allCases.filter { category in
            report.items.contains { $0.category == category }
        }
    }

    private func categorySummary(_ category: DiagnosticCategory, in report: DiagnosticReport) -> String {
        let items = report.items.filter { $0.category == category }
        let passed = items.filter { $0.status == .passed }.count
        let failed = items.filter { $0.status == .failed }.count
        let skipped = items.filter { $0.status == .skipped }.count
        if store.language == .zhHans {
            return "通过 \(passed)/\(items.count)" + (failed > 0 ? " · 失败 \(failed)" : "") + (skipped > 0 ? " · 跳过 \(skipped)" : "")
        }
        return "passed \(passed)/\(items.count)" + (failed > 0 ? " · failed \(failed)" : "") + (skipped > 0 ? " · skipped \(skipped)" : "")
    }
}

struct NativeUIProbeSection: View {
    @EnvironmentObject private var store: MacWinStore
    @State private var architecture: WindowsExecutableArchitecture = .x86_64

    private let modeColumns = [GridItem(.adaptive(minimum: 190), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.nativeUIProbe)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.text(.nativeUIProbeSubtitle))
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Image(systemName: sessionIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(sessionColor)
                        .frame(width: 22)
                    Text(sessionStatusText)
                        .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }

                if let bridge = selectedBridgeEngineReport {
                    HStack(spacing: 10) {
                        Image(systemName: bridge.isReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(bridge.isReady ? .green : .orange)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bridge.engineName)
                                .font(.subheadline.weight(.semibold))
                            Text(store.text(
                                .nativeUIBridgeStatus,
                                bridgeStatus(bridge.hostComponent.isReady),
                                bridgeStatus(bridge.architecture(.x86_64)?.isReady),
                                bridgeStatus(bridge.architecture(.i386)?.isReady)
                            ))
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: artifactIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(artifactColor)
                        .frame(width: 22)
                    Text(store.text(
                        .nativeUIProbeAssets,
                        store.nativeUIProbeArtifactReport.x86_64Path == nil ? store.text(.nativeUIProbeMissingShort) : store.text(.nativeUIProbeAvailable),
                        store.nativeUIProbeArtifactReport.i386Path == nil ? store.text(.nativeUIProbeMissingShort) : store.text(.nativeUIProbeAvailable)
                    ))
                    .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Picker(store.text(.nativeUIProbeArchitecture), selection: $architecture) {
                        Text(store.text(.probeArchitectureX86_64)).tag(WindowsExecutableArchitecture.x86_64)
                        Text(store.text(.probeArchitectureI686Wow64)).tag(WindowsExecutableArchitecture.i386)
                    }
                    .labelsHidden()
                    .frame(width: 145)
                    .accessibilityLabel(store.text(.nativeUIProbeArchitecture))
                    .accessibilityIdentifier("native-ui-probe-architecture")
                    Button {
                        store.refreshNativeUIProbeState()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .help(store.text(.refreshLogs))
                    .accessibilityLabel(store.text(.refreshLogs))
                    .accessibilityIdentifier("native-ui-probe-refresh")
                }

                if let bottle = store.selectedBottle ?? store.defaultPerformanceBottle {
                    HStack(spacing: 10) {
                        Label(store.text(.nativeUIProbeCurrentBottle), systemImage: "shippingbox")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        Picker(store.text(.nativeUIProbeCurrentBottle), selection: Binding(
                            get: { store.selectedBottleId ?? bottle.id },
                            set: { store.selectedBottleId = $0 }
                        )) {
                            ForEach(store.bottles) { candidate in
                                Text(candidate.name).tag(candidate.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 250)
                        Spacer(minLength: 0)
                        Text(AppText.nativeUIIntegrationPresetName(
                            NativeUIIntegrationPreset.current(in: bottle),
                            language: store.language
                        ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    }
                }

                if !store.nativeUIProbeArtifactReport.isReady {
                    Label(store.text(.nativeUIProbeMissing), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    LazyVGrid(columns: modeColumns, alignment: .leading, spacing: 8) {
                        ForEach(NativeUIProbeMode.allCases) { mode in
                            let modeName = AppText.nativeUIProbeModeName(mode, language: store.language)
                            Button {
                                Task { await store.runNativeUIProbe(mode: mode, architecture: architecture) }
                            } label: {
                                Label(
                                    modeName,
                                    systemImage: mode.isModern ? "macwindow" : "rectangle.and.paperclip"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .controlSize(.small)
                            .disabled(!store.canRunNativeUIProbe(mode: mode, architecture: architecture))
                            .accessibilityLabel(modeName)
                            .accessibilityIdentifier("native-ui-probe-\(mode.rawValue)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }

                if let report = store.nativeUIProbeLastRunReport {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: runIcon(report.status))
                            .foregroundStyle(runColor(report.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppText.nativeUIProbeModeName(report.mode, language: store.language))
                                .font(.caption.weight(.semibold))
                            Text("\(report.bottleName) · \(report.architecture.rawValue) · \(report.nativeUIPreset.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                        }
                        Spacer(minLength: 0)
                        Text(report.endedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button {
                            store.openNativeUIProbeLog(report)
                        } label: {
                            Image(systemName: "doc.text")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        .help(store.text(.openLogFile))
                    }
                } else {
                    Label(store.text(.noNativeUIProbeRun), systemImage: "clock.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-ui-probe-section")
    }

    private var artifactIcon: String {
        store.nativeUIProbeArtifactReport.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var sessionStatusText: String {
        switch store.hostGUISessionReport.state {
        case .unlocked: store.text(.nativeUIProbeSessionUnlocked)
        case .locked: store.text(.nativeUIProbeSessionLocked)
        case .unavailable: store.text(.nativeUIProbeSessionUnavailable)
        }
    }

    private var sessionIcon: String {
        switch store.hostGUISessionReport.state {
        case .unlocked: "lock.open.fill"
        case .locked: "lock.fill"
        case .unavailable: "questionmark.diamond.fill"
        }
    }

    private var sessionColor: Color {
        switch store.hostGUISessionReport.state {
        case .unlocked: .green
        case .locked: .orange
        case .unavailable: .secondary
        }
    }

    private var selectedBridgeEngineReport: NativeUIBridgeEngineReport? {
        guard let bottle = store.selectedBottle ?? store.defaultPerformanceBottle else { return nil }
        return store.nativeUIBridgeHealthReport.engines.first { $0.engineId == bottle.engineId }
    }

    private func bridgeStatus(_ ready: Bool?) -> String {
        guard let ready else { return store.text(.nativeUIBridgeUnavailable) }
        return store.text(ready ? .nativeUIBridgeReady : .nativeUIBridgeIncomplete)
    }

    private var artifactColor: Color {
        store.nativeUIProbeArtifactReport.isReady ? .green : .orange
    }

    private func runIcon(_ status: NativeUIProbeRunStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .cancelled: "slash.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func runColor(_ status: NativeUIProbeRunStatus) -> Color {
        switch status {
        case .passed: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }
}

struct NativeUIApplicationMatrixSection: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        let report = store.nativeUIApplicationMatrixReport
        SectionPanel(title: store.text(.nativeUIApplicationMatrix)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.text(.nativeUIApplicationMatrixSubtitle))
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Image(systemName: report.failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(report.failedCount > 0 ? .orange : .green)
                    Text(store.text(
                        .nativeUIApplicationMatrixSummary,
                        report.entryCount,
                        report.installedCount,
                        report.passedCount,
                        report.unverifiedCount
                    ))
                    .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Button {
                        Task { await store.runRepresentativeSoftwareAcceptance() }
                    } label: {
                        Label(store.text(.runRepresentativeAcceptance), systemImage: "play.circle")
                    }
                    .controlSize(.small)
                }

                if store.representativeAcceptanceReport.targetCount > 0 {
                    RepresentativeAcceptanceSummary(report: store.representativeAcceptanceReport)
                }

                if report.entries.isEmpty {
                    Label(store.text(.noNativeUIApplicationMatrix), systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(NativeUIApplicationMatrixFamily.allCases) { family in
                            let entries = report.entries.filter { $0.family == family }
                            if !entries.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppText.nativeUIApplicationFamilyName(family, language: store.language))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.macWinReadableSecondaryText)
                                    ForEach(entries) { entry in
                                        NativeUIApplicationMatrixRow(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct NativeUIApplicationMatrixRow: View {
    @EnvironmentObject private var store: MacWinStore
    var entry: NativeUIApplicationMatrixEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(entry.publisher) · \(entry.category)")
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(1)
                    if let exePath = entry.exePath {
                        Text(exePath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else {
                        Text(entry.availabilityDetail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        MatrixBadge(
                            title: AppText.nativeUIApplicationAvailabilityName(entry.availability, language: store.language),
                            color: availabilityColor
                        )
                        MatrixBadge(
                            title: AppText.nativeUIApplicationEvidenceName(entry.launchEvidence, language: store.language),
                            color: evidenceColor
                        )
                    }
                    if let bottleName = entry.bottleName {
                        Text(bottleName)
                            .font(.caption2)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                if let currentPreset = entry.currentPreset,
                   let bottleId = entry.bottleId,
                   let bottle = store.bottles.first(where: { $0.id == bottleId }) {
                    Menu {
                        ForEach(entry.presetOptions, id: \.self) { preset in
                            Button {
                                Task { await store.applyNativeUIIntegrationPreset(preset, to: bottle) }
                            } label: {
                                Label(
                                    AppText.nativeUIIntegrationPresetName(preset, language: store.language),
                                    systemImage: preset == currentPreset ? "checkmark" : ""
                                )
                            }
                        }
                    } label: {
                        Label(
                            "\(store.text(.nativeUIApplicationPreset)): \(AppText.nativeUIIntegrationPresetName(currentPreset, language: store.language))",
                            systemImage: "slider.horizontal.3"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                }
                if entry.launcherId != nil {
                    Button {
                        Task { await store.runNativeUIApplication(entry) }
                    } label: {
                        Label(store.text(.nativeUIApplicationRun), systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    Button {
                        Task { await store.runNativeUIApplication(entry, withDiagnostics: true) }
                    } label: {
                        Label(store.text(.nativeUIApplicationRunDiagnostics), systemImage: "stethoscope")
                    }
                    .controlSize(.small)
                } else if let recipeId = entry.recipeId,
                          entry.recipeAvailable,
                          let recipe = store.recipes.first(where: { $0.id == recipeId }) {
                    if recipe.installer.mode == .localFile, !entry.installerAvailable {
                        Button {
                            store.selection = .market
                        } label: {
                            Label(store.text(.nativeUIApplicationSelectInstaller), systemImage: "folder")
                        }
                        .controlSize(.small)
                    } else {
                        Button {
                            Task { await store.install(recipe: recipe) }
                        } label: {
                            Label(store.text(.nativeUIApplicationInstall), systemImage: "arrow.down.circle")
                        }
                        .controlSize(.small)
                    }
                }
                if let logPath = entry.latestLaunchLogPath {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .help(store.text(.openLogFile))
                }
                Spacer(minLength: 0)
                if let latestLaunchAt = entry.latestLaunchAt {
                    Text(latestLaunchAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if entry.launchEvidence != .notRun || entry.evidenceDetail == "not-run-smoke-session-locked" {
                Label(
                    AppText.nativeUIApplicationEvidenceDetail(entry.evidenceDetail, language: store.language),
                    systemImage: entry.evidenceDetail == "not-run-smoke-session-locked"
                        ? "lock"
                        : (entry.launchEvidence == .passed ? "checkmark.seal" : "eye")
                )
                .font(.caption2)
                .foregroundStyle(entry.launchEvidence == .failed ? Color.red : Color.macWinReadableSecondaryText)
                .lineLimit(2)
            }

            if !entry.warnings.isEmpty {
                Label(entry.warnings.first ?? "", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch entry.family {
        case .hoyoPlay: "gamecontroller.fill"
        case .steam: "gamecontroller"
        case .browser: "safari"
        case .office: "doc.richtext"
        case .lenovoAppStore: "bag"
        }
    }

    private var iconColor: Color {
        switch entry.launchEvidence {
        case .passed: .green
        case .failed: .red
        case .observed: .orange
        case .notRun: .blue
        }
    }

    private var availabilityColor: Color {
        switch entry.availability {
        case .installed: .green
        case .recipeAvailable: .blue
        case .installerAvailable: .orange
        case .unavailable: .secondary
        }
    }

    private var evidenceColor: Color {
        switch entry.launchEvidence {
        case .passed: .green
        case .failed: .red
        case .observed: .orange
        case .notRun: .secondary
        }
    }
}

struct MatrixBadge: View {
    var title: String
    var color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct DiagnosticHistorySection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        let report = store.diagnosticHistoryReport
        SectionPanel(title: store.text(.diagnosticHistory)) {
            if report.records.isEmpty {
                HStack(spacing: 10) {
                    Label(store.text(.noDiagnosticHistory), systemImage: "clock.badge.questionmark")
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    Spacer(minLength: 0)
                    Button {
                        store.exportDiagnosticHistoryCSV()
                    } label: {
                        Label(store.text(.exportDiagnosticHistoryCSV), systemImage: "tablecells")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    Button {
                        store.refreshDiagnosticHistory()
                    } label: {
                        Label(store.text(.refreshLogs), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.failedRunCount > 0 || report.timedOutRunCount > 0 ? "waveform.path.ecg.rectangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(report.failedRunCount > 0 || report.timedOutRunCount > 0 ? .orange : .green)
                        Text(store.text(.diagnosticHistorySummary, report.totalRunCount, report.failedRunCount, report.timedOutRunCount))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Button {
                            store.exportDiagnosticHistoryCSV()
                        } label: {
                            Label(store.text(.exportDiagnosticHistoryCSV), systemImage: "tablecells")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        Button {
                            store.refreshDiagnosticHistory()
                        } label: {
                            Label(store.text(.refreshLogs), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                    }

                    LazyVGrid(columns: metricColumns, spacing: 8) {
                        SoftwarePlanMetric(title: store.text(.diagnosticRuns), value: "\(report.totalRunCount)", systemImage: "list.bullet.clipboard", tint: .blue)
                        SoftwarePlanMetric(title: store.text(.passedRuns), value: "\(report.passedRunCount)", systemImage: "checkmark.circle.fill", tint: .green)
                        SoftwarePlanMetric(title: store.text(.failedRuns), value: "\(report.failedRunCount)", systemImage: "xmark.circle.fill", tint: report.failedRunCount > 0 ? .red : .secondary)
                        SoftwarePlanMetric(title: store.text(.timedOutRuns), value: "\(report.timedOutRunCount)", systemImage: "timer", tint: report.timedOutRunCount > 0 ? .orange : .secondary)
                    }

                    VStack(spacing: 8) {
                        ForEach(report.records.prefix(8)) { record in
                            DiagnosticHistoryRow(record: record)
                        }
                    }
                }
            }
        }
    }
}

struct DiagnosticHistoryRow: View {
    @EnvironmentObject private var store: MacWinStore
    var record: DiagnosticRunRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(titleText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)
                Text(record.endedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button {
                    store.openDiagnosticRunLog(record)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.openLogFile))
                Button {
                    store.revealDiagnosticRunLog(record)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.revealInFinder))
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var titleText: String {
        let scope = AppText.diagnosticRunScope(record.scope, language: store.language)
        if let assetId = record.assetId, !assetId.isEmpty {
            return "\(scope) · \(assetId)"
        }
        if !record.assetIds.isEmpty {
            return "\(scope) · \(record.assetIds.prefix(3).joined(separator: ", "))"
        }
        return scope
    }

    private var detailText: String {
        let duration = String(format: "%.1fs", record.durationSeconds)
        let counts = store.language == .zhHans
            ? "通过 \(record.passedItemCount)/\(record.totalItemCount) · 失败 \(record.failedItemCount)"
            : "passed \(record.passedItemCount)/\(record.totalItemCount) · failed \(record.failedItemCount)"
        return "\(counts) · \(store.text(.durationSeconds)) \(duration) · \(URL(fileURLWithPath: record.logPath).lastPathComponent)"
    }

    private var statusText: String {
        if record.timedOut {
            return store.text(.timedOutRuns)
        }
        return record.exitCode == 0 ? store.text(.passedRuns) : store.text(.failedRuns)
    }

    private var statusIcon: String {
        if record.timedOut {
            return "timer"
        }
        return record.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var statusColor: Color {
        if record.timedOut {
            return .orange
        }
        return record.exitCode == 0 ? .green : .red
    }
}

struct DiagnosticArtifactIndexSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        let report = store.diagnosticArtifactIndexReport
        SectionPanel(title: store.text(.diagnosticArtifacts)) {
            if report.artifacts.isEmpty {
                HStack(spacing: 10) {
                    Label(store.text(.noDiagnosticArtifacts), systemImage: "tray")
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    Spacer(minLength: 0)
                    Button {
                        store.exportDiagnosticArtifactIndexCSV()
                    } label: {
                        Label(store.text(.exportDiagnosticArtifactIndexCSV), systemImage: "tablecells")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    Button {
                        store.refreshDiagnosticArtifacts()
                    } label: {
                        Label(store.text(.refreshLogs), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox.fill")
                            .foregroundStyle(.blue)
                        Text(store.text(.diagnosticArtifactsSummary, report.artifactCount, Double(report.totalBytes) / 1_048_576.0))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Button {
                            store.exportDiagnosticArtifactIndexCSV()
                        } label: {
                            Label(store.text(.exportDiagnosticArtifactIndexCSV), systemImage: "tablecells")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        Button {
                            store.refreshDiagnosticArtifacts()
                        } label: {
                            Label(store.text(.refreshLogs), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                    }

                    LazyVGrid(columns: metricColumns, spacing: 8) {
                        DiagnosticArtifactMetric(kind: .log, systemImage: "doc.text", tint: .blue)
                        DiagnosticArtifactMetric(kind: .report, systemImage: "doc.richtext", tint: .indigo)
                        DiagnosticArtifactMetric(kind: .table, systemImage: "tablecells", tint: .green)
                        DiagnosticArtifactMetric(kind: .script, systemImage: "terminal", tint: .orange)
                        DiagnosticArtifactMetric(kind: .bundle, systemImage: "shippingbox", tint: .teal)
                        DiagnosticArtifactMetric(kind: .record, systemImage: "clock.arrow.circlepath", tint: .indigo)
                    }

                    VStack(spacing: 8) {
                        ForEach(report.artifacts.prefix(8)) { artifact in
                            DiagnosticArtifactRow(artifact: artifact)
                        }
                    }
                }
            }
        }
    }
}

struct DiagnosticArtifactMetric: View {
    @EnvironmentObject private var store: MacWinStore
    var kind: DiagnosticArtifactKind
    var systemImage: String
    var tint: Color

    var body: some View {
        SoftwarePlanMetric(
            title: title,
            value: "\(store.diagnosticArtifactIndexReport.kindCounts[kind] ?? 0)",
            systemImage: systemImage,
            tint: tint
        )
    }

    private var title: String {
        switch kind {
        case .log: store.text(.artifactLogs)
        case .report: store.text(.artifactReports)
        case .table: store.text(.artifactTables)
        case .script: store.text(.artifactScripts)
        case .bundle: store.text(.artifactBundles)
        case .record: store.text(.artifactRecords)
        case .other: store.text(.artifactOthers)
        }
    }
}

struct DiagnosticArtifactRow: View {
    @EnvironmentObject private var store: MacWinStore
    var artifact: DiagnosticArtifactItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(artifact.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(kindTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }
                Text(artifact.relativePath)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
                Text("\(LogMaintenanceSection.formattedByteCount(artifact.byteCount)) · \(artifact.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button {
                    store.openDiagnosticArtifact(artifact)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.openLogFile))
                Button {
                    store.revealDiagnosticArtifact(artifact)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.revealInFinder))
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch artifact.kind {
        case .log: "doc.text"
        case .report: "doc.richtext"
        case .table: "tablecells"
        case .script: "terminal"
        case .bundle: "shippingbox"
        case .record: "clock.arrow.circlepath"
        case .other: "doc"
        }
    }

    private var tint: Color {
        switch artifact.kind {
        case .log: .blue
        case .report: .indigo
        case .table: .green
        case .script: .orange
        case .bundle: .teal
        case .record: .indigo
        case .other: .secondary
        }
    }

    private var kindTitle: String {
        switch artifact.kind {
        case .log: store.text(.artifactLogs)
        case .report: store.text(.artifactReports)
        case .table: store.text(.artifactTables)
        case .script: store.text(.artifactScripts)
        case .bundle: store.text(.artifactBundles)
        case .record: store.text(.artifactRecords)
        case .other: store.text(.artifactOthers)
        }
    }
}

struct SupportTriageSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    private var report: SupportTriageReport {
        store.supportTriageReport
    }

    var body: some View {
        SectionPanel(title: store.text(.supportTriage)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(store.text(
                        .supportTriageSummary,
                        statusText,
                        report.itemCount,
                        report.blockerCount,
                        report.highCount,
                        report.warningCount
                    ))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        store.refreshSupportTriage()
                    } label: {
                        Label(store.text(.refreshSupportTriage), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    Button {
                        store.exportSupportBundle()
                    } label: {
                        Label(store.text(.exportSupportBundle), systemImage: "shippingbox.and.arrow.backward")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                }

                LazyVGrid(columns: metricColumns, spacing: 8) {
                    SoftwarePlanMetric(
                        title: store.text(.supportTriageBlockers),
                        value: "\(report.blockerCount)",
                        systemImage: "xmark.octagon.fill",
                        tint: .red
                    )
                    SoftwarePlanMetric(
                        title: store.text(.supportTriageHighPriority),
                        value: "\(report.highCount)",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                    SoftwarePlanMetric(
                        title: store.text(.supportTriageWarnings),
                        value: "\(report.warningCount)",
                        systemImage: "exclamationmark.circle.fill",
                        tint: .yellow
                    )
                    SoftwarePlanMetric(
                        title: store.text(.supportTriageInfo),
                        value: "\(report.infoCount)",
                        systemImage: "info.circle.fill",
                        tint: .blue
                    )
                }

                if report.items.isEmpty {
                    Label(store.text(.noSupportTriageItems), systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Divider()
                    Text(store.text(.supportTriageActions))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    VStack(spacing: 8) {
                        ForEach(report.items.prefix(6)) { item in
                            SupportTriageItemRow(item: item)
                        }
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch report.status {
        case .ready:
            return store.text(.supportTriageReady)
        case .attention:
            return store.text(.supportTriageAttention)
        case .blocked:
            return store.text(.supportTriageBlocked)
        }
    }

    private var statusIcon: String {
        switch report.status {
        case .ready:
            return "checkmark.seal.fill"
        case .attention:
            return "exclamationmark.triangle.fill"
        case .blocked:
            return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch report.status {
        case .ready:
            return .green
        case .attention:
            return .orange
        case .blocked:
            return .red
        }
    }
}

struct SupportTriageItemRow: View {
    var item: SupportTriageItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: severityIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(severityColor)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.source.rawValue)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(severityColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(severityColor.opacity(0.12), in: Capsule())
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)
                Text(item.recommendedAction)
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var severityIcon: String {
        switch item.severity {
        case .blocker:
            return "xmark.octagon.fill"
        case .high:
            return "exclamationmark.triangle.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    private var severityColor: Color {
        switch item.severity {
        case .blocker:
            return .red
        case .high:
            return .orange
        case .warning:
            return .yellow
        case .info:
            return .blue
        }
    }
}

struct TestAssetSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private var report: TestAssetReport {
        store.testAssetReport
    }

    private var missingRequiredAssets: [TestAssetStatus] {
        report.statuses.filter { $0.required && !$0.exists }
    }

    var body: some View {
        SectionPanel(title: store.text(.testAssets)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: report.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.isReady ? .green : .orange)
                    Text(summaryText)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(report.presentCount)/\(report.totalCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                }

                if !missingRequiredAssets.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(missingRequiredAssets.prefix(5)) { asset in
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.red)
                                Text(asset.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(asset.kind.rawValue)
                                    .foregroundStyle(Color.macWinReadableSecondaryText)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var summaryText: String {
        if report.isReady {
            return store.text(.testAssetsReady, report.presentCount, report.totalCount)
        }
        return store.text(.testAssetsMissing, report.missingRequiredCount)
    }
}

struct BottleHealthSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private var report: BottleHealthAuditReport {
        store.bottleHealthReport
    }

    private let metricColumns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.bottleHealth)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: healthIcon)
                        .foregroundStyle(healthColor)
                    Text(store.text(
                        .bottleHealthSummary,
                        report.bottleCount,
                        report.healthyBottleCount,
                        report.actionRequiredBottleCount,
                        report.warningBottleCount
                    ))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }

                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                    SoftwarePlanMetric(
                        title: store.text(.healthyBottles),
                        value: "\(report.healthyBottleCount)",
                        systemImage: "checkmark.seal.fill",
                        tint: .green
                    )
                    SoftwarePlanMetric(
                        title: store.text(.bottlesNeedAttention),
                        value: "\(report.actionRequiredBottleCount)",
                        systemImage: "exclamationmark.octagon.fill",
                        tint: .red
                    )
                    SoftwarePlanMetric(
                        title: store.text(.bottleHealthWarnings),
                        value: "\(report.warningBottleCount)",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                    SoftwarePlanMetric(
                        title: store.text(.staleLaunchers),
                        value: "\(report.staleLauncherCount)",
                        systemImage: "text.badge.xmark",
                        tint: .teal
                    )
                    SoftwarePlanMetric(
                        title: store.text(.incompleteProfiles),
                        value: "\(report.incompleteCompatibilityProfileCount)",
                        systemImage: "checkmark.shield.fill",
                        tint: .blue
                    )
                }

                if report.findings.isEmpty {
                    Label(store.text(.noBottleHealthIssues), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.text(.latestBottleHealthFindings))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        ForEach(report.findings.prefix(4)) { finding in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: finding.severity))
                                    .foregroundStyle(color(for: finding.severity))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(finding.title)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Text(finding.bottleId)
                                            .font(.caption2)
                                            .foregroundStyle(Color.macWinReadableSecondaryText)
                                            .lineLimit(1)
                                    }
                                    Text(finding.recommendedAction)
                                        .font(.caption)
                                        .foregroundStyle(Color.macWinReadableSecondaryText)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }

    private var healthIcon: String {
        if report.actionRequiredBottleCount > 0 {
            return "exclamationmark.octagon.fill"
        }
        if report.warningBottleCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.seal.fill"
    }

    private var healthColor: Color {
        if report.actionRequiredBottleCount > 0 {
            return .red
        }
        if report.warningBottleCount > 0 {
            return .orange
        }
        return .green
    }

    private func icon(for severity: BottleHealthSeverity) -> String {
        switch severity {
        case .high:
            "exclamationmark.octagon.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .info:
            "info.circle.fill"
        }
    }

    private func color(for severity: BottleHealthSeverity) -> Color {
        switch severity {
        case .high:
            .red
        case .warning:
            .orange
        case .info:
            .blue
        }
    }
}

struct RuntimeProcessSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private var report: RuntimeProcessAuditReport {
        store.runtimeProcessAuditReport
    }

    private let metricColumns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.runtimeProcesses)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: report.findings.isEmpty ? "point.3.connected.trianglepath.dotted" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.findings.isEmpty ? .blue : .orange)
                    Text(store.text(
                        .runtimeProcessesSummary,
                        report.observedProcessCount,
                        report.auditedProcessCount,
                        report.staleRenderingProcessCount
                    ))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        store.refreshRuntimeProcesses()
                    } label: {
                        Label(store.text(.refreshRuntimeProcesses), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    Button {
                        store.exportRuntimeProcessesCSV()
                    } label: {
                        Label(store.text(.exportRuntimeProcessesCSV), systemImage: "tablecells")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    Button {
                        store.exportRuntimeProcessSnapshot()
                    } label: {
                        Label(store.text(.exportRuntimeSnapshot), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    Button(role: .destructive) {
                        store.terminateWineVirtualDesktopProcesses()
                    } label: {
                        Label(store.text(.stopWineVirtualDesktops), systemImage: "rectangle.badge.xmark")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .disabled(!report.entries.contains { $0.isWineVirtualDesktop || $0.isWineDeviceService })
                    Button(role: .destructive) {
                        store.terminateDetachedWineSystemProcesses()
                    } label: {
                        Label(store.text(.stopDetachedWineSystemProcesses), systemImage: "eraser.fill")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .disabled(report.detachedWineSystemEntries.isEmpty)
                    Button(role: .destructive) {
                        store.terminateAllRuntimeProcesses()
                    } label: {
                        Label(store.text(.stopAllRuntimeProcesses), systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .disabled(report.entries.isEmpty)
                }

                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                    SoftwarePlanMetric(
                        title: store.text(.runningWindowsProcesses),
                        value: "\(report.auditedProcessCount)",
                        systemImage: "terminal.fill",
                        tint: .blue
                    )
                    SoftwarePlanMetric(
                        title: store.text(.detachedWineSystemProcesses),
                        value: "\(report.detachedWineSystemEntries.count)",
                        systemImage: "link.badge.plus",
                        tint: report.detachedWineSystemEntries.isEmpty ? .green : .red
                    )
                    SoftwarePlanMetric(
                        title: store.text(.staleRuntimeProcesses),
                        value: "\(report.staleRenderingProcessCount)",
                        systemImage: "text.badge.xmark",
                        tint: report.staleRenderingProcessCount > 0 ? .red : .green
                    )
                    SoftwarePlanMetric(
                        title: store.text(.runtimeFindings),
                        value: "\(report.findings.count)",
                        systemImage: "exclamationmark.bubble.fill",
                        tint: report.findings.isEmpty ? .green : .orange
                    )
                }

                if report.entries.isEmpty {
                    Label(store.text(.noRuntimeProcesses), systemImage: "checkmark.circle")
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .font(.caption)
                } else {
                    Divider()
                    if !report.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.text(.latestRuntimeFindings))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                            ForEach(report.findings.prefix(3), id: \.id) { finding in
                                RuntimeProcessFindingRow(finding: finding)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.text(.runningWindowsProcesses))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        ForEach(report.entries.prefix(6), id: \.processIdentifier) { entry in
                            RuntimeProcessEntryRow(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

struct RuntimeProcessFindingRow: View {
    @EnvironmentObject private var store: MacWinStore
    var finding: RuntimeProcessFinding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(finding.affectedProcessIdentifiers.map(String.init).joined(separator: ", "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(1)
                }
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)
                if !finding.flags.isEmpty {
                    Text(finding.flags.prefix(6).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var severityIcon: String {
        finding.severity == "high" ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var severityColor: Color {
        finding.severity == "high" ? .red : .orange
    }
}

struct RuntimeProcessEntryRow: View {
    @EnvironmentObject private var store: MacWinStore
    var entry: RuntimeProcessEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.staleRenderingFlags.isEmpty ? iconName : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(entry.staleRenderingFlags.isEmpty ? tint : .red)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.executableName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(kindText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Text("\(store.text(.pid)) \(entry.processIdentifier)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    Spacer(minLength: 0)
                }
                if !entry.staleRenderingFlags.isEmpty {
                    Text(entry.staleRenderingFlags.prefix(6).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if let prefixName = entry.winePrefixDisplayName {
                    Text(store.text(.runtimeProcessContext, prefixName, entry.parentProcessIdentifier.map(String.init) ?? "-"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(entry.isDetachedWineSystemProcess ? .orange : .secondary)
                        .lineLimit(1)
                }
                Text(entry.commandPreview)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Button {
                store.terminateRuntimeProcess(entry)
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .help(store.text(.stopRuntimeProcess))
        }
    }

    private var kindText: String {
        switch entry.kind {
        case .hoYoPlay:
            "HoYoPlay"
        case .steam:
            "Steam"
        case .lenovoAppStore:
            store.language == .zhHans ? "联想应用商店" : "Lenovo App Store"
        case .windowsExecutable:
            store.language == .zhHans ? "Windows 程序" : "Windows EXE"
        case .wineHost:
            "Wine"
        }
    }

    private var iconName: String {
        switch entry.kind {
        case .hoYoPlay, .steam, .lenovoAppStore:
            "play.square.fill"
        case .windowsExecutable:
            "app.fill"
        case .wineHost:
            "gearshape.2.fill"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .hoYoPlay:
            .cyan
        case .steam:
            .blue
        case .lenovoAppStore:
            .green
        case .windowsExecutable:
            .mint
        case .wineHost:
            .secondary
        }
    }
}

struct TestCoverageSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private var report: TestCoverageReport {
        store.testCoverageReport
    }

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.testCoverage)) {
            if report.categories.isEmpty {
                Label(store.text(.noTestCoverage), systemImage: "clock.badge.questionmark")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: healthIcon)
                            .foregroundStyle(healthColor)
                        Text(store.text(
                            .testCoverageSummary,
                            report.presentExecutableCount,
                            report.requiredExecutableCount,
                            report.passedAssetCount,
                            report.unverifiedAssetCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.exportTestSessionArchive()
                        } label: {
                            Label(store.text(.exportTestSessionArchive), systemImage: "archivebox")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        Button {
                            store.exportLogIssueReport()
                        } label: {
                            Label(store.text(.exportLogIssueReport), systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        Button {
                            store.exportTestRunHistoryCSV()
                        } label: {
                            Label(store.text(.exportTestRunHistoryCSV), systemImage: "tablecells")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        Button {
                            store.exportRecommendedProbeScript()
                        } label: {
                            Label(store.text(.exportRecommendedProbeScript), systemImage: "terminal")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.coveragePassed),
                            value: "\(report.passedAssetCount)",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.coverageFailed),
                            value: "\(report.failedAssetCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: .red
                        )
                        SoftwarePlanMetric(
                            title: store.text(.coverageTimedOut),
                            value: "\(report.timedOutAssetCount)",
                            systemImage: "timer",
                            tint: .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.coverageUnverified),
                            value: "\(report.unverifiedAssetCount)",
                            systemImage: "questionmark.circle.fill",
                            tint: .secondary
                        )
                        SoftwarePlanMetric(
                            title: store.text(.coverageMissing),
                            value: "\(report.missingRequiredExecutableCount)",
                            systemImage: "tray.and.arrow.down.fill",
                            tint: .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.verifiedCategories),
                            value: "\(report.verifiedCategoryCount)/\(report.readyCategoryCount)",
                            systemImage: "list.bullet.rectangle.portrait.fill",
                            tint: .blue
                        )
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.categories, id: \.category.rawValue) { category in
                            TestCoverageCategoryRow(category: category)
                        }
                    }
                }
            }
        }
    }

    private var healthIcon: String {
        if report.failedAssetCount > 0 || report.timedOutAssetCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        if report.unverifiedAssetCount > 0 || report.missingRequiredExecutableCount > 0 {
            return "clock.badge.questionmark.fill"
        }
        return "checkmark.seal.fill"
    }

    private var healthColor: Color {
        if report.failedAssetCount > 0 || report.timedOutAssetCount > 0 {
            return .orange
        }
        if report.unverifiedAssetCount > 0 || report.missingRequiredExecutableCount > 0 {
            return .blue
        }
        return .green
    }
}

struct TestExecutionPlanSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private var plan: TestExecutionPlan? {
        store.testExecutionPlanReport
    }

    private var runnableAssetIds: [String] {
        orderedUnique((plan?.items ?? []).map(\.assetId)).filter { store.canRunProbe(assetId: $0) }
    }

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.testExecutionPlan)) {
            if let plan {
                if plan.items.isEmpty {
                    Label(store.text(.noTestExecutionPlan), systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: plan.requiredCount > 0 ? "exclamationmark.triangle.fill" : "play.circle.fill")
                                .foregroundStyle(plan.requiredCount > 0 ? .orange : .blue)
                            Text(store.text(
                                .testExecutionPlanSummary,
                                plan.itemCount,
                                plan.requiredCount,
                                plan.highPriorityCount
                            ))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                store.exportTestExecutionPlanCSV()
                            } label: {
                                Label(store.text(.exportTestExecutionPlanCSV), systemImage: "tablecells")
                            }
                            .controlSize(.small)
                            Button {
                                Task { await store.runProbes(assetIds: runnableAssetIds) }
                            } label: {
                                Label(store.text(.runRecommendedProbes), systemImage: "play.circle.fill")
                            }
                            .controlSize(.small)
                            .disabled(runnableAssetIds.isEmpty)
                            .help(store.text(.runRecommendedProbes))
                        }

                        LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                            SoftwarePlanMetric(
                                title: store.text(.requiredTests),
                                value: "\(plan.requiredCount)",
                                systemImage: "tray.and.arrow.down.fill",
                                tint: .orange
                            )
                            SoftwarePlanMetric(
                                title: store.text(.highPriorityTests),
                                value: "\(plan.highPriorityCount)",
                                systemImage: "exclamationmark.circle.fill",
                                tint: .red
                            )
                            SoftwarePlanMetric(
                                title: store.text(.coverageFailed),
                                value: "\(plan.failedCount)",
                                systemImage: "xmark.octagon.fill",
                                tint: .red
                            )
                            SoftwarePlanMetric(
                                title: store.text(.coverageTimedOut),
                                value: "\(plan.timedOutCount)",
                                systemImage: "timer",
                                tint: .orange
                            )
                            SoftwarePlanMetric(
                                title: store.text(.coverageUnverified),
                                value: "\(plan.unverifiedCount)",
                                systemImage: "questionmark.circle.fill",
                                tint: .secondary
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(plan.items.prefix(8))) { item in
                                TestExecutionPlanItemRow(item: item)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.noTestExecutionPlan), systemImage: "checkmark.seal")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
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
}

struct TestExecutionPlanItemRow: View {
    @EnvironmentObject private var store: MacWinStore
    var item: TestExecutionPlanItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(AppText.testExecutionPriority(item.priority, language: store.language))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(reasonSummary)
                    .font(.caption2)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(AppText.diagnosticCategory(item.category, language: store.language))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.macWinReadableSecondaryText)
                .lineLimit(1)
            Button {
                Task { await store.runProbe(assetId: item.assetId) }
            } label: {
                Image(systemName: "play.circle.fill")
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .foregroundStyle(store.canRunProbe(assetId: item.assetId) ? Color.accentColor : Color.macWinReadableSecondaryText)
            .disabled(!store.canRunProbe(assetId: item.assetId))
            .help(store.text(.runProbeSuite))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var reasonSummary: String {
        item.reasons
            .map { AppText.testExecutionReason($0, language: store.language) }
            .joined(separator: " · ")
    }

    private var icon: String {
        if item.reasons.contains(.missingRequiredAsset) || item.reasons.contains(.missingRunner) {
            return "tray.and.arrow.down.fill"
        }
        if item.reasons.contains(.failed) {
            return "xmark.octagon.fill"
        }
        if item.reasons.contains(.timedOut) {
            return "timer"
        }
        if item.reasons.contains(.neverRun) || item.reasons.contains(.missingExit) {
            return "questionmark.circle.fill"
        }
        return "clock.badge.questionmark.fill"
    }

    private var tint: Color {
        switch item.priority {
        case .required:
            .orange
        case .high:
            .red
        case .normal:
            .blue
        case .optional:
            .secondary
        }
    }
}

struct TestCoverageCategoryRow: View {
    @EnvironmentObject private var store: MacWinStore
    var category: TestCoverageCategoryReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: categoryIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(categoryColor)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppText.diagnosticCategory(category.category, language: store.language))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(categorySummary)
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !actionableAssetIds.isEmpty {
                    Button {
                        Task { await store.runProbes(assetIds: actionableAssetIds) }
                    } label: {
                        Label(store.text(.runCoverageProbes), systemImage: "play.circle.fill")
                    }
                    .controlSize(.small)
                    .disabled(actionableAssetIds.allSatisfy { !store.canRunProbe(assetId: $0) })
                    .help(store.text(.runCoverageProbes))
                }
                if let latestRunAt = category.latestRunAt {
                    Text(latestRunAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if !category.latestRuns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.text(.latestRuns))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    ForEach(Array(category.latestRuns.prefix(3)), id: \.assetId) { run in
                        TestCoverageRunRow(run: run)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var categorySummary: String {
        var parts = [
            "\(store.text(.coveragePassed)) \(category.passedAssetIds.count)/\(category.requiredAssetCount)"
        ]
        if !category.missingRequiredAssetIds.isEmpty {
            parts.append("\(store.text(.coverageMissing)) \(category.missingRequiredAssetIds.count)")
        }
        if !category.failedAssetIds.isEmpty {
            parts.append("\(store.text(.coverageFailed)) \(category.failedAssetIds.count)")
        }
        if !category.timedOutAssetIds.isEmpty {
            parts.append("\(store.text(.coverageTimedOut)) \(category.timedOutAssetIds.count)")
        }
        if !category.unverifiedAssetIds.isEmpty {
            parts.append("\(store.text(.coverageUnverified)) \(category.unverifiedAssetIds.count)")
        }
        return parts.joined(separator: " · ")
    }

    private var actionableAssetIds: [String] {
        orderedUnique(category.failedAssetIds + category.timedOutAssetIds + category.unverifiedAssetIds)
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

    private var categoryIcon: String {
        if !category.failedAssetIds.isEmpty || !category.timedOutAssetIds.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        if !category.missingRequiredAssetIds.isEmpty || !category.unverifiedAssetIds.isEmpty {
            return "clock.badge.questionmark.fill"
        }
        return "checkmark.circle.fill"
    }

    private var categoryColor: Color {
        if !category.failedAssetIds.isEmpty || !category.timedOutAssetIds.isEmpty {
            return .orange
        }
        if !category.missingRequiredAssetIds.isEmpty || !category.unverifiedAssetIds.isEmpty {
            return .blue
        }
        return .green
    }
}

struct TestCoverageRunRow: View {
    @EnvironmentObject private var store: MacWinStore
    var run: TestCoverageRunSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: outcomeIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(outcomeColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(run.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(AppText.testRunOutcome(run.outcome, language: store.language))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(outcomeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(outcomeColor.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                    Text(run.modifiedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(run.summary)
                    .font(.caption2)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
            }
            Button {
                Task { await store.runProbe(assetId: run.assetId) }
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .disabled(!store.canRunProbe(assetId: run.assetId))
            .help(store.text(.rerunProbe))
            Button {
                store.openTestRunLog(run)
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .help(store.text(.openLogFile))
            Button {
                store.revealTestRunLog(run)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .help(store.text(.revealInFinder))
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var outcomeIcon: String {
        switch run.outcome {
        case .passed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        case .timedOut:
            "timer"
        case .missingExit, .unknown:
            "questionmark.circle.fill"
        }
    }

    private var outcomeColor: Color {
        switch run.outcome {
        case .passed:
            .green
        case .failed:
            .red
        case .timedOut:
            .orange
        case .missingExit, .unknown:
            .secondary
        }
    }
}

struct InstallerAssetSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.installerAssets)) {
            if let report = store.installerAssetReport, report.recipeCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    let actions = installerActions(in: report)
                    let preparation = store.installerPreparationReport
                    HStack(spacing: 10) {
                        Image(systemName: report.hashMismatchCount > 0 ? "exclamationmark.triangle.fill" : "tray.and.arrow.down.fill")
                            .foregroundStyle(report.hashMismatchCount > 0 ? .red : .blue)
                        Text(store.text(
                            .installerAssetsSummary,
                            report.downloadableRecipeCount,
                            report.cachedRecipeCount,
                            report.missingDownloadCount,
                            report.hashMismatchCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if !actions.isEmpty {
                            Button {
                                Task { await store.downloadInstallers(recipeIds: actions.map(\.recipeId)) }
                            } label: {
                                Label(store.text(.downloadInstallerBatch), systemImage: "arrow.down.circle.fill")
                            }
                            .controlSize(.small)
                        }
                        Button {
                            store.openDownloads()
                        } label: {
                            Label(store.text(.openDownloads), systemImage: "folder")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportInstallerDownloadScript()
                        } label: {
                            Label(store.text(.exportInstallerDownloadScript), systemImage: "terminal")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportInstallerAssetCSV()
                        } label: {
                            Label(store.text(.exportInstallerAssetCSV), systemImage: "tablecells")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportInstallerPreparationCSV()
                        } label: {
                            Label(store.text(.exportInstallerPreparationCSV), systemImage: "checklist")
                        }
                        .controlSize(.small)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.downloadableInstallers),
                            value: "\(report.downloadableRecipeCount)",
                            systemImage: "arrow.down.circle.fill",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: store.text(.installerCached),
                            value: "\(report.cachedRecipeCount)",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.installerMissing),
                            value: "\(report.missingDownloadCount)",
                            systemImage: "tray.and.arrow.down.fill",
                            tint: .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.installerHashMismatchCount),
                            value: "\(report.hashMismatchCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: .red
                        )
                        SoftwarePlanMetric(
                            title: store.text(.installerPreparation),
                            value: "\(preparation.actionCount)",
                            systemImage: "checklist",
                            tint: preparation.criticalCount > 0 ? .red : preparation.warningCount > 0 ? .orange : .green
                        )
                    }

                    if preparation.actions.isEmpty {
                        Label(store.text(.noInstallerActions), systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(store.text(.installerPreparation))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.macWinReadableSecondaryText)
                                Text(store.text(
                                    .installerPreparationSummary,
                                    preparation.actionCount,
                                    preparation.criticalCount,
                                    preparation.warningCount
                                ))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            ForEach(preparation.actions.prefix(6)) { action in
                                InstallerPreparationActionRow(action: action)
                            }
                        }
                    }

                    if !report.orphanedDownloads.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(store.text(.localInstallerCandidates))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.macWinReadableSecondaryText)
                                Text(store.text(.localInstallerCandidatesSummary, report.orphanedFileCount))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            ForEach(report.orphanedDownloads.prefix(6)) { item in
                                LocalInstallerCandidateRow(item: item)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.softwareNoCatalog), systemImage: "shippingbox")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }

    private func installerActions(in report: InstallerAssetReport) -> [RecipeInstallerAssetStatus] {
        report.recipes.filter { item in
            item.installerMode == .download && (!item.cachedExists || item.hashStatus == .mismatch)
        }
        .sorted { lhs, rhs in
            if lhs.hashStatus != rhs.hashStatus {
                return lhs.hashStatus == .mismatch
            }
            return lhs.recipeName.localizedCaseInsensitiveCompare(rhs.recipeName) == .orderedAscending
        }
    }
}

struct InstallerPreparationActionRow: View {
    @EnvironmentObject private var store: MacWinStore
    var action: InstallerPreparationAction

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(action.recipeName ?? action.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(kindText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Text(severityText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    Spacer(minLength: 0)
                }

                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)

                Text(action.sourceURL ?? action.cachedPath ?? action.fileName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if canDownload, let recipeId = action.recipeId {
                Button {
                    Task { await store.downloadInstaller(recipeId: recipeId) }
                } label: {
                    Label(store.text(.downloadInstaller), systemImage: "arrow.down.circle.fill")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canDownload: Bool {
        action.kind == .downloadMissing || action.kind == .redownloadHashMismatch
    }

    private var kindText: String {
        switch action.kind {
        case .redownloadHashMismatch:
            store.text(.installerPreparationHashMismatch)
        case .downloadMissing:
            store.text(.installerPreparationDownloadMissing)
        case .addExpectedHash:
            store.text(.installerPreparationAddExpectedHash)
        case .useWoW64Engine:
            store.text(.installerPreparationUseWoW64)
        case .reviewOrphanedDownload:
            store.text(.installerPreparationReviewOrphaned)
        }
    }

    private var severityText: String {
        switch action.severity {
        case .critical:
            store.text(.installerPreparationCritical)
        case .warning:
            store.text(.installerPreparationWarning)
        case .info:
            store.text(.installerPreparationInfo)
        }
    }

    private var iconName: String {
        switch action.severity {
        case .critical:
            "xmark.octagon.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .info:
            "info.circle.fill"
        }
    }

    private var tint: Color {
        switch action.severity {
        case .critical:
            .red
        case .warning:
            .orange
        case .info:
            .blue
        }
    }
}

struct InstallerAssetRow: View {
    @EnvironmentObject private var store: MacWinStore
    var item: RecipeInstallerAssetStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.recipeName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    if item.requiresWin32Installer {
                        Text(store.text(.requiresWin32))
                            .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.10), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }

                Text(item.fileName ?? item.sourceURL ?? item.recipeId)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)

                if let sourceURL = item.sourceURL {
                    Text(sourceURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Button {
                Task { await store.downloadInstaller(recipeId: item.recipeId) }
            } label: {
                Label(store.text(.downloadInstaller), systemImage: "arrow.down.circle.fill")
            }
            .controlSize(.small)
            .disabled(!canDownload)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        switch item.hashStatus {
        case .mismatch:
            store.text(.installerHashMismatchCount)
        case .missing:
            store.text(.installerMissing)
        case .match:
            store.text(.installerCached)
        case .notApplicable, .notExpected:
            AppText.softwareTestPlanState(.readyToInstall, language: store.language)
        }
    }

    private var iconName: String {
        switch item.hashStatus {
        case .mismatch:
            "xmark.octagon.fill"
        case .missing:
            "tray.and.arrow.down.fill"
        case .match:
            "checkmark.circle.fill"
        case .notApplicable, .notExpected:
            "questionmark.circle"
        }
    }

    private var tint: Color {
        switch item.hashStatus {
        case .mismatch:
            .red
        case .missing:
            .orange
        case .match:
            .green
        case .notApplicable, .notExpected:
            .secondary
        }
    }

    private var canDownload: Bool {
        item.installerMode == .download && item.sourceURL != nil && item.cachedPath != nil
    }
}

struct LocalInstallerCandidateRow: View {
    @EnvironmentObject private var store: MacWinStore
    var item: DownloadCacheFileStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.architecture?.is32Bit == true ? "square.stack.3d.down.forward.fill" : "doc.badge.gearshape")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.architecture?.is32Bit == true ? .orange : .blue)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(architectureText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.architecture?.is32Bit == true ? .orange : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    Spacer(minLength: 0)
                }

                Text("\(byteCountText) · \(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)

                if let sha256 = item.sha256 {
                    Text(sha256)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text(item.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Button {
                Task { await store.installCachedInstallerCandidate(item) }
            } label: {
                Label(store.text(.installLocalCandidate), systemImage: "play.circle.fill")
            }
            .controlSize(.small)
            .disabled(!canInstall)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .help(store.text(.revealInFinder))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canInstall: Bool {
        item.pathExtension == "exe" || item.pathExtension == "msi"
    }

    private var architectureText: String {
        guard let architecture = item.architecture else {
            return store.text(.unknownArchitecture)
        }
        return architecture.rawValue
    }

    private var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
    }
}

struct InstallerDownloadHistorySection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.installerDownloadHistory)) {
            if let report = store.installerDownloadHistoryReport, report.totalRecordCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.failedCount > 0 || report.hashMismatchCount > 0 ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                            .foregroundStyle(report.failedCount > 0 || report.hashMismatchCount > 0 ? .orange : .blue)
                        Text(store.text(
                            .installerDownloadHistorySummary,
                            report.totalRecordCount,
                            report.downloadedCount,
                            report.cachedCount,
                            report.failedCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.exportInstallerDownloadHistoryCSV()
                        } label: {
                            Label(store.text(.exportInstallerDownloadHistoryCSV), systemImage: "tablecells")
                        }
                        .controlSize(.small)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.installerDownloadRecords),
                            value: "\(report.totalRecordCount)",
                            systemImage: "list.bullet.rectangle",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: store.text(.installerCached),
                            value: "\(report.cachedCount)",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.installerDownloadFailures),
                            value: "\(report.failedCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: .red
                        )
                        SoftwarePlanMetric(
                            title: store.text(.installerDownloadHashMismatches),
                            value: "\(report.hashMismatchCount)",
                            systemImage: "number.square.fill",
                            tint: .orange
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.records.prefix(6)) { record in
                            InstallerDownloadHistoryRow(record: record)
                        }
                    }
                }
            } else {
                Label(store.text(.noInstallerDownloadHistory), systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }
}

struct InstallerDownloadHistoryRow: View {
    @EnvironmentObject private var store: MacWinStore
    var record: InstallerDownloadRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(record.recipeName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(stateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                    Text(record.startedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Text(record.fileName)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)

                Text(record.sourceURL)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let errorMessage = record.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let actual = record.actualSha256, record.state == .hashMismatch {
                    Text(actual)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            if FileManager.default.fileExists(atPath: record.destinationPath) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.destinationPath)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.revealInFinder))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stateText: String {
        switch record.state {
        case .cached:
            store.text(.installerCached)
        case .downloaded:
            store.language == .zhHans ? "已下载" : "Downloaded"
        case .hashMismatch:
            store.text(.installerDownloadHashMismatches)
        case .failed:
            store.text(.installerDownloadFailures)
        }
    }

    private var iconName: String {
        switch record.state {
        case .cached:
            "checkmark.circle.fill"
        case .downloaded:
            "arrow.down.circle.fill"
        case .hashMismatch:
            "number.square.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch record.state {
        case .cached:
            .green
        case .downloaded:
            .blue
        case .hashMismatch:
            .orange
        case .failed:
            .red
        }
    }
}

struct SoftwareCollectionSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        let report = store.softwareCollectionReport
        SectionPanel(title: store.text(.softwareCollection)) {
            if report.recipeCount > 0 || report.missingRecipeCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.actionRequiredCount > 0 ? "shippingbox.and.arrow.down.fill" : "checkmark.seal.fill")
                            .foregroundStyle(report.actionRequiredCount > 0 ? .orange : .green)
                        Text(store.text(
                            .softwareCollectionSummary,
                            report.collectionCount,
                            report.recipeCount,
                            report.cachedInstallerCount,
                            report.missingInstallerCount,
                            report.verifiedRecipeCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            Task { await store.downloadMissingSoftwareCollectionInstallers() }
                        } label: {
                            Label(store.text(.softwareCollectionDownloadMissing), systemImage: "arrow.down.circle.fill")
                        }
                        .controlSize(.small)
                        .disabled(missingDownloadEntries.isEmpty)
                        Button {
                            store.exportSoftwareCollectionCSV()
                        } label: {
                            Label(store.text(.exportSoftwareCollectionCSV), systemImage: "tablecells")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportSoftwareCollectionDownloadScript()
                        } label: {
                            Label(store.text(.exportSoftwareCollectionDownloadScript), systemImage: "terminal")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportSoftwareCollectionBundle()
                        } label: {
                            Label(store.text(.exportSoftwareCollectionBundle), systemImage: "shippingbox")
                        }
                        .controlSize(.small)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.softwareCollectionCoverage),
                            value: "\(report.collectionCount)",
                            systemImage: "square.grid.2x2.fill",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareCollectionMissingRecipes),
                            value: "\(report.missingRecipeCount)",
                            systemImage: "doc.badge.questionmark",
                            tint: report.missingRecipeCount > 0 ? .orange : .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareCollectionMissingInstallers),
                            value: "\(report.missingInstallerCount)",
                            systemImage: "tray.and.arrow.down.fill",
                            tint: report.missingInstallerCount > 0 ? .orange : .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareCollectionActionRequired),
                            value: "\(report.actionRequiredCount)",
                            systemImage: "exclamationmark.circle.fill",
                            tint: report.actionRequiredCount > 0 ? .orange : .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareVerified),
                            value: "\(report.verifiedRecipeCount)",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.collections) { collection in
                            SoftwareCollectionGroupRow(
                                collection: collection,
                                entries: entries(in: collection),
                                missingRecipeIds: missingRecipeIds(in: collection)
                            )
                        }
                    }

                    if !actionEntries.isEmpty {
                        Divider()
                        Text(store.text(.softwareNextActions))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(actionEntries.prefix(8)) { entry in
                                SoftwareCollectionEntryRow(entry: entry)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.noSoftwareCollection), systemImage: "shippingbox")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }

    private var actionEntries: [SoftwareCollectionEntry] {
        store.softwareCollectionReport.entries
            .filter { entry in
                entry.softwareState != .verified && entry.softwareState != .disabled
            }
            .sorted { lhs, rhs in
                if lhs.cachedInstallerExists != rhs.cachedInstallerExists {
                    return !lhs.cachedInstallerExists
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var missingDownloadEntries: [SoftwareCollectionEntry] {
        store.softwareCollectionReport.entries.filter { entry in
            entry.installerMode == .download
                && !entry.cachedInstallerExists
                && entry.installerSourceURL?.isEmpty == false
                && entry.installerFileName?.isEmpty == false
        }
    }

    private func entries(in collection: SoftwareCollectionDefinition) -> [SoftwareCollectionEntry] {
        store.softwareCollectionReport.entries.filter { $0.collectionIds.contains(collection.id) }
    }

    private func missingRecipeIds(in collection: SoftwareCollectionDefinition) -> [String] {
        let missing = Set(store.softwareCollectionReport.missingRecipeIds)
        return collection.requiredRecipeIds.filter { missing.contains($0) }
    }
}

struct SoftwareSampleCatalogSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        let report = store.softwareSampleCatalogReport
        SectionPanel(title: store.text(.softwareSampleCatalog)) {
            if report.sampleCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.warningCount > 0 ? "shippingbox.and.arrow.down.fill" : "checkmark.seal.fill")
                            .foregroundStyle(report.warningCount > 0 ? .orange : .green)
                        Text(store.text(
                            .softwareSampleCatalogSummary,
                            report.sampleCount,
                            report.catalogBackedCount,
                            report.localInstallerCount,
                            report.warningCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.exportSoftwareSampleCatalogCSV()
                        } label: {
                            Label(store.text(.exportSoftwareSampleCatalogCSV), systemImage: "tablecells")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportSoftwareSampleCatalogRunbook()
                        } label: {
                            Label(store.text(.exportSoftwareSampleCatalogRunbook), systemImage: "doc.text.magnifyingglass")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportSoftwareSamplePreparationSnapshot()
                        } label: {
                            Label(store.text(.exportSoftwareSamplePreparationSnapshot), systemImage: "shippingbox.and.arrow.down")
                        }
                        .controlSize(.small)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.softwareCollectionCoverage),
                            value: "\(report.sampleCount)",
                            systemImage: "square.grid.2x2.fill",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareSampleCatalogSignedRecipes),
                            value: "\(report.catalogBackedCount)",
                            systemImage: "checkmark.seal.fill",
                            tint: report.catalogBackedCount > 0 ? .green : .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareSampleCatalogLocalInstallers),
                            value: "\(report.localInstallerCount)",
                            systemImage: "tray.and.arrow.down.fill",
                            tint: .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareSampleCatalogWarnings),
                            value: "\(report.warningCount)",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: report.warningCount > 0 ? .yellow : .green
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(prioritySamples(report.samples).prefix(6)) { sample in
                            SoftwareSampleCatalogRow(sample: sample)
                        }
                    }
                }
            } else {
                Label(store.text(.noSoftwareSampleCatalog), systemImage: "shippingbox")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }

    private func prioritySamples(_ samples: [SoftwareSampleProfile]) -> [SoftwareSampleProfile] {
        samples.sorted { lhs, rhs in
            if lhs.catalogBacked != rhs.catalogBacked {
                return !lhs.catalogBacked
            }
            if lhs.installSource != rhs.installSource {
                return installSourceRank(lhs.installSource) < installSourceRank(rhs.installSource)
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func installSourceRank(_ source: SoftwareSampleInstallSource) -> Int {
        switch source {
        case .localInstaller: 0
        case .externalExecutable: 1
        case .alreadyInstalled: 2
        case .signedRecipe: 3
        }
    }
}

struct SoftwareSampleCatalogRow: View {
    @EnvironmentObject private var store: MacWinStore
    var sample: SoftwareSampleProfile

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(sample.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(sourceText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }
                Text("\(sample.publisher) · \(sample.category)")
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let recipeId = sample.catalogRecipeId {
                Text(recipeId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(sample.catalogBacked ? .green : .orange)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((sample.catalogBacked ? Color.green : Color.orange).opacity(0.10), in: Capsule())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sourceText: String {
        switch sample.installSource {
        case .signedRecipe:
            return store.language == .zhHans ? "签名配方" : "Signed"
        case .localInstaller:
            return store.language == .zhHans ? "本地安装器" : "Local"
        case .alreadyInstalled:
            return store.language == .zhHans ? "已安装" : "Installed"
        case .externalExecutable:
            return store.language == .zhHans ? "外部 EXE" : "External"
        }
    }

    private var detailText: String {
        if !sample.recommendedProbeIds.isEmpty {
            return "\(store.text(.recommendedProbes)): \(sample.recommendedProbeIds.joined(separator: ", "))"
        }
        if !sample.expectedIssueIds.isEmpty {
            return sample.expectedIssueIds.joined(separator: ", ")
        }
        return sample.purpose
    }

    private var iconName: String {
        switch sample.installSource {
        case .signedRecipe:
            sample.catalogBacked ? "checkmark.seal.fill" : "doc.badge.questionmark"
        case .localInstaller:
            "tray.and.arrow.down.fill"
        case .alreadyInstalled:
            "app.badge.checkmark"
        case .externalExecutable:
            "doc.badge.gearshape"
        }
    }

    private var tint: Color {
        switch sample.installSource {
        case .signedRecipe:
            sample.catalogBacked ? .green : .orange
        case .localInstaller:
            .orange
        case .alreadyInstalled:
            .blue
        case .externalExecutable:
            .orange
        }
    }
}

struct SoftwareSampleLogCorrelationSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        let report = store.softwareSampleLogCorrelationReport
        SectionPanel(title: store.text(.softwareSampleLogCorrelation)) {
            if report.sampleCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.failedSampleCount > 0 ? "exclamationmark.triangle.fill" : "link.circle.fill")
                            .foregroundStyle(report.failedSampleCount > 0 ? .orange : .green)
                        Text(store.text(
                            .softwareSampleLogCorrelationSummary,
                            report.matchedSampleCount,
                            report.launchCount,
                            report.logCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.softwareSampleMatched),
                            value: "\(report.matchedSampleCount)",
                            systemImage: "link",
                            tint: report.matchedSampleCount > 0 ? .blue : .secondary
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareSampleFailed),
                            value: "\(report.failedSampleCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: report.failedSampleCount > 0 ? .red : .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareSampleAttention),
                            value: "\(report.attentionSampleCount)",
                            systemImage: "exclamationmark.circle.fill",
                            tint: report.attentionSampleCount > 0 ? .orange : .green
                        )
                    }

                    let matchedEntries = report.entries.filter { $0.launchCount > 0 || $0.logCount > 0 }
                    if matchedEntries.isEmpty {
                        Label(store.text(.noSoftwareSampleLogCorrelation), systemImage: "link.badge.plus")
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(matchedEntries.prefix(6)) { entry in
                                SoftwareSampleLogCorrelationRow(entry: entry)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.noSoftwareSampleLogCorrelation), systemImage: "link.badge.plus")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }
}

private struct RepresentativeAcceptanceSummary: View {
    @EnvironmentObject private var store: MacWinStore
    var report: RepresentativeSoftwareAcceptanceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.text(.representativeAcceptanceSummary, report.passedCount, report.targetCount, report.pendingCount))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.macWinReadableSecondaryText)
            ForEach(report.entries) { entry in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: entry.state))
                        .foregroundStyle(color(for: entry.state))
                        .frame(width: 18)
                    Text(entry.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.nextAction)
                        .font(.caption2)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(for state: RepresentativeAcceptanceState) -> String {
        switch state {
        case .passed: "checkmark.seal.fill"
        case .failed: "xmark.octagon.fill"
        case .needsFunctionalProof: "eye"
        case .needsInstall: "arrow.down.circle"
        case .needsLaunch: "play.circle"
        case .unavailable: "questionmark.circle"
        }
    }

    private func color(for state: RepresentativeAcceptanceState) -> Color {
        switch state {
        case .passed: .green
        case .failed: .red
        case .needsFunctionalProof, .needsInstall, .needsLaunch: .orange
        case .unavailable: .secondary
        }
    }
}

struct SoftwareSampleLogCorrelationRow: View {
    @EnvironmentObject private var store: MacWinStore
    var entry: SoftwareSampleLogCorrelationEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(entry.launchCount) / \(entry.logCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
                if !entry.recommendedProbeIds.isEmpty {
                    Text("\(store.text(.recommendedProbes)): \(entry.recommendedProbeIds.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        if entry.failedLogCount > 0 { return "xmark.octagon.fill" }
        if entry.attentionLogCount > 0 { return "exclamationmark.circle.fill" }
        return "link.circle.fill"
    }

    private var tint: Color {
        if entry.failedLogCount > 0 { return .red }
        if entry.attentionLogCount > 0 { return .orange }
        return .green
    }

    private var detailText: String {
        if let logName = entry.logNames.first {
            return "\(logName) · \(entry.sampleId)"
        }
        if let launchRecordId = entry.launchRecordIds.first {
            return "\(launchRecordId) · \(entry.sampleId)"
        }
        return entry.sampleId
    }
}

struct SoftwareCollectionAcceptanceSection: View {
    @EnvironmentObject private var store: MacWinStore

    private var report: SoftwareCollectionAcceptanceReport {
        store.softwareCollectionAcceptanceReport
    }

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.softwareCollectionAcceptance)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: stateIcon)
                        .foregroundStyle(stateColor)
                    Text(store.text(
                        .softwareCollectionAcceptanceSummary,
                        stateText,
                        report.actionCount,
                        report.blockerCount,
                        report.highPriorityCount
                    ))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        store.exportSoftwareCollectionAcceptanceRunbook()
                    } label: {
                        Label(store.text(.exportSoftwareCollectionAcceptanceRunbook), systemImage: "terminal")
                    }
                    .controlSize(.small)
                    Button {
                        store.exportSoftwareCollectionBundle()
                    } label: {
                        Label(store.text(.exportSoftwareCollectionBundle), systemImage: "shippingbox")
                    }
                    .controlSize(.small)
                }

                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                    SoftwarePlanMetric(
                        title: store.text(.softwareCollectionAcceptanceState),
                        value: stateText,
                        systemImage: stateIcon,
                        tint: stateColor
                    )
                    SoftwarePlanMetric(
                        title: store.text(.softwareCollectionAcceptanceBlockers),
                        value: "\(report.blockerCount)",
                        systemImage: "xmark.octagon.fill",
                        tint: report.blockerCount > 0 ? .red : .green
                    )
                    SoftwarePlanMetric(
                        title: store.text(.softwareCollectionAcceptanceHighPriority),
                        value: "\(report.highPriorityCount)",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: report.highPriorityCount > 0 ? .orange : .green
                    )
                    SoftwarePlanMetric(
                        title: store.text(.softwareCollectionAcceptanceWarnings),
                        value: "\(report.warningCount)",
                        systemImage: "exclamationmark.circle.fill",
                        tint: report.warningCount > 0 ? .yellow : .green
                    )
                }

                Divider()
                Text(store.text(.softwareCollectionAcceptanceActions))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.macWinReadableSecondaryText)

                if report.actions.isEmpty {
                    Label(store.text(.noSoftwareCollectionAcceptanceActions), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.actions.prefix(8)) { action in
                            SoftwareCollectionAcceptanceActionRow(action: action)
                        }
                    }
                }
            }
        }
    }

    private var stateText: String {
        switch report.state {
        case .verified:
            store.language == .zhHans ? "已验证" : "Verified"
        case .readyToRun:
            store.language == .zhHans ? "可运行" : "Ready"
        case .needsAction:
            store.language == .zhHans ? "需处理" : "Needs Action"
        case .blocked:
            store.language == .zhHans ? "阻塞" : "Blocked"
        }
    }

    private var stateIcon: String {
        switch report.state {
        case .verified:
            "checkmark.seal.fill"
        case .readyToRun:
            "play.circle.fill"
        case .needsAction:
            "exclamationmark.triangle.fill"
        case .blocked:
            "xmark.octagon.fill"
        }
    }

    private var stateColor: Color {
        switch report.state {
        case .verified:
            .green
        case .readyToRun:
            .blue
        case .needsAction:
            .orange
        case .blocked:
            .red
        }
    }
}

struct SoftwareCollectionAcceptanceActionRow: View {
    @EnvironmentObject private var store: MacWinStore
    var action: SoftwareCollectionAcceptanceAction

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(localizedTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(severityText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }
                Text(localizedDetail)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)
                if let relatedText {
                    Text(relatedText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if action.kind == .downloadInstaller, let recipeId = action.recipeId {
                Button {
                    Task { await store.downloadInstaller(recipeId: recipeId) }
                } label: {
                    Label(store.text(.downloadInstaller), systemImage: "arrow.down.circle.fill")
                }
                .controlSize(.small)
            } else if action.kind == .runProbe, let assetId = action.assetId {
                Button {
                    Task { await store.runProbe(assetId: assetId) }
                } label: {
                    Image(systemName: "play.circle.fill")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.runProbeSuite))
            } else if let path = action.relatedPath, !path.isEmpty {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.latestLog))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var localizedTitle: String {
        guard store.language == .zhHans else { return action.title }
        switch action.kind {
        case .addMissingRecipe:
            return "补充缺失配方 \(action.recipeId ?? "")"
        case .downloadInstaller:
            return "缓存安装器 \(action.recipeId ?? "")"
        case .redownloadHashMismatch:
            return "重新下载安装器 \(action.recipeId ?? "")"
        case .runSoftwareAction:
            return action.recipeId.map { "处理软件项 \($0)" } ?? "处理软件项"
        case .runProbe:
            return action.assetId.map { "运行探针 \($0)" } ?? "运行探针"
        case .reviewLogIssue:
            return action.logIssueId.map { "复查日志问题 \($0)" } ?? "复查日志问题"
        }
    }

    private var localizedDetail: String {
        guard store.language == .zhHans else { return action.detail }
        switch action.kind {
        case .addMissingRecipe:
            return "测试集合引用了签名市场中不存在的配方。"
        case .downloadInstaller:
            return "运行配方前需要先下载并校验安装器。"
        case .redownloadHashMismatch:
            return "缓存安装器的 SHA-256 与可信配方不一致，需要重新下载。"
        case .runSoftwareAction:
            return action.detail.isEmpty ? "按软件测试计划继续处理该项。" : action.detail
        case .runProbe:
            return "核心探针需要运行或复测：\(action.assetId ?? "")。"
        case .reviewLogIssue:
            return action.detail.isEmpty ? "最近日志中存在需要复查的问题。" : action.detail
        }
    }

    private var relatedText: String? {
        if let recipeId = action.recipeId {
            return "recipe: \(recipeId)"
        }
        if let assetId = action.assetId {
            return "asset: \(assetId)"
        }
        if let logIssueId = action.logIssueId {
            return "log: \(logIssueId)"
        }
        return action.relatedPath
    }

    private var severityText: String {
        switch action.severity {
        case .blocker:
            store.language == .zhHans ? "阻塞" : "Blocker"
        case .high:
            store.language == .zhHans ? "高" : "High"
        case .warning:
            store.language == .zhHans ? "警告" : "Warning"
        case .info:
            store.language == .zhHans ? "提示" : "Info"
        }
    }

    private var iconName: String {
        switch action.kind {
        case .addMissingRecipe:
            "doc.badge.plus"
        case .downloadInstaller:
            "arrow.down.circle.fill"
        case .redownloadHashMismatch:
            "arrow.clockwise.circle.fill"
        case .runSoftwareAction:
            "play.rectangle.fill"
        case .runProbe:
            "waveform.path.ecg"
        case .reviewLogIssue:
            "doc.text.magnifyingglass"
        }
    }

    private var tint: Color {
        switch action.severity {
        case .blocker:
            .red
        case .high:
            .orange
        case .warning:
            .yellow
        case .info:
            .blue
        }
    }
}

struct SoftwareCollectionGroupRow: View {
    @EnvironmentObject private var store: MacWinStore
    var collection: SoftwareCollectionDefinition
    var entries: [SoftwareCollectionEntry]
    var missingRecipeIds: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: missingRecipeIds.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(missingRecipeIds.isEmpty ? .green : .orange)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(localizedName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(entries.count)/\(collection.requiredRecipeIds.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    Spacer(minLength: 0)
                }
                Text(localizedPurpose)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)
                if !missingRecipeIds.isEmpty {
                    Text(missingRecipeIds.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var localizedName: String {
        guard store.language == .zhHans else { return collection.name }
        switch collection.id {
        case "baseline-utilities": return "基础工具"
        case "launcher-webview": return "启动器与 WebView"
        case "media-graphics": return "媒体与图形"
        case "diagnostics": return "MacWin 诊断"
        default: return collection.name
        }
    }

    private var localizedPurpose: String {
        guard store.language == .zhHans else { return collection.purpose }
        switch collection.id {
        case "baseline-utilities": return "覆盖文件对话框、菜单、Shell 集成和普通 Win32 窗口。"
        case "launcher-webview": return "覆盖 CEF、Chromium、Qt WebEngine、登录、焦点与文字渲染。"
        case "media-graphics": return "覆盖 GStreamer、GPU 合成、Vulkan、D3D 与媒体播放。"
        case "diagnostics": return "内置探针和核心能力套件，用于回归验证。"
        default: return collection.purpose
        }
    }
}

struct SoftwareCollectionEntryRow: View {
    @EnvironmentObject private var store: MacWinStore
    var entry: SoftwareCollectionEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(stateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }
                Text("\(entry.publisher) · \(AppText.category(entry.category, language: store.language))")
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if canDownload {
                Button {
                    Task { await store.downloadInstaller(recipeId: entry.recipeId) }
                } label: {
                    Label(store.text(.downloadInstaller), systemImage: "arrow.down.circle.fill")
                }
                .controlSize(.small)
            } else if let logPath = entry.latestLaunchLogPath, !logPath.isEmpty {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.latestLog))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var canDownload: Bool {
        entry.installerMode == .download
            && !entry.cachedInstallerExists
            && entry.installerSourceURL?.isEmpty == false
            && entry.installerFileName?.isEmpty == false
    }

    private var stateText: String {
        if let state = entry.softwareState {
            return state.rawValue
        }
        if !entry.readinessIssues.isEmpty {
            return entry.readinessIssues.map(\.rawValue).joined(separator: ", ")
        }
        return entry.installerMode.rawValue
    }

    private var detailText: String {
        if canDownload {
            return entry.installerFileName ?? entry.installerSourceURL ?? entry.recipeId
        }
        if !entry.recommendedProbeIds.isEmpty {
            return "\(store.text(.recommendedProbes)): \(entry.recommendedProbeIds.joined(separator: ", "))"
        }
        if let health = entry.latestLogHealth {
            return "\(store.text(.latestLog)): \(health.rawValue)"
        }
        return entry.recipeId
    }

    private var iconName: String {
        if entry.softwareState == .verified {
            return "checkmark.circle.fill"
        }
        if canDownload {
            return "tray.and.arrow.down.fill"
        }
        if entry.smokeSeverity == .failed || entry.smokeSeverity == .blocked {
            return "exclamationmark.triangle.fill"
        }
        return "circle.dashed"
    }

    private var tint: Color {
        if entry.softwareState == .verified {
            return .green
        }
        if canDownload {
            return .orange
        }
        if entry.smokeSeverity == .failed {
            return .red
        }
        if entry.smokeSeverity == .blocked {
            return .orange
        }
        return .secondary
    }
}

struct SoftwareTestPlanSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.softwareTestPlan)) {
            if let report = store.softwareTestPlanReport, report.recipeCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.failingCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(report.failingCount > 0 ? .orange : .green)
                        Text(store.text(.softwareTestPlanSummary, report.recipeCount, report.verifiedCount, report.reviewCount, report.failingCount))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.exportSoftwareTestPlanCSV()
                        } label: {
                            Label(store.text(.exportSoftwareTestPlanCSV), systemImage: "tablecells")
                        }
                        .controlSize(.small)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.softwareVerified),
                            value: "\(report.verifiedCount)",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareInstalled),
                            value: "\(report.installedCount)",
                            systemImage: "app.badge",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareReadyToInstall),
                            value: "\(report.readyToInstallCount)",
                            systemImage: "arrow.down.circle.fill",
                            tint: .cyan
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareNeedsReview),
                            value: "\(report.reviewCount)",
                            systemImage: "doc.text.magnifyingglass",
                            tint: .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.softwareFailing),
                            value: "\(report.failingCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: .red
                        )
                    }

                    Divider()

                    if actionEntries.isEmpty {
                        Label(store.text(.noSoftwareActions), systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    } else {
                        Text(store.text(.softwareNextActions))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(actionEntries.prefix(6)) { entry in
                                SoftwareTestPlanRow(entry: entry)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.softwareNoCatalog), systemImage: "shippingbox")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }

    private var actionEntries: [SoftwareTestPlanEntry] {
        guard let report = store.softwareTestPlanReport else { return [] }
        let entriesById = Dictionary(uniqueKeysWithValues: report.entries.map { ($0.recipeId, $0) })
        return report.nextActions.compactMap { entriesById[$0.recipeId] }
    }
}

struct SoftwareSmokeMatrixSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.softwareSmokeMatrix)) {
            let report = store.softwareSmokeMatrixReport
            if report.recipeCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.failedCount > 0 || report.blockedCount > 0 ? "checklist.unchecked" : "checklist.checked")
                            .foregroundStyle(report.failedCount > 0 || report.blockedCount > 0 ? .orange : .green)
                        Text(store.text(
                            .softwareSmokeMatrixSummary,
                            report.recipeCount,
                            report.blockedCount,
                            report.warningCount,
                            report.failedCount,
                            report.verifiedCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.exportSoftwareAdaptationRunbook()
                        } label: {
                            Label(store.text(.exportSoftwareAdaptationRunbook), systemImage: "doc.text.magnifyingglass")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportSoftwareAdaptationQueueCSV()
                        } label: {
                            Label(store.text(.exportSoftwareAdaptationQueueCSV), systemImage: "tablecells")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportSoftwareAdaptationProbeScript()
                        } label: {
                            Label(store.text(.exportSoftwareAdaptationProbeScript), systemImage: "terminal")
                        }
                        .controlSize(.small)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.smokeBlocked),
                            value: "\(report.blockedCount)",
                            systemImage: "hand.raised.fill",
                            tint: report.blockedCount > 0 ? .red : .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.smokeWarnings),
                            value: "\(report.warningCount)",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: report.warningCount > 0 ? .orange : .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.smokeFailures),
                            value: "\(report.failedCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: report.failedCount > 0 ? .red : .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.smokeVerified),
                            value: "\(report.verifiedCount)",
                            systemImage: "checkmark.seal.fill",
                            tint: .green
                        )
                    }

                    Divider()

                    if report.nextActions.isEmpty {
                        Label(store.text(.noSoftwareActions), systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    } else {
                        Text(store.text(.softwareNextActions))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(priorityRows(in: report).prefix(6)) { row in
                                SoftwareSmokeMatrixRowView(row: row)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.noSoftwareSmokeMatrix), systemImage: "checklist")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }

    private func priorityRows(in report: SoftwareSmokeMatrixReport) -> [SoftwareSmokeMatrixRow] {
        let rowsById = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.recipeId, $0) })
        let actionRows = report.nextActions.compactMap { rowsById[$0.recipeId] }
        if !actionRows.isEmpty {
            return actionRows
        }
        return report.rows.sorted { lhs, rhs in
            let lhsRank = smokeSeverityRank(lhs.highestSeverity)
            let rhsRank = smokeSeverityRank(rhs.highestSeverity)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.recipeId < rhs.recipeId
        }
    }
}

struct SoftwareSmokeMatrixRowView: View {
    @EnvironmentObject private var store: MacWinStore
    var row: SoftwareSmokeMatrixRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(AppText.softwareSmokeStage(row.stage, language: store.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Text(AppText.softwareSmokeCheckState(row.highestSeverity, language: store.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    Spacer(minLength: 0)
                }

                Text(row.nextAction)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(visibleChecklist) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(color(for: item.state))
                                .frame(width: 6, height: 6)
                            Text("\(item.label): \(AppText.softwareSmokeCheckState(item.state, language: store.language))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                .lineLimit(1)
                            Text(item.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                if let latestLogName {
                    Text("\(store.text(.latestLog)): \(latestLogName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Button {
                Task { await store.runSoftwareAction(recipeId: row.recipeId) }
            } label: {
                Image(systemName: "arrowtriangle.right.circle.fill")
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .disabled(row.stage == .verified || row.stage == .disabled)
            .help(store.text(.runNextAction))

            if let path = row.latestLogPath, FileManager.default.fileExists(atPath: path) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.openLogFile))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var visibleChecklist: [SoftwareSmokeChecklistItem] {
        let important = row.checklist.filter { item in
            item.state == .failed || item.state == .blocked || item.state == .warning || item.state == .pending
        }
        return Array((important.isEmpty ? row.checklist : important).prefix(3))
    }

    private var latestLogName: String? {
        guard let path = row.latestLogPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var iconName: String {
        switch row.highestSeverity {
        case .failed:
            "xmark.octagon.fill"
        case .blocked:
            "hand.raised.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .pending:
            "clock.fill"
        case .passed:
            "checkmark.circle.fill"
        case .notApplicable:
            "minus.circle.fill"
        }
    }

    private var tint: Color {
        color(for: row.highestSeverity)
    }

    private func color(for state: SoftwareSmokeCheckState) -> Color {
        switch state {
        case .passed:
            .green
        case .pending:
            .blue
        case .warning:
            .orange
        case .failed, .blocked:
            .red
        case .notApplicable:
            .secondary
        }
    }
}

private func smokeSeverityRank(_ state: SoftwareSmokeCheckState) -> Int {
    switch state {
    case .failed:
        0
    case .blocked:
        1
    case .warning:
        2
    case .pending:
        3
    case .passed:
        4
    case .notApplicable:
        5
    }
}

struct SoftwarePlanMetric: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ActivityTimelineSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.activityTimeline)) {
            let report = store.activityTimelineReport
            if report.eventCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.errorEventCount > 0 ? "exclamationmark.triangle.fill" : "point.topleft.down.curvedto.point.bottomright.up.fill")
                            .foregroundStyle(report.errorEventCount > 0 ? .red : .blue)
                        Text(store.text(.activityTimelineSummary, report.eventCount, report.errorEventCount, report.warningEventCount))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.exportInstallHistoryCSV()
                        } label: {
                            Label(store.text(.exportInstallHistoryCSV), systemImage: "tablecells")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        Button {
                            store.exportLaunchHistoryCSV()
                        } label: {
                            Label(store.text(.exportLaunchHistoryCSV), systemImage: "tablecells")
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                        if let latest = report.latestEventAt {
                            Text(latest, style: .relative)
                                .font(.caption)
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                .lineLimit(1)
                        }
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.activityTimelineEvents),
                            value: "\(report.eventCount)",
                            systemImage: "list.bullet.rectangle",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: store.text(.activityTimelineErrors),
                            value: "\(report.errorEventCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: .red
                        )
                        SoftwarePlanMetric(
                            title: store.text(.activityTimelineWarnings),
                            value: "\(report.warningEventCount)",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.events.prefix(8)) { event in
                            ActivityTimelineRow(event: event)
                        }
                    }
                }
            } else {
                Label(store.text(.noActivityTimeline), systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }
}

struct ActivityTimelineRow: View {
    @EnvironmentObject private var store: MacWinStore
    var event: ActivityTimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(kindText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                    Text(event.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)
                if let path = event.relatedLogPath ?? event.sourcePath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if let path = event.relatedLogPath ?? event.sourcePath,
               FileManager.default.fileExists(atPath: path) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.openLogFile))

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.revealInFinder))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var kindText: String {
        switch event.kind {
        case .installerDownload:
            store.language == .zhHans ? "下载" : "Download"
        case .installTask:
            store.language == .zhHans ? "安装" : "Install"
        case .launch:
            store.language == .zhHans ? "启动" : "Launch"
        case .testRun:
            store.language == .zhHans ? "测试" : "Test"
        case .logIssue:
            store.language == .zhHans ? "日志" : "Log"
        case .diagnostics:
            store.language == .zhHans ? "诊断" : "Diagnostics"
        }
    }

    private var iconName: String {
        switch event.severity {
        case .info:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch event.severity {
        case .info:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }
}

struct CompatibilityRepairAuditSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.compatibilityRepairAudit)) {
            let report = store.compatibilityRepairAuditReport
            if report.auditedLaunchCount > 0 || !report.runtimeCoverageEntries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.findings.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(report.findings.isEmpty ? .green : .orange)
                        Text(store.text(
                            .compatibilityRepairAuditSummary,
                            report.auditedLaunchCount,
                            report.readyLaunchCount,
                            report.missingRepairLaunchCount,
                            report.staleFlagLaunchCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.compatibilityRepairReady),
                            value: "\(report.readyLaunchCount)",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                        SoftwarePlanMetric(
                            title: store.text(.compatibilityRepairMissing),
                            value: "\(report.missingRepairLaunchCount)",
                            systemImage: "exclamationmark.circle.fill",
                            tint: .orange
                        )
                        SoftwarePlanMetric(
                            title: store.text(.compatibilityRepairStale),
                            value: "\(report.staleFlagLaunchCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: .red
                        )
                        SoftwarePlanMetric(
                            title: store.text(.compatibilityRuntimeCoverageMissing),
                            value: "\(report.missingRuntimeCoverageCount)",
                            systemImage: "shippingbox.and.arrow.backward.fill",
                            tint: report.missingRuntimeCoverageCount == 0 ? .green : .orange
                        )
                    }

                    let problemEntries = report.entries.filter { $0.state != .ready }
                    if !problemEntries.isEmpty {
                        Divider()
                        Text(store.text(.latestRepairFindings))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(problemEntries.prefix(5)) { entry in
                                CompatibilityRepairAuditRow(entry: entry)
                            }
                        }
                    }

                    if !report.runtimeCoverageEntries.isEmpty {
                        Divider()
                        Text(store.text(.compatibilityRuntimeCoverage))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.runtimeCoverageEntries) { entry in
                                CompatibilityRuntimeCoverageRow(entry: entry)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.noCompatibilityRepairAudit), systemImage: "checkmark.shield")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }
}

struct CompatibilityRuntimeCoverageRow: View {
    @EnvironmentObject private var store: MacWinStore
    var entry: CompatibilityRuntimeCoverageEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.missingSourcePaths.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(entry.missingSourcePaths.isEmpty ? .green : .orange)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.engineName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(AppText.compatibilityProfileName(.wpsOffice, language: store.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                    Spacer(minLength: 0)
                    Text(entry.missingSourcePaths.isEmpty
                        ? store.text(.compatibilityRepairReady)
                        : store.text(.compatibilityRuntimeCoverageMissing))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.missingSourcePaths.isEmpty ? .green : .orange)
                }

                Text(store.text(
                    .compatibilityAffectedBottles,
                    entry.affectedBottleNames.joined(separator: " · ")
                ))
                .font(.caption)
                .foregroundStyle(Color.macWinReadableSecondaryText)
                .lineLimit(2)

                if !entry.missingSourcePaths.isEmpty {
                    ForEach(entry.missingSourcePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CompatibilityRepairAuditRow: View {
    @EnvironmentObject private var store: MacWinStore
    var entry: CompatibilityRepairAuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: entry.exe.replacingOccurrences(of: "\\", with: "/")).lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(AppText.compatibilityProfileName(profile, language: store.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                    Text(stateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                    Text(entry.startedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !entry.missingRepairKeys.isEmpty {
                    Text(entry.missingRepairKeys.prefix(5).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(2)
                }
                if !entry.staleRenderingFlags.isEmpty {
                    Text(entry.staleRenderingFlags.prefix(5).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(2)
                }
                Text(entry.logPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if FileManager.default.fileExists(atPath: entry.logPath) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.logPath))
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.openLogFile))

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.logPath)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help(store.text(.revealInFinder))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var profile: ApplicationCompatibilityProfile {
        ApplicationCompatibilityProfile(rawValue: entry.profile) ?? .cefSoftwareRenderer
    }

    private var stateText: String {
        switch entry.state {
        case .ready:
            store.text(.compatibilityRepairReady)
        case .missingRepairs:
            store.text(.compatibilityRepairMissing)
        case .staleFlags:
            store.text(.compatibilityRepairStale)
        }
    }

    private var iconName: String {
        switch entry.state {
        case .ready:
            "checkmark.circle.fill"
        case .missingRepairs:
            "exclamationmark.circle.fill"
        case .staleFlags:
            "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch entry.state {
        case .ready:
            .green
        case .missingRepairs:
            .orange
        case .staleFlags:
            .red
        }
    }
}

struct SoftwareTestPlanRow: View {
    @EnvironmentObject private var store: MacWinStore
    var entry: SoftwareTestPlanEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stateIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(AppText.softwareTestPlanState(entry.state, language: store.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stateColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(stateColor.opacity(0.12), in: Capsule())
                    if entry.requiresWin32 {
                        Text(store.text(.requiresWin32))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.10), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }

                Text(AppText.softwareTestPlanAction(entry, language: store.language))
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text("\(AppText.category(entry.category, language: store.language)) · \(AppText.rating(entry.compatibilityRating, language: store.language))")
                    if let logName = latestLogName {
                        Text("\(store.text(.latestLog)): \(logName)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                if !issueText.isEmpty {
                    Text("\(store.text(.blockers)): \(issueText)")
                        .font(.caption2)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                        .lineLimit(2)
                }
            }

            Button {
                Task { await store.runSoftwareAction(recipeId: entry.recipeId) }
            } label: {
                Image(systemName: "arrowtriangle.right.circle.fill")
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .disabled(entry.state == .verified || entry.state == .disabled)
            .help(store.text(.runNextAction))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var latestLogName: String? {
        let path = entry.latestLaunchLogPath ?? entry.latestInstallLogPath
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var issueText: String {
        var values: [String] = []
        for value in entry.blockers + entry.probableIssueIds where !values.contains(value) {
            values.append(value)
        }
        return values.prefix(4).joined(separator: " · ")
    }

    private var stateIcon: String {
        switch entry.state {
        case .verified:
            "checkmark.circle.fill"
        case .readyToInstall:
            "arrow.down.circle.fill"
        case .installerLaunched:
            "clock.fill"
        case .installedNotLaunched:
            "play.circle.fill"
        case .needsReview:
            "doc.text.magnifyingglass"
        case .installFailed, .launchFailed, .hashMismatch:
            "xmark.octagon.fill"
        case .missingInstaller, .localInstallerRequired, .existingInstallMissing:
            "tray.and.arrow.down.fill"
        case .blocked:
            "exclamationmark.triangle.fill"
        case .disabled:
            "minus.circle.fill"
        }
    }

    private var stateColor: Color {
        switch entry.state {
        case .verified:
            .green
        case .readyToInstall:
            .cyan
        case .installerLaunched:
            .blue
        case .installedNotLaunched:
            .blue
        case .needsReview:
            .orange
        case .installFailed, .launchFailed, .hashMismatch:
            .red
        case .missingInstaller, .localInstallerRequired, .existingInstallMissing, .blocked:
            .orange
        case .disabled:
            .secondary
        }
    }
}

struct DiagnosticCard: View {
    @EnvironmentObject private var store: MacWinStore
    var item: DiagnosticItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(AppText.diagnosticStatus(item.status, language: store.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
            Text(AppText.diagnosticRecommendation(item, language: store.language))
                .font(.caption)
                .foregroundStyle(Color.macWinReadableSecondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(minHeight: 74, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusIcon: String {
        switch item.status {
        case .passed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .skipped:
            "minus.circle.fill"
        case .notObserved:
            "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .passed:
            .green
        case .failed:
            .red
        case .skipped:
            .orange
        case .notObserved:
            .secondary
        }
    }
}

struct LogIssueSummarySection: View {
    @EnvironmentObject private var store: MacWinStore

    private var report: LogIssueReport {
        store.logIssueReport
    }

    private let metricColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.logIssues)) {
            if report.logsAnalyzed == 0 {
                Label(store.text(.noRecentLogs), systemImage: "doc.text")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.failedLogCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(report.failedLogCount > 0 ? .red : .green)
                        Text(store.text(
                            .logIssuesSummary,
                            report.logsAnalyzed,
                            report.failedLogCount,
                            report.attentionLogCount,
                            report.passedLogCount
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.logsAnalyzed),
                            value: "\(report.logsAnalyzed)",
                            systemImage: "doc.text.magnifyingglass",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: AppText.logHealth(.failed, language: store.language),
                            value: "\(report.failedLogCount)",
                            systemImage: "xmark.octagon.fill",
                            tint: .red
                        )
                        SoftwarePlanMetric(
                            title: AppText.logHealth(.attention, language: store.language),
                            value: "\(report.attentionLogCount)",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                        SoftwarePlanMetric(
                            title: AppText.logHealth(.passed, language: store.language),
                            value: "\(report.passedLogCount)",
                            systemImage: "checkmark.circle.fill",
                            tint: .green
                        )
                    }

                    if report.topIssues.isEmpty {
                        Label(store.text(.noLogIssues), systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.topIssues.prefix(5)) { issue in
                                LogIssueTrendRow(issue: issue)
                            }
                        }
                    }

                    if !report.recentFailures.isEmpty {
                        Divider()
                        Text(store.text(.recentLogFailures))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.recentFailures.prefix(5)) { sample in
                                LogIssueSampleRow(sample: sample)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct LogMaintenanceSection: View {
    @EnvironmentObject private var store: MacWinStore

    private let metricColumns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        SectionPanel(title: store.text(.logMaintenance)) {
            if let report = store.logMaintenanceReport {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: report.cleanupCandidateCount > 0 ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.checkmark")
                            .foregroundStyle(report.cleanupCandidateCount > 0 ? .orange : .green)
                        Text(store.text(
                            .logMaintenanceSummary,
                            report.totalLogCount,
                            Self.formattedByteCount(report.totalLogBytes),
                            Self.formattedByteCount(report.cleanupCandidateBytes)
                        ))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            store.archiveCleanupLogs()
                        } label: {
                            Label(store.text(.archiveCleanupLogs), systemImage: "archivebox")
                        }
                        .controlSize(.small)
                        .disabled(report.cleanupCandidateCount == 0)
                        Button {
                            store.cleanHistoricalLogs()
                        } label: {
                            Label(store.text(.cleanHistoricalLogs), systemImage: "clock.arrow.circlepath")
                        }
                        .controlSize(.small)
                        Button {
                            store.exportLogMaintenanceScript()
                        } label: {
                            Label(store.text(.exportLogMaintenanceScript), systemImage: "terminal")
                        }
                        .controlSize(.small)
                    }

                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                        SoftwarePlanMetric(
                            title: store.text(.totalLogSize),
                            value: Self.formattedByteCount(report.totalLogBytes),
                            systemImage: "doc.text",
                            tint: .blue
                        )
                        SoftwarePlanMetric(
                            title: store.text(.staleLogs),
                            value: "\(report.staleLogCount)",
                            systemImage: "clock.badge.exclamationmark",
                            tint: report.staleLogCount > 0 ? .orange : .secondary
                        )
                        SoftwarePlanMetric(
                            title: store.text(.largeLogs),
                            value: "\(report.largeLogCount)",
                            systemImage: "doc.badge.gearshape",
                            tint: report.largeLogCount > 0 ? .orange : .secondary
                        )
                        SoftwarePlanMetric(
                            title: store.text(.cleanupCandidates),
                            value: "\(report.cleanupCandidateCount)",
                            systemImage: "trash",
                            tint: report.cleanupCandidateCount > 0 ? .red : .green
                        )
                    }

                    HStack(spacing: 12) {
                        if let oldest = report.oldestLogModifiedAt {
                            Label("\(store.text(.oldestLog)) \(oldest.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar.badge.clock")
                        }
                        if let newest = report.newestLogModifiedAt {
                            Label("\(store.text(.newestLog)) \(newest.formatted(date: .abbreviated, time: .shortened))", systemImage: "calendar")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)

                    if report.cleanupCandidates.isEmpty {
                        Label(store.text(.logMaintenanceHealthy), systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.cleanupCandidates.prefix(4)) { item in
                                LogMaintenanceCandidateRow(item: item)
                            }
                        }
                    }

                    if !report.recommendations.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(store.text(.recommendations), systemImage: "lightbulb")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                            ForEach(report.recommendations.prefix(3), id: \.self) { recommendation in
                                Text(AppText.logMaintenanceRecommendation(recommendation, language: store.language))
                                    .font(.caption)
                                    .foregroundStyle(Color.macWinReadableSecondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                Label(store.text(.noRecentLogs), systemImage: "doc.text")
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }
        }
    }

    fileprivate static func formattedByteCount(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }
}

struct LogMaintenanceCandidateRow: View {
    @EnvironmentObject private var store: MacWinStore
    var item: LogMaintenanceItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(LogMaintenanceSection.formattedByteCount(item.byteCount)) · \(item.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(reasonText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        item.reasons.contains("large") ? "doc.badge.gearshape" : "clock.badge.exclamationmark"
    }

    private var tint: Color {
        item.reasons.contains("large") ? .orange : .secondary
    }

    private var reasonText: String {
        let localized = item.reasons.map { reason in
            switch reason {
            case "stale":
                store.text(.staleLogs)
            case "large":
                store.text(.largeLogs)
            default:
                reason
            }
        }
        return localized.joined(separator: " · ")
    }
}

struct LogIssueTrendRow: View {
    @EnvironmentObject private var store: MacWinStore
    var issue: LogIssueTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                Text(AppText.logIssueTitle(issue, language: store.language))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(AppText.logIssueSeverity(issue.severity, language: store.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12), in: Capsule())
                Spacer(minLength: 0)
                Text("\(issue.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.macWinReadableSecondaryText)
            }

            Text(AppText.logIssueDetail(issue, language: store.language))
                .font(.caption)
                .foregroundStyle(Color.macWinReadableSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            let actions = AppText.logIssueActions(issue, language: store.language)
            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(store.text(.recommendedActions), systemImage: "wrench.and.screwdriver")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    ForEach(actions.prefix(2), id: \.self) { action in
                        Text(action)
                            .font(.caption2)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 1)
            }

            if !issue.probeAssetIds.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    Label(store.text(.recommendedProbes), systemImage: "testtube.2")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                    ForEach(issue.probeAssetIds.prefix(5), id: \.self) { probe in
                        Button {
                            Task { await store.runProbe(assetId: probe) }
                        } label: {
                            Label(probe, systemImage: "play.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .font(.caption2.weight(.semibold))
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                        .disabled(!store.canRunProbe(assetId: probe))
                        .help(store.text(.runningProbe, probe))
                    }
                }
                .lineLimit(1)
            }

            if !issue.affectedLogNames.isEmpty {
                Text("\(store.text(.affectedLogs)): \(issue.affectedLogNames.prefix(4).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch issue.severity {
        case "critical":
            "xmark.octagon.fill"
        case "high":
            "exclamationmark.triangle.fill"
        case "medium":
            "exclamationmark.circle.fill"
        default:
            "info.circle.fill"
        }
    }

    private var tint: Color {
        switch issue.severity {
        case "critical":
            .red
        case "high":
            .orange
        case "medium":
            .yellow
        default:
            .secondary
        }
    }
}

struct LogIssueSampleRow: View {
    @EnvironmentObject private var store: MacWinStore
    var sample: LogIssueSample

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: health == .failed ? "doc.badge.xmark" : "doc.badge.gearshape")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(healthColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(sample.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(AppText.logHealth(health, language: store.language))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(healthColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(healthColor.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .lineLimit(2)

                Text(sample.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let context = sample.launchContext {
                    LogLaunchContextView(context: context)
                }

                if !sample.evidenceSnippets.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.text(.evidence))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                        ForEach(Array(sample.evidenceSnippets.prefix(2)), id: \.self) { snippet in
                            Text(snippet)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 2)
                }

                if !sample.probeAssetIds.isEmpty {
                    Text("\(store.text(.recommendedProbes)): \(sample.probeAssetIds.prefix(4).joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            Button {
                store.openLogIssueSample(sample)
            } label: {
                Label(store.text(.log), systemImage: "doc.text.magnifyingglass")
            }
            .controlSize(.small)
            Button {
                store.revealLogIssueSample(sample)
            } label: {
                Label(store.text(.revealInFinder), systemImage: "folder")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var health: LogHealth {
        LogHealth(rawValue: sample.health) ?? .attention
    }

    private var healthColor: Color {
        switch health {
        case .failed:
            .red
        case .attention:
            .orange
        case .passed:
            .green
        case .quiet:
            .secondary
        }
    }

    private var summaryText: String {
        let issues = sample.probableIssueIds.prefix(3).map {
            AppText.logIssueTitle(id: $0, language: store.language)
        }
        var parts = issues
        if sample.errorCount > 0 {
            parts.append(store.language == .zhHans ? "错误 \(sample.errorCount)" : "errors \(sample.errorCount)")
        }
        if sample.failCount > 0 {
            parts.append("FAIL \(sample.failCount)")
        }
        if sample.warningCount > 0 {
            parts.append(store.language == .zhHans ? "警告 \(sample.warningCount)" : "warn \(sample.warningCount)")
        }
        return parts.isEmpty ? sample.path : parts.joined(separator: " · ")
    }
}

struct RecentLogsSection: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        SectionPanel(title: store.text(.recentLogs)) {
            if store.recentLogs.isEmpty {
                Text(store.text(.noRecentLogs))
                    .foregroundStyle(Color.macWinReadableSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(store.recentLogs) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(AppText.logHealth(item.summary.health, language: store.language))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(healthColor(item.summary.health))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(healthColor(item.summary.health).opacity(0.12), in: Capsule())
                            }
                            Text("\(item.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.formattedByteCount(item.byteCount))")
                                .font(.caption)
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                                .lineLimit(1)
                            if !summaryCounts(item.summary).isEmpty {
                                Text(summaryCounts(item.summary))
                                    .font(.caption)
                                    .foregroundStyle(Color.macWinReadableSecondaryText)
                                    .lineLimit(1)
                            }
                            if let context = item.launchContext {
                                LogLaunchContextView(context: context)
                            }
                            ForEach(item.summary.hints.prefix(2), id: \.self) { hint in
                                Label(AppText.logHint(hint, language: store.language), systemImage: "lightbulb")
                                    .font(.caption)
                                    .foregroundStyle(Color.macWinReadableSecondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            store.openLog(item)
                        } label: {
                            Label(store.text(.log), systemImage: "doc.text.magnifyingglass")
                        }
                        .controlSize(.small)
                        Button {
                            store.revealLog(item)
                        } label: {
                            Label(store.text(.revealInFinder), systemImage: "folder")
                        }
                        .controlSize(.small)
                    }
                    if item.id != store.recentLogs.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    private func healthColor(_ health: LogHealth) -> Color {
        switch health {
        case .passed:
            .green
        case .failed:
            .red
        case .attention:
            .orange
        case .quiet:
            .secondary
        }
    }

    private func summaryCounts(_ summary: LogSummary) -> String {
        var parts: [String] = []
        if summary.errorCount > 0 {
            parts.append(store.language == .zhHans ? "错误 \(summary.errorCount)" : "errors \(summary.errorCount)")
        }
        if summary.failCount > 0 {
            parts.append("FAIL \(summary.failCount)")
        }
        if summary.warningCount > 0 {
            parts.append(store.language == .zhHans ? "警告 \(summary.warningCount)" : "warn \(summary.warningCount)")
        }
        if summary.fixmeCount > 0 {
            parts.append("fixme \(summary.fixmeCount)")
        }
        if summary.passCount > 0 {
            parts.append("PASS \(summary.passCount)")
        }
        return parts.joined(separator: " · ")
    }
}

struct LogLaunchContextView: View {
    @EnvironmentObject private var store: MacWinStore
    var context: LogLaunchContext

    var body: some View {
        HStack(spacing: 6) {
            Label(context.bottleName, systemImage: "shippingbox")
            Label(executableName, systemImage: "app")
            Label(context.mode, systemImage: context.mode == WineLaunchMode.detached.rawValue ? "rectangle.stack" : "play.circle")
            if let exitCode = context.exitCode {
                Label("\(store.text(.exitCode)) \(exitCode)", systemImage: exitCode == 0 ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
            } else if context.state == WineLaunchState.failedToLaunch.rawValue {
                Label(store.text(.unableToLaunchProcess), systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .help(helpText)
    }

    private var executableName: String {
        let normalized = context.exe.replacingOccurrences(of: "\\", with: "/")
        return URL(fileURLWithPath: normalized).lastPathComponent
    }

    private var helpText: String {
        var parts = [
            "\(store.text(.bottle)): \(context.bottleName) (\(context.bottleId))",
            "\(store.text(.engine)): \(context.engineId)",
            "\(store.text(.externalExecutable)): \(context.exe)"
        ]
        if !context.args.isEmpty {
            parts.append("\(store.text(.arguments)): \(context.args.joined(separator: " "))")
        }
        if let exitCode = context.exitCode {
            parts.append("\(store.text(.exitCode)): \(exitCode)")
        }
        return parts.joined(separator: "\n")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: MacWinStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(title: store.text(.settings), subtitle: store.text(.engineAndCatalog))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionPanel(title: store.text(.language)) {
                        Picker(store.text(.language), selection: Binding(get: {
                            store.language
                        }, set: { language in
                            store.setLanguage(language)
                        })) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    SectionPanel(title: store.text(.keepSystemAwake)) {
                        Toggle(isOn: Binding(get: {
                            store.preventScreenLockWhileRunning
                        }, set: { enabled in
                            store.setPreventScreenLockWhileRunning(enabled)
                        })) {
                            Text(store.text(.keepSystemAwake))
                        }
                        Text(store.text(.preventScreenLockHint))
                            .font(.caption)
                            .foregroundStyle(Color.macWinReadableSecondaryText)
                    }

                    SectionPanel(title: store.text(.engine)) {
                        if let engine = store.engines.first {
                            LabeledContent(store.text(.name), value: engine.name)
                            LabeledContent(store.text(.version), value: engine.wineVersion)
                            LabeledContent(store.text(.architecture), value: engine.arch.rawValue)
                            LabeledContent(store.text(.win32Compatibility), value: engine.supportsWin32 ? store.text(.win32Supported) : store.text(.win32Unsupported))
                            LabeledContent("Wine", value: engine.winePath)
                            LabeledContent(store.text(.runtime), value: engine.runtimePath)
                            LabeledContent("D3D", value: engine.defaultEnv["WINE_D3D_CONFIG"] ?? "")
                        } else {
                            Text(store.text(.noEngineRegistered))
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                        }
                        Button {
                            Task { await store.bootstrap() }
                        } label: {
                            Label(store.text(.refreshEngine), systemImage: "arrow.clockwise")
                        }
                    }

                    SectionPanel(title: store.text(.defaultGameBottle)) {
                        if let bottle = store.defaultPerformanceBottle {
                            LabeledContent(store.text(.name), value: bottle.name)
                            GraphicsPresetSelector(bottle: bottle)
                        } else {
                            Text(store.text(.noBottleSelected))
                                .foregroundStyle(Color.macWinReadableSecondaryText)
                        }
                    }

                    SectionPanel(title: store.text(.catalog)) {
                        LabeledContent(store.text(.recipes), value: "\(store.recipes.count)")
                        LabeledContent(store.text(.trust), value: store.text(.signedCuratedSource))
                        Button {
                            do {
                                try store.loadBundledCatalog()
                            } catch {
                                store.statusMessage = store.text(.catalogError)
                                store.lastError = error.localizedDescription
                            }
                        } label: {
                            Label(store.text(.refreshCatalog), systemImage: "arrow.clockwise")
                        }
                    }

                    SectionPanel(title: store.text(.data)) {
                        LabeledContent(store.text(.root), value: store.paths.root.path)
                        Button {
                            store.openLogs()
                        } label: {
                            Label(store.text(.openLogs), systemImage: "doc.text")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

struct Header: View {
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(Color.macWinReadableSecondaryText)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }
}

struct SectionPanel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    var systemImage: String
    var title: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Color.macWinReadableSecondaryText)
            Text(title)
                .font(.headline)
            Button(action: action) {
                Label(actionTitle, systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExternalExecutableOpenView: View {
    @EnvironmentObject private var store: MacWinStore
    var request: ExternalExecutableRequest
    @State private var selectedBottleId: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                executableIcon
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.text(.openWindowsExecutable))
                        .font(.title2.weight(.semibold))
                    Text(request.displayName)
                        .font(.headline)
                    Text(store.text(.chooseBottleToOpenExecutable))
                        .font(.subheadline)
                        .foregroundStyle(Color.macWinReadableSecondaryText)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(store.text(.sourceFile), value: request.url.path)
                LabeledContent(store.text(.architecture), value: request.architecture.rawValue)
            }
            .font(.callout)

            Picker(store.text(.bottle), selection: $selectedBottleId) {
                ForEach(store.bottles) { bottle in
                    Text(bottle.name).tag(bottle.id)
                }
            }

            HStack {
                Button {
                    store.dismissPendingExternalExecutable()
                } label: {
                    Text(store.text(.cancel))
                }
                Spacer()
                Button {
                    guard let bottle = selectedBottle else { return }
                    Task { await store.runExternalExecutable(request, in: bottle, diagnostics: true) }
                } label: {
                    Label(store.text(.runWithDiagnostics), systemImage: "stethoscope")
                }
                Button {
                    guard let bottle = selectedBottle else { return }
                    Task { await store.runExternalExecutable(request, in: bottle) }
                } label: {
                    Label(store.text(.runInBottle), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear {
            selectedBottleId = store.selectedBottleId ?? store.defaultPerformanceBottle?.id ?? store.bottles.first?.id ?? ""
        }
    }

    @ViewBuilder
    private var executableIcon: some View {
        LauncherIconView(
            title: request.url.deletingPathExtension().lastPathComponent,
            iconPath: request.iconURL?.path,
            systemImage: "app",
            tint: .accentColor,
            size: 64
        )
    }

    private var selectedBottle: BottleManifest? {
        store.bottles.first { $0.id == selectedBottleId }
    }
}
