import Foundation
import AppKit
import Combine

// MARK: - Library Manager

/// Manages the local music library: folder scanning, metadata extraction,
/// artwork caching, and persistence.
final class LibraryManager: ObservableObject {

    /// Shared singleton for cross-window access.
    static let shared = LibraryManager()

    // MARK: - Published

    @Published private(set) var tracks: [Track] = [] {
        didSet {
            invalidateDerivedData()
            clearArtworkCache()
        }
    }
    @Published private(set) var folders: [URL] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isScanning: Bool = false
    @Published var scanProgress: Double = 0
    @Published private(set) var lastScanDate: Date?

    // MARK: - Derived (cached)

    // Rebuilding the full album/artist hierarchy from every track is expensive
    // (Dictionary grouping, sorting, struct construction). During playback the
    // AudioEngine publishes `currentTime` at 4Hz, which recomputes any view
    // observing this object — so caching these derived collections prevents
    // the entire library from being re-grouped on every progress tick.
    private var _albums: [Album]?
    private var _artists: [Artist]?

    var albums: [Album] {
        if let cached = _albums { return cached }

        let grouped = Dictionary(grouping: tracks) { track -> String in
            "\(track.albumArtist.isEmpty ? track.artist : track.albumArtist)|\(track.album)"
        }

        let result: [Album] = grouped.values.compactMap { albumTracks in
            guard let first = albumTracks.first else { return nil }
            let sorted = albumTracks.sorted { $0.trackNumber < $1.trackNumber }
            return Album(
                id: "\(first.albumArtist)|\(first.album)",
                title: first.displayAlbum,
                artist: first.displayArtist,
                year: first.year > 0 ? first.year : nil,
                artworkPath: first.artworkPath,
                tracks: sorted
            )
        }.sorted { $0.title < $1.title }

        _albums = result
        return result
    }

    var artists: [Artist] {
        if let cached = _artists { return cached }

        let grouped = Dictionary(grouping: tracks) { $0.displayArtist }
        let result: [Artist] = grouped.map { name, artistTracks in
            let artistAlbums = Dictionary(grouping: artistTracks) { $0.displayAlbum }
                .values
                .compactMap { albumTracks -> Album? in
                    guard let first = albumTracks.first else { return nil }
                    let sorted = albumTracks.sorted { $0.trackNumber < $1.trackNumber }
                    return Album(
                        id: "\(name)|\(first.displayAlbum)",
                        title: first.displayAlbum,
                        artist: name,
                        year: first.year > 0 ? first.year : nil,
                        artworkPath: first.artworkPath,
                        tracks: sorted
                    )
                }
                .sorted { $0.title < $1.title }

            return Artist(id: name, name: name, albums: artistAlbums)
        }.sorted { $0.name < $1.name }

        _artists = result
        return result
    }

    private func invalidateDerivedData() {
        _albums = nil
        _artists = nil
    }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    var totalSize: Int64 {
        var total: Int64 = 0
        for track in tracks {
            let attrs = try? FileManager.default.attributesOfItem(atPath: track.url.path)
            if let size = attrs?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    // MARK: - Private

    private let persistenceURL: URL
    private let foldersURL: URL
    private let playlistsURL: URL
    private let artworkCacheDir: URL
    private var scanTask: Task<Void, Never>?
    private var activeScopedURLs: [URL] = []

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Audiophilia", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        persistenceURL = appSupport.appendingPathComponent("library.json")
        foldersURL = appSupport.appendingPathComponent("folders.json")
        playlistsURL = appSupport.appendingPathComponent("playlists.json")
        artworkCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudiophiliaArtwork", isDirectory: true)

        try? FileManager.default.createDirectory(at: artworkCacheDir, withIntermediateDirectories: true)

        loadLibrary()
        restoreFolderAccess()
        reconcileArtwork()
    }

    // MARK: - Folder Management

    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)

        // Start accessing the folder for security-scoped access
        let didStart = url.startAccessingSecurityScopedResource()
        if didStart {
            activeScopedURLs.append(url)
        }

        saveFolders()
        scanLibrary()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }

        // Stop security-scoped access
        if let idx = activeScopedURLs.firstIndex(of: url) {
            let scopedURL = activeScopedURLs.remove(at: idx)
            scopedURL.stopAccessingSecurityScopedResource()
        }

        saveFolders()

        // Remove tracks from this folder
        tracks.removeAll { track in
            track.url.path.hasPrefix(url.path)
        }
        saveLibrary()
    }

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Music Folder"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select folders containing your music library"

        if panel.runModal() == .OK {
            for url in panel.urls {
                addFolder(url)
            }
        }
    }

    // MARK: - Scanning

    func scanLibrary() {
        guard !folders.isEmpty, !isScanning else { return }

        isScanning = true
        scanProgress = 0

        let allFiles = folders.flatMap { folder -> [URL] in
            findAudioFiles(in: folder)
        }

        guard !allFiles.isEmpty else {
            isScanning = false
            lastScanDate = Date()
            return
        }

        let total = allFiles.count
        var processed = 0
        var newTracks: [Track] = []
        let existingPaths = Set(tracks.map { $0.url.path })

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            for file in allFiles {
                if Task.isCancelled { break }

                // Skip if already in library
                if existingPaths.contains(file.path) {
                    processed += 1
                    continue
                }

                if let track = MetadataExtractor.extract(from: file) {
                    // Extract artwork
                    let artworkPath = MetadataExtractor.extractArtwork(from: file, trackID: track.id)
                    var enrichedTrack = track
                    enrichedTrack.artworkPath = artworkPath
                    newTracks.append(enrichedTrack)
                }

                processed += 1

                let progress = Double(processed) / Double(total)
                await MainActor.run {
                    self.scanProgress = progress
                }
            }

            let appendedTracks = newTracks
            await MainActor.run {
                self.tracks.append(contentsOf: appendedTracks)
                self.tracks.sort { $0.album < $1.album || ($0.album == $1.album && $0.trackNumber < $1.trackNumber) }
                self.isScanning = false
                self.lastScanDate = Date()
                self.saveLibrary()
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
    }

    private func findAudioFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options
        ) else { return [] }

        var files: [URL] = []

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if MetadataExtractor.playableExtensions.contains(ext) {
                files.append(url)
            }
        }

        return files
    }

    // MARK: - Single Track Import

    /// Imports individual audio files selected by the user directly into the library.
    /// Existing tracks already in the library are skipped.
    /// The completion handler is called with the track IDs of ALL selected files
    /// (whether newly imported or already present) once the import finishes.
    func importTrackFiles(_ urls: [URL], completion: (([UUID]) -> Void)? = nil) {
        let existingPaths = Set(tracks.map { $0.url.path })

        let newFiles = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return MetadataExtractor.playableExtensions.contains(ext) && !existingPaths.contains(url.path)
        }

        // Resolve track IDs for files that already exist in the library
        let existingIDs = urls.compactMap { url -> UUID? in
            tracks.first { $0.url.path == url.path }?.id
        }

        guard !newFiles.isEmpty else {
            // Everything was already imported — call completion with existing IDs
            completion?(existingIDs)
            return
        }

        isScanning = true
        scanProgress = 0

        let total = newFiles.count
        var processed = 0
        var importedTracks: [Track] = []

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            for file in newFiles {
                if let track = MetadataExtractor.extract(from: file) {
                    let artworkPath = MetadataExtractor.extractArtwork(from: file, trackID: track.id)
                    var enrichedTrack = track
                    enrichedTrack.artworkPath = artworkPath
                    importedTracks.append(enrichedTrack)
                }

                processed += 1
                let progress = Double(processed) / Double(total)
                await MainActor.run {
                    self.scanProgress = progress
                }
            }

            let appendedTracks = importedTracks
            await MainActor.run {
                self.tracks.append(contentsOf: appendedTracks)
                self.tracks.sort { $0.album < $1.album || ($0.album == $1.album && $0.trackNumber < $1.trackNumber) }
                self.isScanning = false
                self.lastScanDate = Date()
                self.saveLibrary()

                // Collect all track IDs: newly imported + pre-existing
                let allIDs = appendedTracks.map(\.id) + existingIDs
                completion?(allIDs)
            }
        }
    }

    // MARK: - Playlists

    /// Creates a new playlist with the given name and optional cover image.
    func createPlaylist(name: String, coverImagePath: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let playlist = Playlist(
            name: trimmedName,
            coverImagePath: coverImagePath
        )

        playlists.append(playlist)
        savePlaylists()
    }

    /// Deletes a playlist by ID.
    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    /// Sets a playlist's custom cover image, replacing any previous one.
    /// The previous file is removed only if it lives in the app's own
    /// `PlaylistCovers` directory — track-derived artwork is never touched.
    func setPlaylistCover(playlistID: UUID, coverImagePath: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        if let old = playlists[index].coverImagePath,
           old != coverImagePath,
           FileManager.default.fileExists(atPath: old),
           old.contains("PlaylistCovers") {
            try? FileManager.default.removeItem(atPath: old)
        }

        playlists[index].coverImagePath = coverImagePath
        savePlaylists()
    }

    /// Returns the tracks belonging to a playlist, preserving order.
    func tracks(inPlaylist playlist: Playlist) -> [Track] {
        let trackMap = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return playlist.trackIDs.compactMap { trackMap[$0] }
    }

    /// Adds tracks to a playlist.
    func addTracks(_ trackIDs: [UUID], to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var updated = playlists[index]
        for id in trackIDs where !updated.trackIDs.contains(id) {
            updated.trackIDs.append(id)
        }
        playlists[index] = updated
        savePlaylists()
    }

    /// Removes a track from a playlist.
    func removeTrackFromPlaylist(trackID: UUID, playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var updated = playlists[index]
        updated.trackIDs.removeAll { $0 == trackID }
        playlists[index] = updated
        savePlaylists()
    }

    /// Scans a folder for audio files, imports any missing tracks into the library,
    /// and appends them to the given playlist.
    func addFolderToPlaylist(_ url: URL, playlistID: UUID) {
        guard !url.path.isEmpty else { return }

        let audioFiles = findAudioFiles(in: url)
        guard !audioFiles.isEmpty else { return }

        // Get existing paths to avoid duplicate imports
        let existingPaths = Set(tracks.map { $0.url.path })
        let newFiles = audioFiles.filter { !existingPaths.contains($0.path) }

        // Extract metadata for new files (reuse the import logic)
        var importedTracks: [Track] = []
        isScanning = true
        scanProgress = 0
        let total = max(newFiles.count, 1)
        var processed = 0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            for file in newFiles {
                if let track = MetadataExtractor.extract(from: file) {
                    let artworkPath = MetadataExtractor.extractArtwork(from: file, trackID: track.id)
                    var enrichedTrack = track
                    enrichedTrack.artworkPath = artworkPath
                    importedTracks.append(enrichedTrack)
                }
                processed += 1
                let progress = Double(processed) / Double(total)
                await MainActor.run {
                    self.scanProgress = progress
                }
            }

            let appendedTracks = importedTracks
            await MainActor.run {
                self.tracks.append(contentsOf: appendedTracks)
                self.tracks.sort { $0.album < $1.album || ($0.album == $1.album && $0.trackNumber < $1.trackNumber) }
                self.isScanning = false
                self.lastScanDate = Date()
                self.saveLibrary()

                // Append all the folder's track IDs to the playlist
                let trackIDs: [UUID]
                if importedTracks.isEmpty {
                    // All files already existed — look them up from the library
                    trackIDs = audioFiles.compactMap { file in
                        self.tracks.first { $0.url.path == file.path }?.id
                    }
                } else {
                    trackIDs = appendedTracks.map(\.id)
                }
                self.addTracks(trackIDs, to: playlistID)
            }
        }
    }

    // MARK: - Track Operations

    func track(withID id: UUID) -> Track? {
        tracks.first { $0.id == id }
    }

    func tracks(inAlbum album: Album) -> [Track] {
        tracks.filter { $0.displayAlbum == album.title && $0.displayArtist == album.artist }
            .sorted { $0.trackNumber < $1.trackNumber }
    }

    func tracks(byArtist artist: Artist) -> [Track] {
        tracks.filter { $0.displayArtist == artist.name }
    }

    /// Returns the tracks inside a given folder, sorted by track number then title.
    func tracks(inFolder url: URL) -> [Track] {
        let folderPath = url.path
        return tracks
            .filter { track in
                track.url.path.hasPrefix(folderPath + "/") || track.url.path.hasPrefix(folderPath)
            }
            .sorted { a, b in
                if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
                return a.displayTitle < b.displayTitle
            }
    }

    /// Removes a track from the library entirely, including all playlists
    /// that reference it, and cleans up its cached artwork file.
    func removeTrackFromLibrary(trackID: UUID) {
        // Remove from all playlists first
        for playlistIndex in playlists.indices {
            playlists[playlistIndex].trackIDs.removeAll { $0 == trackID }
        }
        savePlaylists()

        // Remove the track itself
        if let track = tracks.first(where: { $0.id == trackID }) {
            // Clean up cached artwork if present
            if let artworkPath = track.artworkPath,
               FileManager.default.fileExists(atPath: artworkPath) {
                try? FileManager.default.removeItem(atPath: artworkPath)
            }
        }
        tracks.removeAll { $0.id == trackID }

        // If the currently playing track was removed, stop playback
        if AudioEngine.shared.currentTrack?.id == trackID {
            AudioEngine.shared.stop()
        }

        saveLibrary()
    }

    /// Creates a new playlist automatically named after the given track
    /// and adds the track to it. Returns the new playlist's ID.
    @discardableResult
    func newPlaylistFromTrack(trackID: UUID) -> UUID? {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }

        let baseName = "\(track.displayTitle) — Playlist"
        var playlistName = baseName
        var suffix = 2
        while playlists.contains(where: { $0.name == playlistName }) {
            playlistName = "\(baseName) \(suffix)"
            suffix += 1
        }

        var playlist = Playlist(name: playlistName, coverImagePath: track.artworkPath)
        playlist.trackIDs = [trackID]
        playlists.append(playlist)
        savePlaylists()
        return playlist.id
    }

    // MARK: - Persistence

    private func loadLibrary() {
        // Load folders
        if let data = try? Data(contentsOf: foldersURL),
           let savedFolders = try? JSONDecoder().decode([URL].self, from: data) {
            folders = savedFolders
        }

        // Load tracks, then correct any LOSSLESS badges saved under the old
        // rules (WAV/AIFF previously tagged lossless). Runs off the main
        // thread so large libraries don't block the window from appearing.
        if let data = try? Data(contentsOf: persistenceURL),
           let savedTracks = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = savedTracks
            reclassifyLosslessBadges()
        }

        // Load playlists
        if let data = try? Data(contentsOf: playlistsURL),
           let savedPlaylists = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = savedPlaylists
        }
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: persistenceURL)
        }
        savePlaylists()
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: playlistsURL)
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            try? data.write(to: foldersURL)
        }
    }

    /// Re-establishes security-scoped access to persisted folders.
    /// Since the app is sandboxed, file access grants are lost on restart —
    /// this re-acquires them so saved folders remain playable.
    private func restoreFolderAccess() {
        for folder in folders {
            let didStart = folder.startAccessingSecurityScopedResource()
            if didStart {
                activeScopedURLs.append(folder)
            }
        }
    }

    // MARK: - Lossless Reclassification

    /// Re-evaluates every persisted track's `isLossless` flag under the
    /// current gating rules (FLAC always; M4A only when ALAC codec).
    /// Files that no longer qualify keep their metadata and specs but lose
    /// the LOSSLESS badge. Runs off the main thread; saves only on change.
    private func reclassifyLosslessBadges() {
        let tracksToCheck = tracks.filter { track in
            // Only recheck tracks that could have a stale badge:
            // WAV/AIFF/MP3/AAC were previously force-tagged via extension.
            // FLAC never changes. M4A is rechecked to detect the codec.
            let ext = track.fileFormat.lowercased()
            return ext == "wav" || ext == "aiff" || ext == "aif" || ext == "aifc"
                || track.isLossless
        }

        guard !tracksToCheck.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            var needsSave = false
            var corrected: [UUID: Bool] = [:]
            for track in tracksToCheck {
                let isLossless = MetadataExtractor.recomputeIsLossless(from: track.url, fileFormat: track.fileFormat)
                if isLossless != track.isLossless {
                    corrected[track.id] = isLossless
                }
            }

            guard !corrected.isEmpty else { return }

            await MainActor.run {
                var updated = self.tracks
                for index in updated.indices {
                    if let value = corrected[updated[index].id] {
                        updated[index].isLossless = value
                        needsSave = true
                    }
                }
                if needsSave {
                    self.tracks = updated
                    self.saveLibrary()
                }
            }
        }
    }

    // MARK: - Artwork

    /// Re-establishes cached cover art that is missing or was evicted.
    ///
    /// `artworkPath` values are persisted in `library.json`, but macOS may
    /// purge `~/Library/Caches/AudiophiliaArtwork` between launches. Without
    /// this pass, every cover silently drops back to the placeholder note.
    /// Runs off the main thread; each cached file that still exists is skipped
    /// (an expensive re-read of every track on launch is avoided).
    func reconcileArtwork() {
        let snapshotTracks = tracks
        guard !snapshotTracks.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }

            var updates: [UUID: String] = [:]
            for track in snapshotTracks {
                if let path = track.artworkPath, FileManager.default.fileExists(atPath: path) {
                    continue
                }
                if let newPath = MetadataExtractor.extractArtwork(from: track.url, trackID: track.id) {
                    updates[track.id] = newPath
                }
            }
            guard !updates.isEmpty else { return }

            await MainActor.run {
                self.applyArtworkUpdates(updates)
            }
        }
    }

    /// Applies re-extracted artwork paths to the in-memory library.
    private func applyArtworkUpdates(_ updates: [UUID: String]) {
        var updated = tracks
        var changed = false
        for index in updated.indices where updates[updated[index].id] != nil {
            updated[index].artworkPath = updates[updated[index].id]
            changed = true
        }
        guard changed else { return }
        tracks = updated
        saveLibrary()
    }

    /// Cached artwork images keyed by file path.
    ///
    /// Downscaled to a small max dimension so grid cards, thumbnails, and
    /// playbar art never decode full-resolution album covers — cuts both
    /// CPU (repeated decode) and memory (large pixel buffers) dramatically.
    /// Uses `NSCache` so the OS can evict entries under memory pressure
    /// instead of holding every cover in RAM for the app's lifetime.
    private let artworkCache = NSCache<NSString, NSImage>()
    private let artworkMaxDimension: CGFloat = 512

    func artwork(for track: Track) -> NSImage? {
        guard let path = track.artworkPath else { return nil }
        return cachedArtwork(at: path)
    }

    func artwork(for album: Album) -> NSImage? {
        guard let path = album.artworkPath else { return nil }
        return cachedArtwork(at: path)
    }

    private func cachedArtwork(at path: String) -> NSImage? {
        let key = path as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }

        guard let image = NSImage(contentsOfFile: path) else { return nil }

        let downscaled = downscaledImage(image, maxDimension: artworkMaxDimension)
        artworkCache.setObject(downscaled, forKey: key)
        return downscaled
    }

    /// Downscales an NSImage to fit within the given max dimension.
    /// Keeps memory usage bounded when many album covers are visible.
    private func downscaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxDimension else { return image }

        let scale = maxDimension / largest
        let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }

    /// Removes all cached artwork — called when the library changes.
    private func clearArtworkCache() {
        artworkCache.removeAllObjects()
    }
}
