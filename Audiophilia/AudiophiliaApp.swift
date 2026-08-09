import SwiftUI
import AppKit
import Combine

// MARK: - App Delegate

/// Application-level window configuration. This is the most reliable place
/// to style the titlebar because it runs at the NSApplication level —
/// no dependence on SwiftUI view lifecycle timing.
///
/// SwiftUI's `.windowStyle(.hiddenTitleBar)` alone still paints an opaque
/// grey strip over the top ~28pt for the traffic lights. The titlebar is
/// therefore removed ENTIRELY (`.titled` is dropped) and the SwiftUI root
/// draws a full-bleed opaque theme gradient — so the whole window, including
/// the former titlebar strip, shows the theme (no desktop grey). The window
/// is OPAQUE and painted with the theme's top gradient colour, and is
/// draggable by its background.
final class AudiophiliaAppDelegate: NSObject, NSApplicationDelegate {
    private var themeObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Observe every window that becomes key — re-assert the (idempotent)
        // titlebar configuration. This also catches windows created later
        // (e.g. after a window is closed and reopened via the Dock).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            Self.configureTitlebar(for: window)
        }

        // Re-assert when a window is resized. SwiftUI can restore the implicit
        // "titlebar <-> content" relationship of `.titled` windows during
        // resize/live-resize; the guard inside configureTitlebar makes this a
        // cheap no-op unless `.titled` actually came back.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            Self.configureTitlebar(for: window)
        }

        // Configure any windows that already exist at launch. SwiftUI's
        // WindowGroup may create its NSWindow slightly AFTER this delegate
        // callback completes, so re-assert a few runloop turns later too.
        DispatchQueue.main.async { [weak self] in
            self?.configureAllWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.configureAllWindows()
        }

        // Re-tint the titlebar whenever the theme changes in Settings.
        // Only the window background colour is touched — never the
        // expensive `styleMask` (it stays idempotent inside configureTitlebar).
        themeObservation = ThemeManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureAllWindows()
            }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureAllWindows()
    }

    private func configureAllWindows() {
        for window in NSApp.windows {
            Self.configureTitlebar(for: window)
        }
    }

    /// Removes the AppKit titlebar ENTIRELY (frameless window) and lets the
    /// SwiftUI root draw the theme gradient full-bleed — so no grey titlebar
    /// strip can ever render. The window is OPAQUE and painted with the
    /// theme's top gradient colour; the SwiftUI root draws a full-bleed
    /// opaque theme gradient, so the whole window shows the theme (exactly
    /// like the FullscreenPlayer) — no desktop grey.
    ///
    /// IDEMPOTENT: the expensive `styleMask` mutation runs only when `.titled`
    /// is still present. SwiftUI's WindowGroup re-asserts window styling
    /// frequently; previously `styleMask.remove(.titled)` was re-executed on
    /// every window update during playback, causing window-server churn and
    /// sustained CPU. Now repeated calls are cheap no-ops (just an opaque
    /// background-colour set).
    static func configureTitlebar(for window: NSWindow) {
        // Never touch the borderless mini-player panel (no titlebar there),
        // nor modal sheets/panels (they need `.titled` to render correctly).
        guard !window.styleMask.contains(.borderless),
              !window.styleMask.contains(.docModalWindow) else { return }

        // Drop `.titled` only once → the system titlebar (and its grey
        // strip) no longer exists. The window keeps `.resizable` so
        // zoom/resize still work, and SwiftUI content extends under the
        // former strip via `.fullSizeContentView`.
        if window.styleMask.contains(.titled) {
            window.styleMask.remove(.titled)
            window.styleMask.insert(.fullSizeContentView)
        }
        window.isMovableByWindowBackground = true

        // Paint the whole window with the theme's top gradient colour so the
        // theme fills the entire frame (no grey anywhere). The window is
        // OPAQUE: the SwiftUI root draws a full-bleed solid theme gradient,
        // so there is no desktop to composite through — the window server
        // skips per-frame desktop blending (a CPU win during playback).
        let theme = ThemeManager.shared.theme
        window.backgroundColor = NSColor(theme.topGradient)
        window.isOpaque = true
    }
}

// MARK: - App

@main
struct AudiophiliaApp: App {
    @NSApplicationDelegateAdaptor(AudiophiliaAppDelegate.self) private var appDelegate

    @StateObject private var libraryManager = LibraryManager.shared
    @StateObject private var audioEngine = AudioEngine.shared
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var themeManager = ThemeManager.shared

    @State private var miniPlayerController: MiniPlayerPanelController?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryManager)
                .environmentObject(audioEngine)
                .environmentObject(playerState)
                .environmentObject(themeManager)
                .tint(themeManager.theme.accent)
                .frame(minWidth: 1100, minHeight: 700)
                .onChange(of: playerState.isMiniPlayerVisible) { _, isVisible in
                    if isVisible {
                        showMiniPlayer()
                    } else {
                        hideMiniPlayer()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Music Folder…") {
                    libraryManager.promptForFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Search Library…") {
                    NotificationCenter.default.post(name: NSNotification.Name("FocusSearch"), object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandMenu("Playback") {
                Button("Play/Pause") {
                    audioEngine.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Next Track") {
                    audioEngine.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button("Previous Track") {
                    audioEngine.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button("Toggle Shuffle") {
                    audioEngine.isShuffleEnabled.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Toggle Bit-Perfect") {
                    playerState.isBitPerfectMode.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            CommandGroup(after: .windowArrangement) {
                Button("Toggle Mini Player") {
                    playerState.isMiniPlayerVisible.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }

    private func showMiniPlayer() {
        if miniPlayerController == nil {
            miniPlayerController = MiniPlayerPanelController()
        }
        miniPlayerController?.show()
    }

    private func hideMiniPlayer() {
        miniPlayerController?.hide()
    }
}