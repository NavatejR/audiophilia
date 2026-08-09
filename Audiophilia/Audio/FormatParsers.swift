import Foundation
import CoreAudio

// MARK: - FLAC Parser

/// Lightweight FLAC metadata parser. Reads STREAMINFO, VORBIS_COMMENT, and PICTURE blocks.
nonisolated enum FLACParser {

    struct StreamInfo {
        var sampleRate: Double
        var bitDepth: Int
        var channelCount: Int
        var totalSamples: UInt64
        var duration: TimeInterval
    }

    // MARK: - Public

    /// Extracts VORBIS_COMMENT tags from a FLAC file.
    static func extractMetadata(from url: URL) -> [String: String] {
        guard let data = readMetadataBlocks(from: url) else { return [:] }

        var result: [String: String] = [:]

        for block in data.blocks {
            guard block.type == 4 else { continue } // VORBIS_COMMENT
            result.merge(parseVorbisComment(block.data), uniquingKeysWith: { first, _ in first })
        }

        return result
    }

    /// Extracts STREAMINFO from a FLAC file.
    static func extractStreamInfo(from url: URL) -> StreamInfo? {
        guard let data = readMetadataBlocks(from: url) else { return nil }

        for block in data.blocks where block.type == 0 { // STREAMINFO
            return parseStreamInfo(block.data)
        }
        return nil
    }

    /// Extracts embedded picture (cover art) data from a FLAC file.
    static func extractPictureData(from url: URL) -> Data? {
        guard let data = readMetadataBlocks(from: url) else { return nil }

        for block in data.blocks where block.type == 6 { // PICTURE
            return parsePicture(block.data)
        }
        return nil
    }

    // MARK: - Private

    private struct MetadataBlock {
        var type: UInt8
        var data: Data
    }

    private struct MetadataBlocks {
        var blocks: [MetadataBlock]
    }

    private static func readMetadataBlocks(from url: URL) -> MetadataBlocks? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }

        defer { try? fileHandle.close() }

        // Read "fLaC" marker
        guard let marker = try? fileHandle.read(upToCount: 4),
              marker == Data("fLaC".utf8) else {
            return nil
        }

        var blocks: [MetadataBlock] = []

        while true {
            guard let header = try? fileHandle.read(upToCount: 4), header.count == 4 else { break }

            let isLast = (header[0] & 0x80) != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])

            guard length > 0, let blockData = try? fileHandle.read(upToCount: length), blockData.count == length else {
                break
            }

            blocks.append(MetadataBlock(type: type, data: blockData))

            if isLast { break }
        }

        return MetadataBlocks(blocks: blocks)
    }

    private static func parseStreamInfo(_ data: Data) -> StreamInfo? {
        guard data.count >= 34 else { return nil }

        let bytes = [UInt8](data)

        // STREAMINFO layout:
        // 2 bytes: min block size
        // 2 bytes: max block size
        // 3 bytes: min frame size
        // 3 bytes: max frame size
        // 8 bytes: sample rate (20 bits), channels (3 bits), bits per sample (5 bits), total samples (36 bits)

        let sampleRate = (UInt32(bytes[10]) << 12) | (UInt32(bytes[11]) << 4) | (UInt32(bytes[12]) >> 4)
        let channels = Int((bytes[12] >> 1) & 0x07) + 1
        let bitDepth = Int(((bytes[12] & 0x01) << 4) | (bytes[13] >> 4)) + 1

        let totalSamples = (UInt64(bytes[13] & 0x0F) << 32) |
                           (UInt64(bytes[14]) << 24) |
                           (UInt64(bytes[15]) << 16) |
                           (UInt64(bytes[16]) << 8) |
                           UInt64(bytes[17])

        let duration = sampleRate > 0 ? Double(totalSamples) / Double(sampleRate) : 0

        return StreamInfo(
            sampleRate: Double(sampleRate),
            bitDepth: bitDepth,
            channelCount: channels,
            totalSamples: totalSamples,
            duration: duration
        )
    }

    private static func parseVorbisComment(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        let bytes = [UInt8](data)

        guard bytes.count >= 8 else { return result }

        var offset = 0

        // Vendor length (4 bytes LE)
        let vendorLength = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
        offset = 4 + vendorLength

        guard offset + 4 <= bytes.count else { return result }

        // Comment count (4 bytes LE)
        let commentCount = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24)
        offset += 4

        for _ in 0..<commentCount {
            guard offset + 4 <= bytes.count else { break }

            let length = Int(bytes[offset]) | (Int(bytes[offset+1]) << 8) | (Int(bytes[offset+2]) << 16) | (Int(bytes[offset+3]) << 24)
            offset += 4

            guard offset + length <= bytes.count else { break }

            let commentData = bytes[offset..<offset+length]
            offset += length

            if let comment = String(bytes: commentData, encoding: .utf8),
               let eqIndex = comment.firstIndex(of: "=") {
                let key = String(comment[..<eqIndex]).uppercased()
                let value = String(comment[comment.index(after: eqIndex)...])
                result[key] = value
            }
        }

        return result
    }

    private static func parsePicture(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { return nil }

        var offset = 0

        // Picture type (4 bytes)
        offset += 4

        // MIME type length (4 bytes BE)
        let mimeLength = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
        offset += 4 + mimeLength

        // Description length (4 bytes BE)
        guard offset + 4 <= bytes.count else { return nil }
        let descLength = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
        offset += 4 + descLength

        // Width, height, color depth, colors used (16 bytes)
        offset += 16

        // Data length (4 bytes BE)
        guard offset + 4 <= bytes.count else { return nil }
        let dataLength = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
        offset += 4

        guard offset + dataLength <= bytes.count else { return nil }

        return Data(bytes[offset..<offset+dataLength])
    }
}

// MARK: - WAV Parser

nonisolated enum WAVParser {
    /// Reads the actual bit depth from a WAV file's fmt chunk.
    static func extractBitDepth(from url: URL) -> Int? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        // RIFF header
        guard let riff = try? fileHandle.read(upToCount: 12), riff.count == 12 else { return nil }
        guard String(data: riff[0..<4], encoding: .ascii) == "RIFF" else { return nil }

        // Walk chunks
        while true {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let chunkID = String(data: header[0..<4], encoding: .ascii) ?? ""
            let chunkSize = Int(header[4]) | (Int(header[5]) << 8) | (Int(header[6]) << 16) | (Int(header[7]) << 24)

            if chunkID == "fmt " {
                guard let fmtData = try? fileHandle.read(upToCount: min(chunkSize, 40)), fmtData.count >= 16 else { return nil }

                let bytes = [UInt8](fmtData)
                let formatTag = Int(bytes[0]) | (Int(bytes[1]) << 8)

                // PCM = 1, IEEE float = 3, extensible = 0xFFFE
                if formatTag == 1 || formatTag == 3 {
                    return Int(bytes[14]) | (Int(bytes[15]) << 8)
                } else if formatTag == 0xFFFE, fmtData.count >= 40 {
                    // WAVE_FORMAT_EXTENSIBLE - valid bits per sample at offset 18
                    return Int(bytes[18]) | (Int(bytes[19]) << 8)
                }
                return nil
            }

            // Skip chunk (pad to even)
            let skipSize = chunkSize + (chunkSize % 2)
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(skipSize))
        }
    }
}

// MARK: - AIFF Parser

nonisolated enum AIFFParser {
    /// Reads the actual bit depth from an AIFF file's COMM chunk.
    static func extractBitDepth(from url: URL) -> Int? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        // FORM header
        guard let form = try? fileHandle.read(upToCount: 12), form.count == 12 else { return nil }
        guard String(data: form[0..<4], encoding: .ascii) == "FORM" else { return nil }

        // Walk chunks
        while true {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let chunkID = String(data: header[0..<4], encoding: .ascii) ?? ""
            let chunkSize = Int(header[4]) << 24 | (Int(header[5]) << 16) | (Int(header[6]) << 8) | Int(header[7])

            if chunkID == "COMM" {
                guard let commData = try? fileHandle.read(upToCount: min(chunkSize, 18)), commData.count >= 18 else { return nil }

                let bytes = [UInt8](commData)
                // Sample size is at offset 14-15 (big-endian)
                return Int(bytes[14]) << 8 | Int(bytes[15])
            }

            // Skip chunk (pad to even)
            let skipSize = chunkSize + (chunkSize % 2)
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(skipSize))
        }
    }
}

// MARK: - ALAC Parser

nonisolated enum ALACParser {
    /// Reads bit depth from an ALAC (M4A) file's magic cookie.
    static func extractBitDepth(from url: URL) -> Int? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        // Read first 8 bytes to check for ftyp
        guard let ftyp = try? fileHandle.read(upToCount: 8), ftyp.count == 8 else { return nil }
        guard String(data: ftyp[4..<8], encoding: .ascii) == "ftyp" else { return nil }

        // Walk atoms
        while true {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let size = Int(header[0]) << 24 | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            let type = String(data: header[4..<8], encoding: .ascii) ?? ""

            if type == "moov" {
                return parseMoovForBitDepth(fileHandle: fileHandle, size: size)
            }

            if size < 8 { return nil }
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(size - 8))
        }
    }

    private static func parseMoovForBitDepth(fileHandle: FileHandle, size: Int) -> Int? {
        let endOffset = fileHandle.offsetInFile + UInt64(size - 8)

        while fileHandle.offsetInFile < endOffset {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let atomSize = Int(header[0]) << 24 | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            let atomType = String(data: header[4..<8], encoding: .ascii) ?? ""

            if atomType == "trak" {
                if let depth = parseTrakForBitDepth(fileHandle: fileHandle, size: atomSize) {
                    return depth
                }
            }

            if atomSize < 8 { return nil }
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(atomSize - 8))
        }
        return nil
    }

    private static func parseTrakForBitDepth(fileHandle: FileHandle, size: Int) -> Int? {
        let endOffset = fileHandle.offsetInFile + UInt64(size - 8)

        while fileHandle.offsetInFile < endOffset {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let atomSize = Int(header[0]) << 24 | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            let atomType = String(data: header[4..<8], encoding: .ascii) ?? ""

            if atomType == "mdia" {
                if let depth = parseMdiaForBitDepth(fileHandle: fileHandle, size: atomSize) {
                    return depth
                }
            }

            if atomSize < 8 { return nil }
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(atomSize - 8))
        }
        return nil
    }

    private static func parseMdiaForBitDepth(fileHandle: FileHandle, size: Int) -> Int? {
        let endOffset = fileHandle.offsetInFile + UInt64(size - 8)

        while fileHandle.offsetInFile < endOffset {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let atomSize = Int(header[0]) << 24 | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            let atomType = String(data: header[4..<8], encoding: .ascii) ?? ""

            if atomType == "minf" {
                if let depth = parseMinfForBitDepth(fileHandle: fileHandle, size: atomSize) {
                    return depth
                }
            }

            if atomSize < 8 { return nil }
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(atomSize - 8))
        }
        return nil
    }

    private static func parseMinfForBitDepth(fileHandle: FileHandle, size: Int) -> Int? {
        let endOffset = fileHandle.offsetInFile + UInt64(size - 8)

        while fileHandle.offsetInFile < endOffset {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let atomSize = Int(header[0]) << 24 | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            let atomType = String(data: header[4..<8], encoding: .ascii) ?? ""

            if atomType == "stbl" {
                if let depth = parseStblForBitDepth(fileHandle: fileHandle, size: atomSize) {
                    return depth
                }
            }

            if atomSize < 8 { return nil }
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(atomSize - 8))
        }
        return nil
    }

    private static func parseStblForBitDepth(fileHandle: FileHandle, size: Int) -> Int? {
        let endOffset = fileHandle.offsetInFile + UInt64(size - 8)

        while fileHandle.offsetInFile < endOffset {
            guard let header = try? fileHandle.read(upToCount: 8), header.count == 8 else { return nil }

            let atomSize = Int(header[0]) << 24 | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            let atomType = String(data: header[4..<8], encoding: .ascii) ?? ""

            if atomType == "stsd" {
                // Skip version/flags (4 bytes)
                try? fileHandle.seek(toOffset: fileHandle.offsetInFile + 4)

                // Entry count (4 bytes)
                guard let countData = try? fileHandle.read(upToCount: 4), countData.count == 4 else { return nil }

                // First entry
                guard let entryHeader = try? fileHandle.read(upToCount: 8), entryHeader.count == 8 else { return nil }
                let entrySize = Int(entryHeader[0]) << 24 | (Int(entryHeader[1]) << 16) | (Int(entryHeader[2]) << 8) | Int(entryHeader[3])
                let format = String(data: entryHeader[4..<8], encoding: .ascii) ?? ""

                if format == "alac" {
                    // Skip 6 bytes reserved + 2 bytes data ref index
                    try? fileHandle.seek(toOffset: fileHandle.offsetInFile + 8)

                    // Version, revision, vendor (16 bytes)
                    try? fileHandle.seek(toOffset: fileHandle.offsetInFile + 16)

                    // Channel count (2 bytes), sample size (2 bytes)
                    guard let sampleData = try? fileHandle.read(upToCount: 4), sampleData.count == 4 else { return nil }
                    let sampleSize = Int(sampleData[2]) << 8 | Int(sampleData[3])
                    return sampleSize
                }
                return nil
            }

            if atomSize < 8 { return nil }
            try? fileHandle.seek(toOffset: fileHandle.offsetInFile + UInt64(atomSize - 8))
        }
        return nil
    }
}