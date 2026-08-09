import Foundation

// MARK: - Playlist

nonisolated struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var coverImagePath: String?
    var trackIDs: [UUID]
    var createdDate: Date

    init(id: UUID = UUID(),
         name: String,
         coverImagePath: String? = nil,
         trackIDs: [UUID] = [],
         createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.coverImagePath = coverImagePath
        self.trackIDs = trackIDs
        self.createdDate = createdDate
    }
}