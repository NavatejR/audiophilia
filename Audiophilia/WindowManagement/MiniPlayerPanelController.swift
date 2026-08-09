import AppKit
import SwiftUI

// MARK: - Mini Player Panel Controller

/// Manages the floating picture-in-picture mini player `NSPanel`.
/// The panel stays on top of other desktop windows, is borderless,
/// and features a frosted glass background with squircle corners.
///
/// Performance notes:
/// - The `NSHostingView` is created ONCE and reused across show/hide
///   cycles — toggling the mini player never rebuilds the SwiftUI tree.
/// - Present/dismiss uses an AppKit `NSAnimationContext` fade+scale
///   transform instead of an instant `orderFront`/`orderOut`.
@MainActor
final class MiniPlayerPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    private var isAnimating = false

    func show() {
        guard !isAnimating else { return }

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
                styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.animationBehavior = .utilityWindow
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.becomesKeyOnlyIfNeeded = true
            panel.delegate = self
            self.panel = panel
        }

        guard let panel = panel else { return }

        // Reuse the hosting view — only build it once.
        if hostingView == nil {
            let contentView = AnyView(
                MiniPlayerContentView()
                    .environmentObject(AudioEngine.shared)
                    .environmentObject(LibraryManager.shared)
                    .environmentObject(PlayerState.shared)
            )
            let hosting = NSHostingView(rootView: contentView)
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 18
            hosting.layer?.masksToBounds = true
            hostingView = hosting
            panel.contentView = hosting

            // Position near the bottom-right of the main screen
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let panelSize = panel.frame.size
                let origin = NSPoint(
                    x: screenFrame.maxX - panelSize.width - 24,
                    y: screenFrame.minY + 24
                )
                panel.setFrameOrigin(origin)
            }
        }

        if panel.isVisible { return }

        // Animated alpha fade only — no scale transform. Scaling an
        // `NSHostingView` layer forces a full SwiftUI re-rasterization;
        // an alpha blend is a single GPU pass.
        isAnimating = true
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.isAnimating = false
        }
    }

    func hide() {
        guard !isAnimating, panel?.isVisible == true else { return }

        isAnimating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1
            self?.isAnimating = false
        }
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }
}

// MARK: - Mini Player Content

/// The SwiftUI content hosted inside the floating panel.
/// Cover-art-only with minimal controls.
private struct MiniPlayerContentView: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var playerState: PlayerState

    var body: some View {
        VStack(spacing: 0) {
            // Cover art display (tap toggles play/pause)
            ZStack {
                if let track = audioEngine.currentTrack,
                   let artwork = library.artwork(for: track) {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                // Close button
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            playerState.isMiniPlayerVisible = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Spacer()
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Minimal controls
            VStack(spacing: 10) {
                if let track = audioEngine.currentTrack {
                    Text(track.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No Track Playing")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    Button {
                        audioEngine.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        audioEngine.togglePlayPause()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 36, height: 36)
                            Image(systemName: audioEngine.playbackState == .playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: audioEngine.playbackState == .playing ? 0 : 1)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        audioEngine.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }

                // Progress
                VStack(spacing: 4) {
                    ProgressView(value: audioEngine.duration > 0 ? audioEngine.currentTime / audioEngine.duration : 0)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .controlSize(.small)

                    HStack {
                        Text(Track.timeString(audioEngine.currentTime))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Track.timeString(audioEngine.duration))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 220)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}