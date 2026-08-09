import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Metadata Extractor

/// Extracts metadata, embedded artwork, and audio specs from local audio files
/// without any network access. Supports FLAC, ALAC (M4A), WAV, and AIFF.
/// Marked nonisolated so library scanning can run in the background without
/// hopping to the main actor for every file (project has default MainActor isolation).
nonisolated enum MetadataExtractor {

    static let supportedExtensions: Set<String> = ["flac", "m4a", "mp4", "alac", "wav", "aiff", "aif", "aifc"]
    /// Only FLAC and ALAC (Apple Lossless in an M4A container) earn the
    /// LOSSLESS badge. Uncompressed WAV/AIFF and lossy codecs do NOT —
    /// they show sample-rate/bit-depth specs without the badge.
    static let losslessExtensions: Set<String> = ["flac"]

    /// All extensions we can attempt to read (lossy formats get tagged but marked not lossless)
    static let playableExtensions: Set<String> = ["flac", "m4a", "mp4", "alac", "wav", "aiff", "aif", "aifc", "mp3", "aac"]

    // MARK: - Public API

    /// Extracts metadata from the file at the given URL. Returns nil if the file can't be read.
    nonisolated static func extract(from url: URL) -> Track? {
        let ext = url.pathExtension.lowercased()

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var track = Track(url: url, fileFormat: ext)

        // Extract FLAC-specific metadata (tags + artwork) using lightweight parser
        if ext == "flac" {
            extractFLACMetadata(from: url, into: &track)
        } else {
            extractAVMetadata(from: url, into: &track)
        }

        // Fill fallback from filename if title/artist still empty
        if track.title.isEmpty {
            track.title = url.deletingPathExtension().lastPathComponent
        }
        if track.album.isEmpty {
            track.album = url.deletingLastPathComponent().lastPathComponent
        }
        if track.artist.isEmpty {
            track.artist = "Unknown Artist"
        }

        // Extract audio stream properties (duration, sample rate, bit depth, channels)
        extractAudioStreamInfo(from: url, into: &track)

        // Extract bitrate for lossy formats
        if track.bitrate == 0 {
            extractBitrate(from: url, into: &track)
        }

        // LOSSLESS gating: FLAC always qualifies. M4A only qualifies when
        // the actual codec is Apple Lossless (kAudioFormatAppleLossless) —
        // an AAC M4A must never show the badge.
        let isALAC = ext == "m4a" && isALACFile(from: url)
        track.isLossless = Self.losslessExtensions.contains(ext) || (ext == "m4a" && isALAC)

        return track
    }

    /// Extracts and caches embedded artwork to the app's cache directory.
    /// Returns the cached file path, or nil if no artwork is found.
    ///
    /// JPEG is preferred (keeps the legacy `<trackID>.jpg` cache layout), but
    /// if the re-encode fails — e.g. artwork with an alpha channel that the
    /// JPEG encoder rejects — we fall back to writing a PNG instead of
    /// silently dropping the cover, which would show the placeholder note.
    @discardableResult
    nonisolated static func extractArtwork(from url: URL, trackID: UUID) -> String? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudiophiliaArtwork", isDirectory: true)

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let destPath = cacheDir.appendingPathComponent("\(trackID.uuidString).jpg").path
        if FileManager.default.fileExists(atPath: destPath) {
            return destPath
        }

        guard let data = extractArtworkData(from: url) else { return nil }

        // Standard path — preferred JPEG cache file.
        if let jpegData = convertToJPEG(data) {
            try? jpegData.write(to: URL(fileURLWithPath: destPath))
            return destPath
        }

        // Fallback — re-encode as PNG (lossless, alpha-safe) so the cover
        // still shows instead of the placeholder note.
        let pngPath = cacheDir.appendingPathComponent("\(trackID.uuidString).png").path
        if let pngData = convertToPNG(data) {
            try? pngData.write(to: URL(fileURLWithPath: pngPath))
            return pngPath
        }

        return nil
    }

    /// Converts raw image data to JPEG using pure CoreGraphics (no NSImage main-actor hop).
    nonisolated private static func convertToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }

        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Converts raw image data to PNG using pure CoreGraphics (alpha-safe
    /// fallback for covers the JPEG encoder rejects).
    nonisolated private static func convertToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Returns raw artwork image data embedded in the file.
    nonisolated static func extractArtworkData(from url: URL) -> Data? {
        let ext = url.pathExtension.lowercased()
        if ext == "flac" {
            return FLACParser.extractPictureData(from: url)
        }
        if let cfData = assetArtworkData(from: url) {
            return cfData
        }
        return nil
    }

    // MARK: - FLAC

    nonisolated private static func extractFLACMetadata(from url: URL, into track: inout Track) {
        let metadata = FLACParser.extractMetadata(from: url)

        track.title = metadata["TITLE"] ?? ""
        track.artist = metadata["ARTIST"] ?? ""
        track.album = metadata["ALBUM"] ?? ""
        track.albumArtist = metadata["ALBUMARTIST"] ?? metadata["ALBUM ARTIST"] ?? ""
        track.genre = metadata["GENRE"] ?? ""
        track.composer = metadata["COMPOSER"] ?? ""
        track.year = Int(metadata["DATE"] ?? metadata["YEAR"] ?? "") ?? 0
        track.trackNumber = Int(metadata["TRACKNUMBER"] ?? "") ?? 0
        track.discNumber = Int(metadata["DISCNUMBER"] ?? "") ?? 0

        if let spec = FLACParser.extractStreamInfo(from: url) {
            track.sampleRate = spec.sampleRate
            track.bitDepth = spec.bitDepth
            track.channelCount = spec.channelCount
            track.duration = spec.duration
            track.bitrate = Int(Double(spec.bitDepth) * spec.sampleRate * Double(spec.channelCount) / 1000)
        }
    }

    // MARK: - AVFoundation (M4A/ALAC/WAV/AIFF)

    nonisolated private static func extractAVMetadata(from url: URL, into track: inout Track) {
        let asset = AVURLAsset(url: url)

        // Common metadata
        for item in asset.commonMetadata {
            guard let value = item.value else { continue }
            switch item.commonKey {
            case .commonKeyTitle:
                track.title = value as? String ?? ""
            case .commonKeyArtist:
                track.artist = value as? String ?? ""
            case .commonKeyAlbumName:
                track.album = value as? String ?? ""
            case .commonKeyCreator:
                track.albumArtist = value as? String ?? ""
            case .commonKeyType:
                track.genre = value as? String ?? ""
            case .commonKeyCreationDate:
                if let s = value as? String, let year = Int(s.prefix(4)) {
                    track.year = year
                }
            case .commonKeyArtwork:
                // Handled separately via extractArtworkData
                break
            default:
                break
            }
        }

        // Format-specific metadata
        for item in asset.metadata {
            guard let key = item.key as? String else { continue }
            let lowered = key.lowercased()

            switch lowered {
            case "trkn":
                if let data = item.dataValue, data.count >= 8 {
                    track.trackNumber = Int(data[data.index(data.startIndex, offsetBy: 2)])
                }
            case "disk":
                if let data = item.dataValue, data.count >= 4 {
                    track.discNumber = Int(data[1])
                }
            case "©day", "©yr":
                if let s = item.value as? String, let year = Int(s) {
                    track.year = year
                }
            case "©wrt":
                track.composer = item.value as? String ?? ""
            default:
                break
            }
        }
    }

    /// Returns true when the M4A container's actual codec is Apple Lossless (ALAC).
    nonisolated private static func isALACFile(from url: URL) -> Bool {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return false }
        let mediaSubType = CMFormatDescriptionGetMediaSubType(audioFile.processingFormat.formatDescription)
        return mediaSubType == kAudioFormatAppleLossless
    }

    /// Re-evaluates whether a previously-persisted track qualifies as LOSSLESS
    /// under the current gating rules without requiring a full re-scan.
    /// Used at launch to correct badges that were saved under the old rules
    /// (e.g. WAV/AIFF previously tagged lossless).
    nonisolated static func recomputeIsLossless(from url: URL, fileFormat: String) -> Bool {
        let ext = fileFormat.isEmpty ? url.pathExtension.lowercased() : fileFormat.lowercased()
        if losslessExtensions.contains(ext) { return true }
        if ext == "m4a" || ext == "mp4" || ext == "alac" {
            return isALACFile(from: url)
        }
        return false
    }

    // MARK: - Audio stream properties

    nonisolated private static func extractAudioStreamInfo(from url: URL, into track: inout Track) {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return }

        let format = audioFile.processingFormat

        // Duration
        let frameCount = Double(audioFile.length)
        let sampleRate = format.sampleRate
        if sampleRate > 0 {
            track.duration = frameCount / sampleRate
        }

        // Sample rate
        track.sampleRate = sampleRate

        // Channels
        track.channelCount = Int(format.channelCount)

        // Bit depth detection
        let bitDepth = streamDescriptionBitDepth(for: url, format: format)
        if bitDepth > 0 {
            track.bitDepth = bitDepth
        } else {
            switch format.commonFormat {
            case .pcmFormatFloat32:
                track.bitDepth = 32
            case .pcmFormatFloat64:
                track.bitDepth = 64
            case .pcmFormatInt16:
                track.bitDepth = 16
            case .pcmFormatInt32:
                track.bitDepth = 32
            default:
                track.bitDepth = 0
            }
        }

        // For FLAC, AVAudioFile may report 16-bit due to upsampling;
        // prefer our own FLAC parser data if available
        if track.fileFormat == "flac" {
            if let spec = FLACParser.extractStreamInfo(from: url) {
                track.sampleRate = spec.sampleRate
                track.bitDepth = spec.bitDepth
                track.channelCount = spec.channelCount
                track.duration = spec.duration
            }
        }
    }

    /// Attempts to read actual bit depth from stream description (more accurate than AVAudioFile's processing format)
    nonisolated private static func streamDescriptionBitDepth(for url: URL, format: AVAudioFormat) -> Int {
        // For WAV/AIFF, try to read the format chunk directly for true bit depth
        let ext = url.pathExtension.lowercased()
        if ext == "wav" {
            return WAVParser.extractBitDepth(from: url) ?? 16
        } else if ext == "aiff" || ext == "aif" || ext == "aifc" {
            return AIFFParser.extractBitDepth(from: url) ?? 16
        }

        // For ALAC/M4A, read from the magic cookie
        if ext == "m4a" || ext == "alac" || ext == "mp4" {
            if format.settings[AVFormatIDKey] as? UInt32 != nil,
               let bits = format.settings[AVLinearPCMBitDepthKey] as? Int {
                return bits
            }
            let formatID = format.formatDescription
            let mediaSubType = CMFormatDescriptionGetMediaSubType(formatID)
            if mediaSubType == kAudioFormatAppleLossless {
                return ALACParser.extractBitDepth(from: url) ?? 16
            }
        }
        return 0
    }

    nonisolated private static func extractBitrate(from url: URL, into track: inout Track) {
        guard track.duration > 0 else { return }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? NSNumber {
            let fileSize = size.int64Value
            if fileSize > 0 {
                track.bitrate = Int(Double(fileSize) * 8 / track.duration / 1000)
            }
        }
    }

    nonisolated private static func assetArtworkData(from url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata {
            if item.commonKey == .commonKeyArtwork {
                if let data = item.dataValue {
                    return data
                }
                if let value = item.value as? Data {
                    return value
                }
            }
        }
        return nil
    }
}

// MARK: - Artwork helpers

extension NSImage {
    @MainActor
    func jpegData(compressionQuality: Double) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    @MainActor
    func resized(maxDimension: CGFloat) -> NSImage {
        guard maxDimension > 0 else { return self }

        let largest = max(size.width, size.height)
        guard largest > maxDimension else { return self }

        let scale = maxDimension / largest
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let image = NSImage(size: newSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        image.unlockFocus()
        return image
    }
}
