import Foundation

// MARK: - Track

nonisolated struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var url: URL
    var fileName: String

    // Metadata
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var year: Int
    var trackNumber: Int
    var discNumber: Int
    var composer: String

    // Audio specs
    var duration: TimeInterval
    var sampleRate: Double
    var bitDepth: Int
    var channelCount: Int
    var bitrate: Int
    var fileFormat: String

    var isLossless: Bool
    var artworkPath: String?

    var dateAdded: Date
    var folderName: String

    init(url: URL,
         title: String = "",
         artist: String = "",
         album: String = "",
         albumArtist: String = "",
         genre: String = "",
         year: Int = 0,
         trackNumber: Int = 0,
         discNumber: Int = 0,
         composer: String = "",
         duration: TimeInterval = 0,
         sampleRate: Double = 44100,
         bitDepth: Int = 16,
         channelCount: Int = 2,
         bitrate: Int = 0,
         fileFormat: String = "",
         isLossless: Bool = true,
         artworkPath: String? = nil,
         dateAdded: Date = Date(),
         folderName: String = "") {
        self.id = UUID()
        self.url = url
        self.fileName = url.lastPathComponent
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.composer = composer
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.bitrate = bitrate
        self.fileFormat = fileFormat
        self.isLossless = isLossless
        self.artworkPath = artworkPath
        self.dateAdded = dateAdded
        self.folderName = folderName
    }
}

// MARK: - Display helpers

extension Track {
    var displayTitle: String {
        title.isEmpty ? fileName : title
    }

    var displayArtist: String {
        artist.isEmpty ? "Unknown Artist" : artist
    }

    var displayAlbum: String {
        album.isEmpty ? "Unknown Album" : album
    }

    var sampleRateLabel: String {
        if sampleRate >= 1_000_000 {
            return String(format: "%.1f MHz", sampleRate / 1_000_000)
        }
        if sampleRate.truncatingRemainder(dividingBy: 1000) == 0 {
            return String(format: "%.0f kHz", sampleRate / 1000)
        }
        return String(format: "%.1f kHz", sampleRate / 1000)
    }

    var specsShortLabel: String {
        "\(bitDepth)-bit/\(sampleRateLabel)"
    }

    var specsFullLabel: String {
        "\(specsShortLabel) · \(fileFormat.uppercased())"
    }

    var resolutionLabel: String {
        "\(bitDepth)-bit/\(sampleRateLabel)"
    }

    var isHiRes: Bool {
        sampleRate > 48000 || bitDepth > 16
    }

    var isDSD: Bool { false }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var durationLabel: String {
        Self.timeString(duration)
    }

    static func timeString(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Album

nonisolated struct Album: Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var year: Int?
    var artworkPath: String?
    var tracks: [Track]

    var sampleRate: Double {
        tracks.map(\.sampleRate).max() ?? 0
    }

    var bitDepth: Int {
        tracks.map(\.bitDepth).max() ?? 0
    }

    var isLossless: Bool {
        !tracks.isEmpty && tracks.allSatisfy(\.isLossless)
    }

    var isHiRes: Bool {
        tracks.contains { $0.sampleRate > 48000 || $0.bitDepth > 16 }
    }

    var trackCount: Int { tracks.count }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    var durationLabel: String {
        Track.timeString(totalDuration)
    }

    var resolutionLabel: String {
        let rateLabel: String
        if sampleRate >= 1_000_000 {
            rateLabel = String(format: "%.1f MHz", sampleRate / 1_000_000)
        } else if sampleRate.truncatingRemainder(dividingBy: 1000) == 0 {
            rateLabel = String(format: "%.0f kHz", sampleRate / 1000)
        } else {
            rateLabel = String(format: "%.1f kHz", sampleRate / 1000)
        }
        return "\(bitDepth)-bit/\(rateLabel) · \(trackCount) tracks"
    }
}

// MARK: - Artist

nonisolated struct Artist: Identifiable, Hashable {
    let id: String
    var name: String
    var albums: [Album]

    var trackCount: Int {
        albums.reduce(0) { $0 + $1.trackCount }
    }
}