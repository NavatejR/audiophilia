import Foundation
import Combine

// MARK: - Player State

/// Shared state for the player UI, including mini player visibility.
final class PlayerState: ObservableObject {

    /// Shared singleton for cross-window access.
    static let shared = PlayerState()

    @Published var isMiniPlayerVisible: Bool = false
    @Published var isNowPlayingExpanded: Bool = false
    @Published var isBitPerfectMode: Bool = true
    @Published var selectedSection: LibrarySection = .albums
    @Published var selectedAlbum: Album?
    @Published var selectedArtist: Artist?
    @Published var selectedPlaylist: Playlist?
    @Published var selectedFolder: URL?
    @Published var searchText: String = ""

    /// True when the search field contains non-whitespace text.
    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private init() {}
}

// MARK: - Library Sections

enum LibrarySection: String, CaseIterable, Identifiable {
    case tracks = "Tracks"
    case albums = "Albums"
    case artists = "Artists"
    case folders = "Folders"
    case playlists = "Playlists"
    case devices = "Devices"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tracks: return "music.note.list"
        case .albums: return "square.stack"
        case .artists: return "person.2"
        case .folders: return "folder"
        case .playlists: return "music.note"
        case .devices: return "hifispeaker"
        }
    }
}