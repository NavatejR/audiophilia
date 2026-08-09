import SwiftUI

// MARK: - Settings View

/// Appearance + Library + Playback settings panel.
/// Accessible via the gear icon in the sidebar header.
struct SettingsView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var playerState: PlayerState
    @EnvironmentObject private var audioEngine: AudioEngine
    @Environment(\.dismiss) private var dismiss

    /// 5-column grid for the theme swatches — always fits the card width
    /// without squeezing, unlike the previous fixed-width HStack.
    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    /// 3-column grid for the EQ sound-style buttons.
    private let soundStyleColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
            }

            // Appearance
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader("APPEARANCE", icon: "paintbrush.fill")

                // Theme swatch picker
                Text("Accent Theme")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: swatchColumns, spacing: 10) {
                    ForEach(ThemeManager.presets) { preset in
                        let isSelected = theme.themeID == preset.id
                        Button {
                            withAnimation(MicroEase) {
                                theme.themeID = preset.id
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(preset.artworkGradient)
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(
                                        Circle()
                                            .strokeBorder(isSelected ? Color.white.opacity(0.6) : Color.white.opacity(0.15), lineWidth: isSelected ? 2 : 1)
                                    )
                                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)

                                Text(preset.name)
                                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.04), lineWidth: isSelected ? 1 : 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Appearance — System / Light / Dark
                Text("Appearance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("Appearance", selection: $theme.appearanceRaw) {
                    ForEach(AppearanceStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)

                // Glass intensity
                Text("Glass Intensity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("Glass Intensity", selection: $theme.glassIntensityRaw) {
                    ForEach(GlassIntensity.allCases) { intensity in
                        Text(intensity.rawValue).tag(intensity.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )

            // Library
            VStack(alignment: .leading, spacing: 12) {
                settingsHeader("LIBRARY", icon: "books.vertical.fill")

                HStack {
                    Text("Default View")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("Default View", selection: $theme.defaultSectionRaw) {
                        ForEach([LibrarySection.tracks, .albums, .artists, .folders, .playlists]) { section in
                            Text(section.rawValue).tag(section.rawValue)
                        }
                    }
                    .labelsHidden()
                    // 160pt — matches the native toggle control width so the
                    // picker's right edge sits exactly on the toggle baseline.
                    .frame(width: 160)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Show LOSSLESS badges", isOn: $theme.showLosslessBadges)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Auto-scan library on launch", isOn: $theme.autoScanOnLaunch)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )

            // Playback
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader("PLAYBACK", icon: "hifispeaker.fill")

                Toggle("Bit-Perfect Mode", isOn: $playerState.isBitPerfectMode)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Auto-advance to next track", isOn: $theme.autoAdvance)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default Volume")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(Int(theme.defaultVolume * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $theme.defaultVolume, in: 0...1)
                        .controlSize(.small)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )

            // Sound Styles
            VStack(alignment: .leading, spacing: 12) {
                settingsHeader("SOUND STYLES", icon: "slider.horizontal.3")

                Text("Equalizer presets applied to every track.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: soundStyleColumns, spacing: 8) {
                    ForEach(EQPreset.presets) { preset in
                        let isSelected = theme.eqPresetID == preset.id
                        Button {
                            withAnimation(MicroEase) {
                                theme.eqPresetID = preset.id
                            }
                            audioEngine.applyEQPreset(preset)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                Text(preset.name)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.04), lineWidth: isSelected ? 1 : 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Apply \"\(preset.name)\" EQ")
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )

            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(.regularMaterial)
    }

    private func settingsHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(ThemeManager.shared)
        .environmentObject(PlayerState.shared)
        .environmentObject(AudioEngine.shared)
}