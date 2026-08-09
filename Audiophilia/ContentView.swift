import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Shared Animation Ease

/// Single micro-ease used across the entire app.
/// Fast (0.12s) ease-out — a single-keyframe GPU blend that feels
/// instant without springs, bounces, or overshoot.
let MicroEase = Animation.easeOut(duration: 0.12)

// MARK: - Artwork Placeholder

/// Temporary cover shown when a track/album/playlist has no artwork.
/// Renders the active theme's gradient with a subdued note so a missing
/// cover never reads as a broken image (replaces one-off music.note-on-tint).
struct ArtworkPlaceholderView: View {
    @EnvironmentObject private var theme: ThemeManager

    var cornerRadius: CGFloat = 12
    var noteSize: CGFloat = 18

    var body: some View {
        LinearGradient(
            colors: [theme.theme.topGradient, theme.theme.bottomGradient],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: noteSize, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState
    @EnvironmentObject private var theme: ThemeManager

    @State private var isSettingsPresented = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // ROOT THEME BACKDROP — fills the ENTIRE window, exactly like
            // the FullscreenPlayer. This backdrop is a fully OPAQUE theme
            // gradient, so the whole window — including the former titlebar
            // strip — shows the theme colour. The window is also marked
            // opaque (`isOpaque = true`) so the window server skips
            // compositing the desktop behind this surface (a CPU win during
            // playback). The translucent frosted materials in the sidebar /
            // canvas blend over this opaque gradient to produce the Liquid
            // Glass look.
            theme.theme.artworkGradient
                .drawingGroup()
                .ignoresSafeArea()

            // Main content — extends behind the titlebar so the theme
            // wash flows all the way up behind the traffic lights.
            HSplitView {
                SidebarView(isSettingsPresented: $isSettingsPresented)
                    .frame(minWidth: 200, idealWidth: 280, maxWidth: 340)

                MainCanvasView()
                    .frame(minWidth: 600)
            }

            // Floating Playbar
            if audioEngine.currentTrack != nil || playerState.isMiniPlayerVisible {
                FloatingPlaybar()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        // Scoped animation: only the floating playbar branch animates when a
        // track starts/stops (opacity fade). No layout animation, no shadow
        // crossfade — just a single alpha blend on the GPU.
        .animation(.easeOut(duration: 0.18), value: audioEngine.currentTrack != nil)
        // Fullscreen player presentation is handled by its own `.transition(.opacity)`
        // inside the overlay; no root re-layout animation on expand/collapse.
        .animation(nil, value: playerState.isNowPlayingExpanded)
        // Respect the user's appearance preference (System/Light/Dark).
        // The window stays opaque + theme-painted regardless; this drives the
        // frosted materials, controls, and text to the right palette.
        .preferredColorScheme(theme.appearance.colorScheme)
        // Fullscreen player overlay — replaces the entire app UI
        .overlay {
            if playerState.isNowPlayingExpanded {
                FullscreenPlayer()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .alert(
            "Playback Error",
            isPresented: Binding(
                get: { audioEngine.playbackError != nil },
                set: { if !$0 { audioEngine.playbackError = nil } }
            )
        ) {
            Button("OK") {
                audioEngine.playbackError = nil
            }
        } message: {
            Text(audioEngine.playbackError ?? "")
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environmentObject(theme)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState
    @EnvironmentObject private var theme: ThemeManager

    @Binding var isSettingsPresented: Bool

    @State private var showAddMenu = false
    @State private var showNewPlaylistSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // App title + actions (settings + "+")
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Audiophilia")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()

                // Settings button — opens the theming/settings sheet
                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.glass.surfaceMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .keyboardShortcut(",", modifiers: .command)

                // "+" button — opens a dropdown that expands toward the left
                Button {
                    showAddMenu = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.glass.surfaceMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add to Library")
                .popover(isPresented: $showAddMenu, arrowEdge: .trailing) {
                    AddToLibraryMenu(
                        onMakePlaylist: {
                            showAddMenu = false
                            showNewPlaylistSheet = true
                        },
                        onAddTracks: {
                            showAddMenu = false
                            promptForAudioFiles()
                        },
                        onAddFolder: {
                            showAddMenu = false
                            library.promptForFolder()
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // Library + Playlists + Devices sections
            List {
                Section("LIBRARY") {
                    ForEach([LibrarySection.tracks, .albums, .artists, .folders]) { section in
                        SidebarRow(
                            icon: section.icon,
                            title: section.rawValue,
                            count: count(for: section),
                            isSelected: playerState.selectedSection == section
                        ) {
                            playerState.selectedSection = section
                            playerState.selectedPlaylist = nil
                            playerState.selectedFolder = nil
                        }
                    }
                }

                if !library.playlists.isEmpty {
                    Section("PLAYLISTS") {
                        ForEach(library.playlists) { playlist in
                            Button {
                                playerState.selectedPlaylist = playlist
                                playerState.selectedSection = .playlists
                            } label: {
                                HStack(spacing: 10) {
                                    // Mini cover or icon
                                    ZStack {
                                        if let coverPath = playlist.coverImagePath,
                                           let cover = NSImage(contentsOfFile: coverPath) {
                                            Image(nsImage: cover)
                                                .resizable()
                                                .frame(width: 20, height: 20)
                                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                        } else {
                                            ArtworkPlaceholderView(cornerRadius: 5, noteSize: 9)
                                                .frame(width: 20, height: 20)
                                        }
                                    }
                                    Text(playlist.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(playlist.trackIDs.count)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(playerState.selectedPlaylist?.id == playlist.id ? Color.accentColor.opacity(0.15) : .clear)
                            )
                        }
                    }
                }

                Section("DEVICES") {
                    ForEach(audioEngine.availableDevices) { device in
                        DeviceRow(
                            device: device,
                            isActive: audioEngine.activeDevice?.id == device.id
                        ) {
                            audioEngine.selectDevice(device)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // Scan progress (stays above the floating playbar)
            if library.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: library.scanProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    Text("Scanning library…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        // Keep the bottom of the sidebar above the floating playbar — applied
        // BEFORE the background so the theme wash + frosted material extend
        // through the entire playbar overlap zone (no grey strip).
        .padding(.bottom, 110)
        .background {
            // Liquid Glass: frosted material + subtle theme accent wash.
            // Extends behind the titlebar so the theme colour reaches
            // all the way up behind the traffic lights.
            ZStack {
                Rectangle().fill(theme.glass.backgroundMaterial)
                theme.theme.backgroundGradient
            }
            // 1px top-edge specular rim — reads as the glass highlight
            // sitting beneath the unified titlebar.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 1)
            }
            .ignoresSafeArea(edges: .top)
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistSheet()
        }
    }

    private func count(for section: LibrarySection) -> Int {
        switch section {
        case .tracks: return library.tracks.count
        case .albums: return library.albums.count
        case .artists: return library.artists.count
        case .folders: return library.folders.count
        case .playlists: return library.playlists.count
        case .devices: return audioEngine.availableDevices.count
        }
    }

    private func promptForAudioFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add Music Tracks"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select audio files to add to your library"
        panel.allowedContentTypes = [.audio]

        if panel.runModal() == .OK {
            library.importTrackFiles(panel.urls)
        }
    }
}

// MARK: - Add To Library Menu

/// Dropdown shown when pressing the "+" button in the sidebar header.
/// The popover arrow points right, so the menu content expands toward the left.
struct AddToLibraryMenu: View {
    let onMakePlaylist: () -> Void
    let onAddTracks: () -> Void
    let onAddFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Make a new playlist
            MenuItemButton(icon: "music.note.list", title: "Make a new playlist", action: onMakePlaylist)

            // Add music track
            MenuItemButton(icon: "music.note", title: "Add music track", action: onAddTracks)

            // Upload music folder
            MenuItemButton(icon: "folder.badge.plus", title: "Upload music folder", action: onAddFolder)
        }
        .padding(6)
        .frame(width: 200)
    }
}

/// A single row inside the Add To Library dropdown.
private struct MenuItemButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - New Playlist Sheet

/// Sheet presented when the user chooses "Make a new playlist".
/// Includes a name field and an optional cover image picker.
struct NewPlaylistSheet: View {
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var coverImage: NSImage?
    @State private var coverImagePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Playlist")
                .font(.system(size: 17, weight: .bold))

            HStack(alignment: .top, spacing: 16) {
                // Cover image picker (optional)
                Button {
                    pickCoverImage()
                } label: {
                    ZStack {
                        if let coverImage {
                            Image(nsImage: coverImage)
                                .resizable()
                                .aspectRatio(1, contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .overlay {
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo.badge.plus")
                                            .font(.system(size: 22, weight: .light))
                                            .foregroundStyle(.secondary)
                                        Text("Add Cover")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                        }
                    }
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose a cover image (optional)")

                // Name field
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .frame(width: 180)
            }

            // Actions
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    library.createPlaylist(name: name, coverImagePath: coverImagePath)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func pickCoverImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Cover Image"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        guard let image = NSImage(contentsOf: url) else { return }
        coverImage = image

        // Copy the cover into the app's support directory so it persists
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Audiophilia", isDirectory: true)
        let coversDir = appSupport.appendingPathComponent("PlaylistCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)

        let extensionName = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let destination = coversDir.appendingPathComponent("\(UUID().uuidString).\(extensionName)")
        try? FileManager.default.copyItem(at: url, to: destination)
        coverImagePath = destination.path
    }
}

/// Standard sidebar navigation row.
struct SidebarRow: View {
    let icon: String
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
    }
}

struct DeviceRow: View {
    let device: AudioDevice
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: device.isUSB ? "cable.connector" : "hifispeaker")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(device.transportType) · \(Int(device.currentSampleRate)) Hz")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.15) : .clear)
        )
    }
}

// MARK: - Main Canvas

struct MainCanvasView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var playerState: PlayerState
    @EnvironmentObject private var theme: ThemeManager
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(playerState.isSearchActive ? "Search" : title)
                    .font(.system(size: 24, weight: .bold))
                Spacer()

                // Search field with clear button
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(playerState.isSearchActive ? Color.accentColor : .secondary)
                    TextField("Search", text: $playerState.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isSearchFocused)
                        .onExitCommand {
                            clearSearch()
                        }
                    // Clear button — appears only when there's text
                    if !playerState.searchText.isEmpty {
                        Button {
                            clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.glass.surfaceMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            playerState.isSearchActive ? theme.theme.accent.opacity(0.5) : Color.white.opacity(0.12),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .frame(width: 200)
                .onExitCommand {
                    clearSearch()
                }

                // Mini player toggle
                Button {
                    playerState.isMiniPlayerVisible.toggle()
                } label: {
                    Image(systemName: "pip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(playerState.isMiniPlayerVisible ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Mini Player")
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)

            // Content
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120) // Space for floating playbar
            }
        }
        .background {
            // Liquid Glass: frosted material + subtle theme accent wash.
            // Extends behind the titlebar so the theme colour reaches
            // all the way up behind the traffic lights.
            ZStack {
                Rectangle().fill(theme.glass.backgroundMaterial)
                theme.theme.backgroundGradient
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 1)
            }
            .ignoresSafeArea(edges: .top)
        }
        // ⌘F to focus the search field
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FocusSearch"))) { _ in
            isSearchFocused = true
        }
    }

    private var title: String {
        switch playerState.selectedSection {
        case .tracks: return "Tracks"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .folders: return "Folders"
        case .playlists: return "Playlists"
        case .devices: return "Audio Devices"
        }
    }

    @ViewBuilder
    private var content: some View {
        if playerState.isSearchActive {
            SearchResultsView()
        } else if playerState.selectedSection == .playlists, let playlist = playerState.selectedPlaylist {
            PlaylistDetailView(playlist: playlist)
        } else if playerState.selectedSection == .folders, let folder = playerState.selectedFolder {
            FolderDetailView(folder: folder)
        } else {
            switch playerState.selectedSection {
            case .albums:
                AlbumGridView(albums: library.albums)
            case .tracks:
                TrackListView(tracks: library.tracks)
            case .artists:
                ArtistGridView(artists: library.artists)
            case .folders:
                FolderListView()
            case .playlists:
                PlaylistView()
            case .devices:
                DeviceListView()
            }
        }
    }

    private func clearSearch() {
        playerState.searchText = ""
        isSearchFocused = false
    }
}

// MARK: - Search Results

/// Unified global search results view. Shown whenever the search field
/// contains text — it replaces the current section with grouped results
/// for tracks, albums, artists, and playlists.
struct SearchResultsView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)
    ]

    private var query: String {
        playerState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchedTracks: [Track] {
        guard !query.isEmpty else { return [] }
        return library.tracks.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) ||
            $0.displayArtist.localizedCaseInsensitiveContains(query) ||
            $0.displayAlbum.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchedAlbums: [Album] {
        guard !query.isEmpty else { return [] }
        return library.albums.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artist.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchedArtists: [Artist] {
        guard !query.isEmpty else { return [] }
        return library.artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var matchedPlaylists: [Playlist] {
        guard !query.isEmpty else { return [] }
        return library.playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if matchedTracks.isEmpty && matchedAlbums.isEmpty && matchedArtists.isEmpty && matchedPlaylists.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No matches found for “\(query)”")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                // Tracks
                if !matchedTracks.isEmpty {
                    SearchSectionHeader(title: "Tracks", count: matchedTracks.count)
                    LazyVStack(spacing: 2) {
                        ForEach(matchedTracks) { track in
                            TrackRow(track: track, isPlaying: audioEngine.currentTrack?.id == track.id && audioEngine.playbackState == .playing)
                                .equatable()
                                .onTapGesture {
                                    audioEngine.play(track: track, in: matchedTracks)
                                    playerState.isNowPlayingExpanded = true
                                }
                                .richTrackContextMenu(track: track, tracksList: matchedTracks)
                        }
                    }
                }

                // Albums
                if !matchedAlbums.isEmpty {
                    SearchSectionHeader(title: "Albums", count: matchedAlbums.count)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(matchedAlbums) { album in
                            AlbumCard(album: album)
                                .onTapGesture {
                                    audioEngine.playQueue(album.tracks, startAt: 0)
                                    playerState.isNowPlayingExpanded = true
                                }
                        }
                    }
                }

                // Artists
                if !matchedArtists.isEmpty {
                    SearchSectionHeader(title: "Artists", count: matchedArtists.count)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(matchedArtists) { artist in
                            ArtistResultCard(artist: artist)
                                .onTapGesture {
                                    let tracks = artist.albums.flatMap { $0.tracks }
                                    audioEngine.playQueue(tracks, startAt: 0)
                                    playerState.isNowPlayingExpanded = true
                                }
                        }
                    }
                }

                // Playlists
                if !matchedPlaylists.isEmpty {
                    SearchSectionHeader(title: "Playlists", count: matchedPlaylists.count)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(matchedPlaylists) { playlist in
                            PlaylistCard(playlist: playlist)
                                .onTapGesture {
                                    playerState.selectedPlaylist = playlist
                                    playerState.selectedSection = .playlists
                                    playerState.searchText = ""
                                }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

/// Small header above each search result group.
private struct SearchSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Compact artist card for search results.
private struct ArtistResultCard: View {
    let artist: Artist

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "person.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Text(artist.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Text("\(artist.trackCount) tracks")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Album Grid

struct AlbumGridView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState

    let albums: [Album]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 24) {
            ForEach(albums) { album in
                AlbumCard(album: album)
                    .onTapGesture {
                        playerState.selectedAlbum = album
                        audioEngine.playQueue(album.tracks, startAt: 0)
                        playerState.isNowPlayingExpanded = true
                    }
            }
        }
        .padding(.top, 8)
    }
}

struct AlbumCard: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var theme: ThemeManager

    let album: Album
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork
            ZStack(alignment: .bottomTrailing) {
                if let artwork = library.artwork(for: album) {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            // Liquid Glass rim: subtle white highlight forming
                            // a "glass edge" around the artwork.
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.theme.artworkGradient)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                }

                // Lossless badge
                if album.isLossless && theme.showLosslessBadges {
                    Text("LOSSLESS")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .padding(8)
                }
            }
            // Zero-transform hover: a soft highlight overlay + constant shadow.
            // No scale, no spring — just a single opacity blend on the GPU.
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
                    .animation(MicroEase, value: isHovering)
            )
            // Constant shadow — never animates.
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            // Title
            Text(album.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            // Artist + specs
            VStack(alignment: .leading, spacing: 2) {
                Text(album.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(album.resolutionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Track List

struct TrackListView: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    let tracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("\(tracks.count) tracks")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 4)

            // Track rows
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track, isPlaying: audioEngine.currentTrack?.id == track.id && audioEngine.playbackState == .playing)
                        .equatable()
                        .onTapGesture {
                            audioEngine.play(track: track, in: tracks)
                        }
                        .richTrackContextMenu(track: track, tracksList: tracks)
                }
            }
        }
        .padding(.top, 8)
    }
}

struct TrackRow: View, Equatable {
    @EnvironmentObject private var theme: ThemeManager

    let track: Track
    let isPlaying: Bool

    @State private var isHovering = false

    static func == (lhs: TrackRow, rhs: TrackRow) -> Bool {
        lhs.track == rhs.track && lhs.isPlaying == rhs.isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number or playing indicator
            ZStack {
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(track.trackNumber > 0 ? track.trackNumber : 0)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)

            // Title
            Text(track.displayTitle)
                .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                .lineLimit(1)

            Spacer()

            // Lossless badge
            if track.isLossless && theme.showLosslessBadges {
                Text("LOSSLESS")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15), in: Capsule())
            }

            // Specs
            Text(track.specsShortLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            // Duration
            Text(track.durationLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.white.opacity(0.07) : .clear)
                .animation(MicroEase, value: isHovering)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering ? Color.white.opacity(0.1) : Color.clear, lineWidth: 0.5)
                .animation(MicroEase, value: isHovering)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Artist Grid

struct ArtistGridView: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState

    let artists: [Artist]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 24) {
            ForEach(artists) { artist in
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 120, height: 120)
                        Image(systemName: "person.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Text(artist.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text("\(artist.trackCount) tracks")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .onTapGesture {
                    playerState.selectedArtist = artist
                    let tracks = artist.albums.flatMap { $0.tracks }
                    audioEngine.playQueue(tracks, startAt: 0)
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Folder List

struct FolderListView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var playerState: PlayerState

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if library.folders.isEmpty {
                ContentUnavailableView(
                    "No Music Folders",
                    systemImage: "folder.badge.plus",
                    description: Text("Add folders to build your local library")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(library.folders, id: \.self) { folder in
                        FolderCard(folder: folder)
                            .onTapGesture {
                                playerState.selectedFolder = folder
                            }
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

/// Grid card for a music folder. Click to open and play.
struct FolderCard: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var theme: ThemeManager

    let folder: URL

    @State private var isHovering = false

    var body: some View {
        let tracks = library.tracks(inFolder: folder)

        VStack(alignment: .leading, spacing: 8) {
            // Artwork — folder icon in a squircle
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.theme.artworkGradient.opacity(0.9))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                // Play overlay on hover
                if isHovering {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .padding(12)
                        .transition(.scale.combined(with: .opacity))
                }

                // Track count badge
                Text("\(tracks.count)")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .padding(8)
            }
            // Constant shadow — hover animates scale only (GPU-friendly).
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
                    .animation(MicroEase, value: isHovering)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            // Folder name
            Text(folder.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            // Meta
            Text("\(tracks.count) tracks · \(tracks.reduce(0) { $0 + $1.duration } > 0 ? Track.timeString(tracks.reduce(0) { $0 + $1.duration }) : "0:00")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Folder Detail View

/// Full folder detail page. Shows all tracks inside a folder with
/// Play All, Shuffle, and per-track playback.
struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState
    @EnvironmentObject private var theme: ThemeManager

    let folder: URL

    @State private var isBackHovering = false
    @State private var isFolderIconHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Back button — animated
            Button {
                playerState.selectedFolder = nil
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(isBackHovering ? Color.primary : Color.secondary)
                .animation(MicroEase, value: isBackHovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isBackHovering = hovering
            }
            .help("Back to folders")

            // Header: folder icon + info + controls
            HStack(spacing: 20) {
                // Folder icon — click to open fullscreen player
                Button {
                    playerState.isNowPlayingExpanded = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 100, height: 100)
                            .overlay {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(isFolderIconHovering ? 0.2 : 0))
                    )
                    .overlay {
                        if isFolderIconHovering {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                    .animation(MicroEase, value: isFolderIconHovering)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isFolderIconHovering = hovering
                }
                .help("Open Fullscreen Player")

                VStack(alignment: .leading, spacing: 10) {
                    Text(folder.lastPathComponent)
                        .font(.system(size: 24, weight: .bold))

                    // Track count + duration
                    HStack(spacing: 6) {
                        Text("\(tracks.count) tracks")
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(totalDurationLabel)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    // Controls: Shuffle + Play All
                    HStack(spacing: 14) {
                        CapsuleActionButton(
                            icon: "shuffle",
                            title: "Shuffle",
                            isActive: audioEngine.isShuffleEnabled,
                            help: "Toggle shuffle"
                        ) {
                            audioEngine.isShuffleEnabled.toggle()
                            playShuffled()
                        }

                        CapsuleActionButton(
                            icon: "play.fill",
                            title: "Play All",
                            isProminent: true,
                            help: "Play all tracks"
                        ) {
                            if !tracks.isEmpty {
                                audioEngine.playQueue(tracks, startAt: 0)
                                playerState.isNowPlayingExpanded = true
                            }
                        }
                    }
                }

                Spacer()
            }

            Divider()

            // Track list
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks in this Folder",
                    systemImage: "folder",
                    description: Text("Add music files to this folder to see them here")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        FolderTrackRow(
                            track: track,
                            index: index,
                            tracks: tracks,
                            isPlaying: audioEngine.currentTrack?.id == track.id && audioEngine.playbackState == .playing
                        )
                        .equatable()
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.glass.surfaceMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }
        }
        .padding(.top, 20)
    }

    private var tracks: [Track] {
        library.tracks(inFolder: folder)
    }

    private var totalDurationLabel: String {
        let total = tracks.reduce(0) { $0 + $1.duration }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 {
            return String(format: "%d hr %d min", hours, minutes)
        }
        return String(format: "%d min", minutes)
    }

    private func playShuffled() {
        guard !tracks.isEmpty else { return }
        let startIndex = Int.random(in: 0..<tracks.count)
        audioEngine.playQueue(tracks, startAt: startIndex)
        playerState.isNowPlayingExpanded = true
    }
}

/// Track row inside the folder detail view (same layout as playlist tracks).
struct FolderTrackRow: View, Equatable {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine

    let track: Track
    let index: Int
    let tracks: [Track]
    let isPlaying: Bool

    @State private var isHovering = false

    static func == (lhs: FolderTrackRow, rhs: FolderTrackRow) -> Bool {
        lhs.track == rhs.track && lhs.isPlaying == rhs.isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            // Cover thumbnail (44pt)
            ZStack {
                if let artwork = library.artwork(for: track) {
                    Image(nsImage: artwork)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ArtworkPlaceholderView(cornerRadius: 8, noteSize: 14)
                        .frame(width: 44, height: 44)
                }

                // Playing badge overlay
                if isPlaying {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .offset(x: 14, y: 14)
                }
            }
            .frame(width: 44, height: 44)

            // Title
            Text(track.displayTitle)
                .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                .lineLimit(1)

            Spacer()

            // Lossless badge / specs
            if track.isLossless {
                Text("LOSSLESS")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15), in: Capsule())
                    .frame(width: 70, alignment: .leading)
            } else {
                Text(track.specsShortLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .leading)
            }

            // Artist
            Text(track.displayArtist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            // Album
            Text(track.displayAlbum)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            // Duration
            Text(track.durationLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.white.opacity(0.07) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering ? Color.white.opacity(0.1) : Color.clear, lineWidth: 0.5)
        )
        .animation(MicroEase, value: isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            audioEngine.play(track: track, in: tracks)
        }
        // Rich right-click context menu — folder rows get Remove from Library
        .richTrackContextMenu(track: track, tracksList: tracks)
    }
}

// MARK: - Playlist View

struct PlaylistView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var playerState: PlayerState

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if library.playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists Yet",
                    systemImage: "music.note.list",
                    description: Text("Press the + button to make a new playlist")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(library.playlists) { playlist in
                        PlaylistCard(playlist: playlist)
                            .onTapGesture {
                                playerState.selectedPlaylist = playlist
                                playerState.selectedSection = .playlists
                            }
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Playlist Detail View

/// Full playlist detail page shown when a playlist is opened.
/// Displays cover, name, track count, duration, playback controls,
/// and options to add music from files or folders.
struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState
    @EnvironmentObject private var theme: ThemeManager

    let playlist: Playlist

    @State private var isCoverHovering = false
    @State private var isAddTracksHovering = false
    @State private var isAddFolderHovering = false
    @State private var isDeleteHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header: cover + info + controls
            HStack(spacing: 20) {
                // Cover — click to open fullscreen player
                Button {
                    playerState.isNowPlayingExpanded = true
                } label: {
                    ZStack {
                        if let coverPath = playlist.coverImagePath,
                           let cover = NSImage(contentsOfFile: coverPath) {
                            Image(nsImage: cover)
                                .resizable()
                                .frame(width: 100, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 100, height: 100)
                                .overlay {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 32, weight: .light))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(isCoverHovering ? 0.2 : 0))
                    )
                    .overlay {
                        if isCoverHovering {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                    .animation(MicroEase, value: isCoverHovering)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCoverHovering = hovering
                }
                .help("Open Fullscreen Player")

                VStack(alignment: .leading, spacing: 10) {
                    Text(playlist.name)
                        .font(.system(size: 24, weight: .bold))

                    // Track count + duration
                    HStack(spacing: 6) {
                        Text("\(tracks.count) tracks")
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(totalDurationLabel)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    // Controls: Shuffle, Repeat, Play
                    HStack(spacing: 14) {
                        CapsuleActionButton(
                            icon: "shuffle",
                            title: "Shuffle",
                            isActive: audioEngine.isShuffleEnabled,
                            help: "Toggle shuffle"
                        ) {
                            audioEngine.isShuffleEnabled.toggle()
                            playShuffled()
                        }

                        CapsuleActionButton(
                            icon: "repeat",
                            title: "Repeat",
                            isActive: audioEngine.isRepeatEnabled,
                            help: "Toggle repeat"
                        ) {
                            audioEngine.isRepeatEnabled.toggle()
                        }

                        CapsuleActionButton(
                            icon: "play.fill",
                            title: "Play All",
                            isProminent: true,
                            help: "Play all tracks"
                        ) {
                            let tracks = library.tracks(inPlaylist: playlist)
                            if !tracks.isEmpty {
                                audioEngine.playQueue(tracks, startAt: 0)
                                playerState.isNowPlayingExpanded = true
                            }
                        }
                    }
                }

                Spacer()

                // Change playlist cover image
                IconActionButton(
                    icon: "photo.on.rectangle.angled",
                    size: 13,
                    color: .secondary,
                    help: "Change cover image"
                ) {
                    changePlaylistCover()
                }

                // Delete playlist
                IconActionButton(
                    icon: "trash",
                    size: 13,
                    color: .secondary,
                    help: "Delete playlist"
                ) {
                    library.deletePlaylist(id: playlist.id)
                    playerState.selectedPlaylist = nil
                    playerState.selectedSection = .playlists
                }
            }

            // Add music buttons
            HStack(spacing: 12) {
                // Add individual tracks
                AddMusicButton(
                    icon: "plus.circle",
                    title: "Add Music Tracks",
                    isHovering: isAddTracksHovering
                ) {
                    let panel = NSOpenPanel()
                    panel.title = "Add Music Tracks to Playlist"
                    panel.prompt = "Add"
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = true
                    panel.message = "Select audio files to add to \"\(playlist.name)\""
                    panel.allowedContentTypes = [.audio]

                    if panel.runModal() == .OK {
                        library.importTrackFiles(panel.urls) { trackIDs in
                            library.addTracks(trackIDs, to: playlist.id)
                        }
                    }
                }
                .onHover { hovering in
                    isAddTracksHovering = hovering
                }

                // Add entire folder
                AddMusicButton(
                    icon: "folder.badge.plus",
                    title: "Add Music Folder",
                    isHovering: isAddFolderHovering
                ) {
                    let panel = NSOpenPanel()
                    panel.title = "Add Music Folder to Playlist"
                    panel.prompt = "Add"
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    panel.message = "Select folders to scan for audio and add to \"\(playlist.name)\""

                    if panel.runModal() == .OK {
                        for url in panel.urls {
                            library.addFolderToPlaylist(url, playlistID: playlist.id)
                        }
                    }
                }
                .onHover { hovering in
                    isAddFolderHovering = hovering
                }
            }

            Divider()

            // Track list
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No Tracks in this Playlist",
                    systemImage: "music.note",
                    description: Text("Add music from files or folders to get started")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        PlaylistTrackRow(
                            playlist: playlist,
                            track: track,
                            index: index,
                            tracks: tracks,
                            isPlaying: audioEngine.currentTrack?.id == track.id && audioEngine.playbackState == .playing
                        )
                        .equatable()
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.glass.surfaceMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }
        }
        .padding(.top, 20)
    }

    private var tracks: [Track] {
        library.tracks(inPlaylist: playlist)
    }

    private var totalDurationLabel: String {
        let total = tracks.reduce(0) { $0 + $1.duration }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 {
            return String(format: "%d hr %d min", hours, minutes)
        }
        return String(format: "%d min", minutes)
    }

    private func playShuffled() {
        let tracks = library.tracks(inPlaylist: playlist)
        guard !tracks.isEmpty else { return }
        let startIndex = Int.random(in: 0..<tracks.count)
        audioEngine.playQueue(tracks, startAt: startIndex)
        playerState.isNowPlayingExpanded = true
    }

    /// Opens an image picker and sets the selected image as the playlist cover.
    /// The chosen file is copied into the app's `PlaylistCovers` directory so it
    /// persists, and the selection is pushed back into the sidebar state so the
    /// header and grid cards all reflect the new cover immediately.
    private func changePlaylistCover() {
        let panel = NSOpenPanel()
        panel.title = "Change Playlist Cover"
        panel.prompt = "Change"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Audiophilia", isDirectory: true)
        let coversDir = appSupport.appendingPathComponent("PlaylistCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)

        let extensionName = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let destination = coversDir.appendingPathComponent("\(UUID().uuidString).\(extensionName)")
        try? FileManager.default.copyItem(at: url, to: destination)

        library.setPlaylistCover(playlistID: playlist.id, coverImagePath: destination.path)

        // Update selection so the detail header re-renders with the new cover.
        if let updated = library.playlists.first(where: { $0.id == playlist.id }) {
            playerState.selectedPlaylist = updated
        }
    }
}

/// Card for a saved playlist in the grid.
struct PlaylistCard: View {
    @EnvironmentObject private var library: LibraryManager

    let playlist: Playlist
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork
            ZStack(alignment: .topTrailing) {
                if let coverPath = playlist.coverImagePath,
                   let cover = NSImage(contentsOfFile: coverPath) {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }

                // Track count badge
                Text("\(playlist.trackIDs.count)")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .padding(8)
            }
            // Liquid Glass rim around the playlist artwork.
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            // Zero-transform hover: a soft highlight overlay + constant shadow.
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
                    .animation(MicroEase, value: isHovering)
            )
            // Constant shadow — never animates.
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            // Name
            Text(playlist.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            // Meta
            Text("\(playlist.trackIDs.count) songs")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Device List

struct DeviceListView: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(audioEngine.availableDevices) { device in
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(device.isUSB ? Color.blue.opacity(0.15) : Color.gray.opacity(0.1))
                            .frame(width: 48, height: 48)
                        Image(systemName: device.isUSB ? "cable.connector" : "hifispeaker")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(device.isUSB ? Color.blue : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.system(size: 14, weight: .semibold))
                            if device.isDefault {
                                Text("DEFAULT")
                                    .font(.system(size: 8, weight: .bold))
                                    .tracking(0.5)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        Text("\(device.manufacturer) · \(device.transportType)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Sample rates
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(device.sampleRates.enumerated()), id: \.element) { _, rate in
                                let isCurrent = rate == device.currentSampleRate
                                let rateString = formatRate(rate)
                                VStack {
                                    Text(rateString)
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isCurrent ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                                )
                                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 200)

                    // Select button
                    Button {
                        audioEngine.selectDevice(device)
                    } label: {
                        Text(audioEngine.activeDevice?.id == device.id ? "Active" : "Select")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(audioEngine.activeDevice?.id == device.id ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.1))
                            )
                            .foregroundStyle(audioEngine.activeDevice?.id == device.id ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.08))
                )
            }
        }
        .padding(.top, 8)
    }

    private func formatRate(_ rate: Double) -> String {
        if rate >= 1_000_000 {
            return String(format: "%.1fM", rate / 1_000_000)
        }
        return String(format: "%.0fk", rate / 1000)
    }
}

// MARK: - Mini Seekbar

/// Drives the one-second seekbar refresh on a BACKGROUND queue.
///
/// The dispatch source timer fires on `DispatchQueue.global(qos: .utility)`,
/// never on the main runloop. Each tick performs a single main-thread hop
/// (`Task { @MainActor }`) to poll the engine's playback position and bump
/// `tick`. Only `MiniSeekbarView` observes this object, so nothing else in
/// the view hierarchy is invalidated during playback.
private final class SeekbarPoller: ObservableObject {
    @Published private(set) var tick = 0

    private var timer: DispatchSourceTimer?
    private weak var audioEngine: AudioEngine?

    func start(audioEngine: AudioEngine) {
        guard timer == nil else { return }
        self.audioEngine = audioEngine

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            // One main-thread hop per second. The utility queue never
            // touches UI or engine state directly.
            Task { @MainActor [weak self] in
                guard let self,
                      let engine = self.audioEngine,
                      engine.playbackState == .playing else { return }
                engine.refreshCurrentTime()
                self.tick &+= 1
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        timer?.cancel()
    }
}

/// The time labels + waveform seekbar, extracted into their own view so ONLY
/// this small component re-renders when `currentTime` ticks at 1Hz. The rest
/// of the FloatingPlaybar (transport buttons, track info, volume) stays
/// static — a big CPU/GPU win over re-evaluating the whole playbar.
///
/// `currentTime` is intentionally NOT @Published on the engine (publishing it
/// re-rendered every AudioEngine observer — the main CPU spike). This view
/// polls via `SeekbarPoller`, whose dispatch-source timer fires on
/// `DispatchQueue.global(qos: .utility)` — the main thread is only woken by
/// a single hop per second to update this tiny view.
private struct MiniSeekbarView: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    @StateObject private var poller = SeekbarPoller()

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(Track.timeString(isDragging ? dragTime : audioEngine.currentTime))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            GeometryReader { geo in
                WaveformSeekbar(
                    progress: isDragging ? dragTime / max(audioEngine.duration, 0.01) : (audioEngine.duration > 0 ? audioEngine.currentTime / audioEngine.duration : 0),
                    isPlaying: audioEngine.playbackState == .playing
                )
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let width = max(geo.size.width, 1)
                            let ratio = min(max(value.location.x / width, 0), 1)
                            dragTime = ratio * audioEngine.duration
                        }
                        .onEnded { _ in
                            audioEngine.seek(to: dragTime)
                            isDragging = false
                        }
                )
            }
            .frame(height: 32)

            Text(Track.timeString(audioEngine.duration))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        // Start/stop the background poller with the view's lifecycle. The
        // timer itself runs on a utility queue; each tick does a single
        // main-thread hop to refresh the position and bump the local tick.
        .onAppear {
            poller.start(audioEngine: audioEngine)
        }
        .onDisappear {
            poller.stop()
        }
    }
}

// MARK: - Floating Playbar

struct FloatingPlaybar: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var playerState: PlayerState
    @EnvironmentObject private var theme: ThemeManager

    @State private var isPlayPauseHovering = false
    @State private var isArtworkHovering = false
    @State private var isShuffleHovering = false
    @State private var isPreviousHovering = false
    @State private var isNextHovering = false

    var body: some View {
        HStack(spacing: 20) {
            // Left: Transport + thumbnail
            HStack(spacing: 14) {
                // Mini artwork — click to toggle the Now Playing panel
                Button {
                    playerState.isNowPlayingExpanded.toggle()
                } label: {
                    Group {
                        if let track = audioEngine.currentTrack,
                           let artwork = library.artwork(for: track) {
                            Image(nsImage: artwork)
                                .resizable()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            ArtworkPlaceholderView(cornerRadius: 10, noteSize: 16)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(isArtworkHovering ? 0.1 : 0))
                            .animation(MicroEase, value: isArtworkHovering)
                    )
                    // Constant shadow — never animates.
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isArtworkHovering = hovering
                }
                .help("Toggle Now Playing")

                // Transport controls
                HStack(spacing: 12) {
                    // Shuffle with hover scale
                    Button {
                        audioEngine.isShuffleEnabled.toggle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                audioEngine.isShuffleEnabled ? Color.accentColor : (isShuffleHovering ? Color.primary : Color.secondary)
                            )
                            .animation(MicroEase, value: isShuffleHovering)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isShuffleHovering = hovering
                    }
                    .help("Toggle shuffle")

                    // Previous — color-only hover
                    Button {
                        audioEngine.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isPreviousHovering ? Color.primary : Color.secondary)
                            .animation(MicroEase, value: isPreviousHovering)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isPreviousHovering = hovering
                    }
                    .help("Previous track")

                    // Play/Pause — opacity-only hover on the circle fill
                    Button {
                        audioEngine.togglePlayPause()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(isPlayPauseHovering ? 0.85 : 1.0))
                                .frame(width: 36, height: 36)
                            Image(systemName: audioEngine.playbackState == .playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: audioEngine.playbackState == .playing ? 0 : 1)
                        }
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        .animation(MicroEase, value: isPlayPauseHovering)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isPlayPauseHovering = hovering
                    }
                    .help("Play / Pause")

                    // Next — color-only hover
                    Button {
                        audioEngine.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isNextHovering ? Color.primary : Color.secondary)
                            .animation(MicroEase, value: isNextHovering)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isNextHovering = hovering
                    }
                    .help("Next track")
                }
            }

            // Center: Track info + waveform seekbar + bit-perfect badge
            VStack(spacing: 6) {
                // Track info
                HStack(spacing: 8) {
                    if let track = audioEngine.currentTrack {
                        Text(track.displayTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(track.displayArtist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()

                    // Bit-perfect badge
                    if audioEngine.isBitPerfect, let track = audioEngine.currentTrack {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                            Text("BIT-PERFECT")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.5)
                            Text("\(track.specsShortLabel)")
                                .font(.system(size: 9, weight: .medium))
                            if let device = audioEngine.activeDevice {
                                Text("· \(device.name)")
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.green.opacity(0.3), lineWidth: 0.5)
                        )
                        .foregroundStyle(.green)
                    }
                }

                // Waveform seekbar — isolated in its own view so only this
                // small component re-renders when currentTime ticks.
                MiniSeekbarView()
            }

            // Right: Volume
            HStack(spacing: 8) {
                Image(systemName: audioEngine.volume == 0 ? "speaker.slash.fill" : (audioEngine.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Slider(value: $audioEngine.volume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 100)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            // Liquid Glass playbar: theme gradient wash over frosted material,
            // 18pt squircle corners (not a rounded pill), and a 1px top-edge
            // white highlight for the glass rim.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.glass.surfaceMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.theme.topGradient.opacity(0.32),
                                    theme.theme.bottomGradient.opacity(0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        )
    }
}

// MARK: - Playlist Track Row

/// A single track row inside the playlist detail view.
/// Shows a 44pt album-artwork thumbnail, aligned title/artist/album/duration
/// columns, and a right-click context menu for playlist management.
struct PlaylistTrackRow: View, Equatable {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState

    let playlist: Playlist
    let track: Track
    let index: Int
    let tracks: [Track]
    let isPlaying: Bool

    @State private var isHovering = false
    @State private var showSongInfo = false
    @State private var showTransferMenu = false

    static func == (lhs: PlaylistTrackRow, rhs: PlaylistTrackRow) -> Bool {
        lhs.track == rhs.track && lhs.isPlaying == rhs.isPlaying && lhs.playlist.id == rhs.playlist.id
    }

    var body: some View {
        HStack(spacing: 12) {
            // Cover thumbnail (44pt) instead of track number
            ZStack {
                if let artwork = library.artwork(for: track) {
                    Image(nsImage: artwork)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ArtworkPlaceholderView(cornerRadius: 8, noteSize: 14)
                        .frame(width: 44, height: 44)
                }

                // Playing badge overlay
                if isPlaying {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .offset(x: 14, y: 14)
                }
            }
            .frame(width: 44, height: 44)

            // Title
            Text(track.displayTitle)
                .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                .lineLimit(1)

            Spacer()

            // Lossless badge
            if track.isLossless {
                Text("LOSSLESS")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15), in: Capsule())
                    .frame(width: 70, alignment: .leading)
            } else {
                // Specs short label to keep alignment
                Text(track.specsShortLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .leading)
            }

            // Artist
            Text(track.displayArtist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            // Album
            Text(track.displayAlbum)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            // Duration
            Text(track.durationLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            // Context menu button (chevron appears on hover)
            Button {
                showTransferMenu = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHovering ? Color.secondary : Color.clear)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTransferMenu, arrowEdge: .bottom) {
                TrackContextMenuView(
                    track: track,
                    playlist: playlist,
                    tracks: tracks
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.white.opacity(0.07) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering ? Color.white.opacity(0.1) : Color.clear, lineWidth: 0.5)
        )
        .animation(MicroEase, value: isHovering)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            audioEngine.play(track: track, in: tracks)
        }
        // Rich right-click context menu adapted for playlist rows
        .richTrackContextMenu(
            track: track,
            tracksList: tracks,
            playlist: playlist
        )
    }

    /// All playlists other than the one this track currently belongs to.
    private var otherPlaylists: [Playlist] {
        library.playlists.filter { $0.id != playlist.id }
    }
}

// MARK: - Track Context Menu Popover

/// Popover shown when clicking the ellipsis button on a playlist track row.
struct TrackContextMenuView: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState
    @Environment(\.dismiss) private var dismiss

    let track: Track
    let playlist: Playlist
    let tracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ContextMenuItem(icon: "play.fill", title: "Play") {
                let queue = library.tracks(inPlaylist: playlist)
                if !queue.isEmpty {
                    audioEngine.play(track: track, in: queue)
                    playerState.isNowPlayingExpanded = true
                }
                dismiss()
            }

            Divider()
                .padding(.vertical, 4)

            ContextMenuItem(icon: "minus.circle", title: "Remove from Playlist", tint: .red) {
                library.removeTrackFromPlaylist(trackID: track.id, playlistID: playlist.id)
                dismiss()
            }

            Text("MOVE TO PLAYLIST")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(otherPlaylists) { target in
                ContextMenuItem(icon: "arrow.right.circle", title: target.name) {
                    library.removeTrackFromPlaylist(trackID: track.id, playlistID: playlist.id)
                    library.addTracks([track.id], to: target.id)
                    dismiss()
                }
            }

            Text("COPY TO PLAYLIST")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(otherPlaylists) { target in
                ContextMenuItem(icon: "plus.circle", title: target.name) {
                    library.addTracks([track.id], to: target.id)
                    dismiss()
                }
            }

            Divider()
                .padding(.vertical, 4)

            ContextMenuItem(icon: "info.circle", title: "Song Info…") {
                dismiss()
            }
        }
        .padding(6)
        .frame(width: 220)
    }

    private var otherPlaylists: [Playlist] {
        library.playlists.filter { $0.id != playlist.id }
    }
}

/// A single button row inside a context menu popover.
private struct ContextMenuItem: View {
    let icon: String
    let title: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Rich Track Context Menu

/// Configuration for the rich right-click track context menu.
struct TrackContextMenuOptions {
    var showRemoveFromPlaylist: Bool = false
    var playlist: Playlist? = nil
    var showRemoveFromLibrary: Bool = true
    var tracksList: [Track] = []
}

/// View modifier that attaches a rich, adaptive context menu to any track row.
/// The menu adapts based on where it's shown:
/// - Playlist rows get "Remove from Playlist" + Move/Copy submenus
/// - Library/Folder rows get "Remove from Library"
/// - All rows get Play Next, Add to Queue, Add to Playlist, and more.
struct TrackContextMenuModifier: ViewModifier {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var playerState: PlayerState

    let track: Track
    var options: TrackContextMenuOptions

    @State private var showSongInfo = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Play") {
                    audioEngine.play(track: track, in: options.tracksList.isEmpty ? [track] : options.tracksList)
                    playerState.isNowPlayingExpanded = true
                }

                Button("Play Next") {
                    audioEngine.playNext(track: track)
                }

                Button("Add to Queue") {
                    audioEngine.addToQueue(track: track)
                }

                Divider()

                // Add to Playlist submenu
                if !library.playlists.isEmpty {
                    Menu("Add to Playlist") {
                        ForEach(library.playlists) { target in
                            Button(target.name) {
                                library.addTracks([track.id], to: target.id)
                            }
                        }
                        Divider()
                        Button("New Playlist from Track…") {
                            library.newPlaylistFromTrack(trackID: track.id)
                        }
                    }
                } else {
                    Button("New Playlist from Track…") {
                        library.newPlaylistFromTrack(trackID: track.id)
                    }
                }

                // Playlist-only actions
                if options.showRemoveFromPlaylist, let playlist = options.playlist {
                    Divider()

                    // Move to Playlist submenu
                    if !otherPlaylists(excluding: playlist).isEmpty {
                        Menu("Move to Playlist") {
                            ForEach(otherPlaylists(excluding: playlist)) { target in
                                Button(target.name) {
                                    library.removeTrackFromPlaylist(trackID: track.id, playlistID: playlist.id)
                                    library.addTracks([track.id], to: target.id)
                                }
                            }
                        }
                    }

                    // Copy to Playlist submenu
                    if !otherPlaylists(excluding: playlist).isEmpty {
                        Menu("Copy to Playlist") {
                            ForEach(otherPlaylists(excluding: playlist)) { target in
                                Button(target.name) {
                                    library.addTracks([track.id], to: target.id)
                                }
                            }
                        }
                    }

                    Button("Remove from Playlist") {
                        library.removeTrackFromPlaylist(trackID: track.id, playlistID: playlist.id)
                    }
                }

                // Library-wide removal
                if options.showRemoveFromLibrary {
                    if !options.showRemoveFromPlaylist {
                        Divider()
                    }
                    Button("Remove from Library") {
                        library.removeTrackFromLibrary(trackID: track.id)
                    }
                }

                Divider()

                // Finder & Info
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                }

                Button("Song Info…") {
                    showSongInfo = true
                }

                Divider()

                // Navigation
                Button("Show in Albums") {
                    playerState.searchText = ""
                    playerState.selectedSection = .albums
                    // Future: could scroll to the album — for now, switch the section.
                    playerState.selectedPlaylist = nil
                    playerState.selectedFolder = nil
                }

                Button("Show in Artists") {
                    playerState.searchText = ""
                    playerState.selectedSection = .artists
                    playerState.selectedPlaylist = nil
                    playerState.selectedFolder = nil
                }
            }
            .popover(isPresented: $showSongInfo, arrowEdge: .bottom) {
                SongInfoPopover(track: track)
            }
    }

    private func otherPlaylists(excluding playlist: Playlist) -> [Playlist] {
        library.playlists.filter { $0.id != playlist.id }
    }
}

extension View {
    /// Fast-path helper for attaching the rich track context menu.
    func richTrackContextMenu(
        track: Track,
        tracksList: [Track] = [],
        playlist: Playlist? = nil,
        showRemoveFromLibrary: Bool = true
    ) -> some View {
        modifier(TrackContextMenuModifier(
            track: track,
            options: TrackContextMenuOptions(
                showRemoveFromPlaylist: playlist != nil,
                playlist: playlist,
                showRemoveFromLibrary: showRemoveFromLibrary,
                tracksList: tracksList
            )
        ))
    }
}

// MARK: - Animated Action Buttons

/// Capsule button with hover-scale spring animation, active state, and prominent style.
private struct CapsuleActionButton: View {
    let icon: String
    let title: String
    var isActive: Bool = false
    var isProminent: Bool = false
    var help: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, isProminent ? 18 : 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isProminent ? Color.accentColor : (isActive ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.05)))
            )
            .overlay(
                Capsule()
                    .stroke(isProminent ? Color.clear : (isActive ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.1)), lineWidth: 0.5)
            )
            .foregroundStyle(isProminent ? Color.white : (isActive ? Color.accentColor : .primary))
            .shadow(color: isProminent ? .black.opacity(0.2) : .clear, radius: 6, y: 3)
            // Zero-transform hover: brightness lift (single GPU color pass).
            .brightness(isHovering ? 0.08 : 0)
            .animation(MicroEase, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(help ?? "")
    }
}

/// Simple icon button (transport controls) with hover-scale animation,
/// optional active/highlight color, and tooltip.
private struct IconActionButton: View {
    let icon: String
    var size: CGFloat = 16
    var color: Color = .primary
    var activeColor: Color? = nil
    var isActive: Bool = false
    var help: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(activeColor != nil && isActive ? activeColor! : (isHovering ? .primary : color))
                .animation(MicroEase, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(help ?? "")
    }
}

/// Rounded-rect label button ("Add Music Tracks" / "Add Music Folder")
/// with a subtle hover-scale + highlight animation.
private struct AddMusicButton: View {
    let icon: String
    let title: String
    var isHovering: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isHovering ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .animation(MicroEase, value: isHovering)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Song Info Popover

/// Popover showing detailed file info for a track.
struct SongInfoPopover: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Format", track.fileFormat.uppercased())
                infoRow("Sample Rate", String(format: "%.1f kHz", track.sampleRate / 1000))
                infoRow("Bit Depth", "\(track.bitDepth)-bit")
                infoRow("Bitrate", String(format: "%.0f kbps", track.bitrate / 1000))
                infoRow("Duration", track.durationLabel)
                infoRow("Channels", track.channelCount > 0 ? "\(track.channelCount)" : "–")
                if track.year > 0 {
                    infoRow("Year", "\(track.year)")
                }
                infoRow("File", track.url.lastPathComponent)
                infoRow("Path", track.url.deletingLastPathComponent().path)
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .frame(width: 280)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Fullscreen Player

/// Fullscreen takeover player. Replaces the entire app UI with a full-window
/// immersive view: huge cover art, ambient gradient derived from the artwork,
/// and the existing floating playbar at the bottom.
struct FullscreenPlayer: View {
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var playerState: PlayerState
    @Environment(\.colorScheme) private var colorScheme

    @State private var isBackHovering = false

    // Single moving gradient — the only "animation" in this view.
    @State private var gradientColors: [Color] = [Color(red: 0.05, green: 0.05, blue: 0.07), Color(red: 0.1, green: 0.1, blue: 0.13)]

    var body: some View {
        ZStack {
            // One gradient layer, one GPU blend. Colors morph smoothly when
            // the off-thread artwork extraction lands. No layers, no crossfade.
            ZStack {
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Ease the eyes in dark appearance — a soft black veil over the
                // artwork palette so bright covers don't glare in dark mode.
                if colorScheme == .dark {
                    Color.black.opacity(0.24)
                        .allowsHitTesting(false)
                }
            }
            .drawingGroup()
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: gradientColors)

            VStack(spacing: 0) {
                // Top bar: exit button + status
                HStack {
                    Button {
                        playerState.isNowPlayingExpanded = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        // Zero-transform hover: subtle brightness lift.
                        .brightness(isBackHovering ? 0.12 : 0)
                        .animation(MicroEase, value: isBackHovering)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isBackHovering = hovering
                    }
                    .help("Collapse Fullscreen Player")

                    Spacer()

                    // Bit-perfect status
                    if let track = audioEngine.currentTrack {
                        HStack(spacing: 6) {
                            Image(systemName: audioEngine.isBitPerfect ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                            Text(audioEngine.isBitPerfect ? "BIT-PERFECT" : "RESAMPLED")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                            if let device = audioEngine.activeDevice {
                                Text("· \(device.name)")
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            Text("· \(track.specsShortLabel)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(audioEngine.isBitPerfect ? Color.green.opacity(0.4) : Color.orange.opacity(0.4), lineWidth: 0.5)
                        )
                        .foregroundStyle(audioEngine.isBitPerfect ? Color.green : Color.orange)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer()

                // Large cover art + track info
                if let track = audioEngine.currentTrack {
                    VStack(spacing: 28) {
                        // Cover art — animated with crossfade + scale
                        ZStack {
                            if let artwork = library.artwork(for: track) {
                                Image(nsImage: artwork)
                                    .resizable()
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(width: 340, height: 340)
                                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                                    )
                                    .shadow(color: .black.opacity(0.4), radius: 40, y: 16)
                            } else {
                                ArtworkPlaceholderView(cornerRadius: 30, noteSize: 80)
                                    .frame(width: 340, height: 340)
                                    .shadow(color: .black.opacity(0.4), radius: 40, y: 16)
                            }

                            // Lossless badge
                            if track.isLossless {
                                VStack {
                                    HStack {
                                        Spacer()
                                        Text("LOSSLESS")
                                            .font(.system(size: 10, weight: .bold))
                                            .tracking(0.5)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .overlay(
                                                Capsule()
                                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                                            )
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .frame(width: 340, height: 340)
                            }
                        }
                        .frame(width: 340, height: 340)
                        .id(track.id)

                        // Track info — crossfades with the cover art
                        VStack(spacing: 6) {
                            Text(track.displayTitle)
                                .font(.system(size: 24, weight: .bold))
                                .lineLimit(1)
                            Text("\(track.displayArtist) · \(track.displayAlbum)")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        .id("\(track.id)-info")
                    }
                }

                Spacer()

                // Floating playbar (reused — centered and elevated above the bottom)
                FloatingPlaybar()
                    .padding(.horizontal, 80)
                    .padding(.bottom, 40)
            }
        }
        // Single animation: morph the background gradient when the track
        // changes. Colors are extracted off the main thread so the UI never
        // blocks; the artwork swaps instantly (no crossfade layers).
        .onChange(of: audioEngine.currentTrack?.id) { _, newTrackID in
            guard let newTrackID = newTrackID,
                  let newTrack = library.tracks.first(where: { $0.id == newTrackID }) else { return }
            guard let artwork = library.artwork(for: newTrack) else { return }

            Task.detached(priority: .userInitiated) {
                let colors = Self.extractDominantColors(from: artwork)
                await MainActor.run {
                    gradientColors = colors
                }
            }
        }
    }

    /// Extracts 2-3 opaque dominant colors from an NSImage by sampling
    /// a low-res bitmap representation. The bottom color is darkened
    /// for playbar contrast.
    nonisolated private static func extractDominantColors(from image: NSImage) -> [Color] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [Color(red: 0.05, green: 0.05, blue: 0.07), Color(red: 0.1, green: 0.1, blue: 0.13)]
        }

        // Downscale to 32x32 for fast sampling
        let width = 32
        let height = 32
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return [Color(red: 0.05, green: 0.05, blue: 0.07), Color(red: 0.1, green: 0.1, blue: 0.13)]
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Collect and average the edge pixels (top + bottom) for gradient directions
        var topR: Double = 0, topG: Double = 0, topB: Double = 0
        var bottomR: Double = 0, bottomG: Double = 0, bottomB: Double = 0
        var topCount = 0.0, bottomCount = 0.0

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let r = Double(pixelData[idx])
                let g = Double(pixelData[idx + 1])
                let b = Double(pixelData[idx + 2])

                if y < height / 4 {
                    topR += r; topG += g; topB += b
                    topCount += 1
                } else if y >= height * 3 / 4 {
                    bottomR += r; bottomG += g; bottomB += b
                    bottomCount += 1
                }
            }
        }

        guard topCount > 0, bottomCount > 0 else {
            return [Color(red: 0.05, green: 0.05, blue: 0.07), Color(red: 0.1, green: 0.1, blue: 0.13)]
        }

        // Fully opaque colors — no opacity modifiers
        let topColor = Color(
            red: (topR / topCount) / 255.0,
            green: (topG / topCount) / 255.0,
            blue: (topB / topCount) / 255.0
        )

        // Darken the bottom color (~80% brightness) for playbar contrast
        let bottomMultiplier = 0.8
        let bottomColor = Color(
            red: ((bottomR / bottomCount) / 255.0) * bottomMultiplier,
            green: ((bottomG / bottomCount) / 255.0) * bottomMultiplier,
            blue: ((bottomB / bottomCount) / 255.0) * bottomMultiplier
        )

        // Middle blend adds depth (slightly brighter)
        var midR: Double = 0, midG: Double = 0, midB: Double = 0
        var midCount = 0.0
        for y in height * 3 / 8..<(height * 5 / 8) {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                midR += Double(pixelData[idx])
                midG += Double(pixelData[idx + 1])
                midB += Double(pixelData[idx + 2])
                midCount += 1
            }
        }
        let midMultiplier = 1.15
        let midColor = midCount > 0 ? Color(
            red: min(((midR / midCount) / 255.0) * midMultiplier, 1.0),
            green: min(((midG / midCount) / 255.0) * midMultiplier, 1.0),
            blue: min(((midB / midCount) / 255.0) * midMultiplier, 1.0)
        ) : topColor

        return [topColor, midColor, bottomColor]
    }
}

// MARK: - Waveform Seekbar

/// Static Canvas waveform seekbar.
///
/// All 48 bars are drawn in a single `Canvas` pass — one lightweight draw
/// on the GPU. The bars NEVER animate on their own (no TimelineView, no
/// per-frame redraws). The only motion is the progress fill, driven by the
/// seekbar's 1s `currentTime` tick flowing through `progress`.
struct WaveformSeekbar: View {
    let progress: Double
    let isPlaying: Bool

    /// The full waveform drawn ONCE into a cached Path (all 48 rounded
    /// rects). Per-frame redraws previously rebuilt every bar path AND
    /// allocated ~48 Gradient objects per tick in the Canvas — a CPU
    /// hotspot during playback. Now the path is static; each tick only
    /// changes the width of a GPU clip.
    @State private var waveformPath = Path()

    private let barCount = 48

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                // Static background waveform — cached path, never re-built.
                waveformPath.fill(Color.primary.opacity(0.1))

                // Progress fill: same cached path, GPU-clipped to the
                // current width. Only the clip width changes per tick —
                // zero path regeneration, zero gradient allocation.
                waveformPath.fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: max(geo.size.width * clamped, 0), alignment: .leading)
                .clipped()
            }
            .onAppear {
                if waveformPath.isEmpty {
                    buildPath(size: geo.size)
                }
            }
            .onChange(of: geo.size) { _, newSize in
                buildPath(size: newSize)
            }
        }
    }

    private func buildPath(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        var random = SystemRandomNumberGenerator()
        let bars: [CGFloat] = (0..<barCount).map { _ in
            CGFloat.random(in: 0.15...1.0, using: &random)
        }

        var path = Path()
        let barWidth = size.width / CGFloat(barCount)
        let spacing: CGFloat = 2
        let drawWidth = max(barWidth - spacing, 1)

        for index in 0..<barCount {
            let barHeight = max(size.height * bars[index], 2)
            let x = CGFloat(index) * barWidth
            let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: drawWidth, height: barHeight)
            let cornerRadius = min(drawWidth / 2, 1)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        }
        waveformPath = path
    }
}
