# Mac-Win frameless window candidate

This candidate is based on sizing commit `2438c345c419bd89df282af5337a9db333ab7f5f` and is not a release or a claim of native interaction validation.

## Implemented scope

- SwiftUI main WindowGroup, AppKit fallback main window, and the app-owned external-executable sheet use the same chrome attachment.
- Windows are visually frameless: they retain AppKit’s public `.titled`, `.resizable` and `.fullSizeContentView` mechanism, make the native titlebar transparent, hide its standard controls and fill the frame with app content. This preserves SwiftUI’s existing keyboard eligibility and native edge-resize mechanism without runtime class replacement. This is not an assertion that `.titled` was removed. Accessible custom close, minimize, zoom/restore, and fullscreen buttons use the window that owns the view. Cmd-W, Cmd-M, Control-Cmd-F, and the normal application Cmd-Q remain available. Closing does not terminate the application or introduce tray behavior. Dock reactivation stays with the existing app delegate.
- A native titlebar background view calls `NSWindow.performDrag(with:)` for a left mouse-down. Interactive buttons/menus stay above that view. AppKit owns drag termination and native edge resizing; no custom pointer polling, screenshot loop, or event monitor was introduced.
- Normal surfaces have a 12-point corner mask and shadow; zoomed/fullscreen surfaces are square without shadow. Transparent window backing allows clipped corners even when the interior uses the solid fallback. The window remains mouse-interactive.
- The root and app-owned sheet use public `NSVisualEffectView` behind-window blending. Interior title/sidebar materials remain within-window and are not described as desktop blur. The custom close action delegates to native `performClose` while its hidden native button exists; the fallback path explicitly consults `windowShouldClose` before closing. Window appearance settings persist the user's opt-out. Reduce Transparency and Increase Contrast force a solid system-color interior without overwriting that opt-out.
- Static style configuration runs once per window. Move/focus notifications no longer rebuild chrome or fit the frame. Resize notifications compare corner/shadow and normal-mode transitions; ordinary live resize schedules no geometry writes. Screen transitions update minimum sizes without moving reachable windows; actual display topology changes recover an unreachable titlebar. Fullscreen/zoomed windows defer minimum/recovery work until normal restoration; pending work waits for live resize to end, then runs once. Initial fullscreen/zoomed attachment does not clear existing constraints or restore a normal frame into the suspended state. Recovery lowers stale minimum constraints before applying a smaller frame. Saved frames and the `MacWinMainWindow` autosave name remain.
- The old SwiftUI root minimum of 1040×700 contradicted the sizing branch's 960×620 nominal minimum and smaller saved windows. The root now permits those restored sizes; AppKit controls the effective minimum.

System file pickers/alerts and Wine-managed application windows are not modified. The external-executable sheet keeps its modal flow, Cancel/Escape/Cmd-W dismissal and existing run actions; it does not acquire main-window minimize/fullscreen behavior.

## Reproducible checks without showing a GUI

From `MacWinManager`:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --manifest-cache local -j 2

CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --manifest-cache local -j 2 \
  --filter 'CompactWindowGeometryTests|WindowSurfacePolicyTests|WindowCloseRequestTests|WindowGeometryRefreshTests'
```

`--disable-sandbox` only avoids SwiftPM's nested manifest sandbox on restricted executors; it changes no OS security setting. Omit it on hosts that support the normal manifest sandbox. No package dependencies are downloaded. Tests exercise production geometry, effect policy, geometry-refresh scheduling across fullscreen/zoom/live-resize transitions and close routing (native lifecycle, modal veto, delegate approval/veto without a native button), not native AppKit event delivery or rendering.

## Native acceptance still required

All rows below are **not run**. The execution environment has no callable native desktop interaction tool. The app was not launched, and no native FPS, CPU, drag latency or frame-time result is claimed.

| Area | Required checks |
| --- | --- |
| Main and fallback windows | Launch each path; focus/type; Tab/Shift-Tab/VoiceOver through controls; close then Dock reopen; minimize/restore; Cmd-Q retains existing shutdown behavior. |
| Drag and resize | Drag blank titlebar; verify menus/buttons never start drag; release outside the window; double-click follows system zoom/minimize/none; resize all edges/corners; verify shadow and transparent edge pixels. |
| Fullscreen and zoom | Enter/exit via button and keyboard; check borderless style, zero corners, input, fullscreen exit, and restored frame/minimum; include repeated transitions and system tiling. |
| Effects | Check active/inactive light/dark desktop blur; toggle off then relaunch; check immediate Reduce Transparency / Increase Contrast fallback and reversion; check readability and no black corners/click-through. |
| Modal sheet | Open only the app-owned executable sheet with synthetic data; verify parent remains blocked, input/selection works, Cancel/Escape/Cmd-W dismiss, focus returns, run actions retain their behavior. |
| Displays | Drag between differing scale displays and negative coordinates; verify no snap on a healthy straddling frame; disconnect a display, confirm titlebar recovery and persisted small size. No system display changes were made during this work. |
| Performance | Compare identical drag/live-resize gestures on sizing baseline and candidate; measure actual frame/CPU/event/write counts with native tooling before declaring an improvement. |

Public API references: [NSWindow.performDrag](https://developer.apple.com/documentation/appkit/nswindow/performdrag(with:)), [NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview), [NSWindow.canBecomeKey](https://developer.apple.com/documentation/appkit/nswindow/canbecomekey).
