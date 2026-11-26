// CubeLUT (from 1Shot) — loads standard .cube 3D LUT files (Resolve / Final Cut / LUT packs)
// and keeps a small library of them in Application Support.

import Foundation
import CoreImage

final class CubeLUT {
    enum LUTError: LocalizedError {
        case unreadable, unsupported1D, badSize, wrongCount(Int, Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file couldn't be read as a .cube LUT."
            case .unsupported1D: return "This is a 1D LUT. Only 3D .cube LUTs are supported."
            case .badSize: return "The LUT doesn't say its size (LUT_3D_SIZE) or the size is unusual."
            case .wrongCount(let found, let expected):
                return "The LUT has \(found) color entries but should have \(expected)."
            }
        }
    }

    let name: String
    let dimension: Int
    let data: Data            // RGBA float, red changing fastest — what Core Image's color cube wants

    init(url: URL) throws {
        guard let bytes = try? Data(contentsOf: url) else { throw LUTError.unreadable }
        var table = Table()
        if bytes.allSatisfy({ $0 < 0x80 }) {
            // Plain ASCII (nearly every .cube file): read straight from the bytes. Several times
            // faster than going through text line by line, and a 65-point LUT has ~275,000 lines.
            try bytes.withUnsafeBytes { try table.read(ascii: $0.bindMemory(to: UInt8.self)) }
        } else {
            // Anything else (an accented title, a byte-order mark): as text, which knows every
            // kind of space and line end.
            guard let text = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { throw LUTError.unreadable }
            try table.read(text: text)
        }
        let (size, values) = try table.finished()
        name = url.deletingPathExtension().lastPathComponent
        dimension = size
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// What's been read from a .cube file so far.
    private struct Table {
        var size = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        /// A line starting with `word` (already upper-cased): true if it's one of the file's settings
        /// (handled here), false if not (the line is then read as a color entry).
        mutating func setting(_ word: String, _ rest: () -> [String]) throws -> Bool {
            switch word {
            case "TITLE":
                return true
            case "LUT_1D_SIZE":
                throw LUTError.unsupported1D
            case "LUT_3D_SIZE":
                size = rest().first.flatMap { Int($0) } ?? 0
                if size >= 2 && size <= 256 { values.reserveCapacity(size * size * size * 4) }
                return true
            case "DOMAIN_MIN":
                domainMin = rest().compactMap { Float($0) }
                return true
            case "DOMAIN_MAX":
                domainMax = rest().compactMap { Float($0) }
                return true
            default:
                return false
            }
        }

        mutating func read(text: String) throws {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard let first = parts.first else { continue }
                if try setting(first.uppercased(), { parts.dropFirst().map(String.init) }) { continue }
                let nums = parts.prefix(3).compactMap { Float($0) }
                if nums.count == 3 { values += [nums[0], nums[1], nums[2], 1] }
            }
        }

        /// The same reading as `read(text:)`, for a file that is all ASCII: lines end at LF, CR,
        /// VT or FF; words are separated by spaces and tabs.
        mutating func read(ascii bytes: UnsafeBufferPointer<UInt8>) throws {
            let count = bytes.count
            var words: [Range<Int>] = []
            words.reserveCapacity(8)
            func text(_ range: Range<Int>) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
            }
            var i = 0
            while i < count {
                // Split one line into words.
                words.removeAll(keepingCapacity: true)
                var wordStart = -1
                while i < count {
                    let c = bytes[i]
                    if c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C { break }
                    if c == 0x20 || c == 0x09 {
                        if wordStart >= 0 { words.append(wordStart..<i); wordStart = -1 }
                    } else if wordStart < 0 {
                        wordStart = i
                    }
                    i += 1
                }
                if wordStart >= 0 { words.append(wordStart..<i) }
                i += 1                                              // past the line end
                guard let first = words.first else { continue }
                let lead = bytes[first.lowerBound]
                if lead == UInt8(ascii: "#") { continue }
                // Settings all start with a letter; color entries never do.
                let letter = lead | 0x20
                if letter >= UInt8(ascii: "a"), letter <= UInt8(ascii: "z"),
                   try setting(text(first).uppercased(), { words.dropFirst().map(text) }) { continue }
                guard words.count >= 3, let r = Float(text(words[0])), let g = Float(text(words[1])),
                      let b = Float(text(words[2])) else { continue }
                values.append(r); values.append(g); values.append(b); values.append(1)
            }
        }

        /// Checks the table is complete and returns its size and RGBA values.
        mutating func finished() throws -> (Int, [Float]) {
            guard size >= 2, size <= 256 else { throw LUTError.badSize }
            let expected = size * size * size
            guard values.count == expected * 4 else { throw LUTError.wrongCount(values.count / 4, expected) }

            // Rare: output values given in a range other than 0…1 — rescale them.
            if domainMin.count == 3, domainMax.count == 3, domainMin != [0, 0, 0] || domainMax != [1, 1, 1] {
                for i in stride(from: 0, to: values.count, by: 4) {
                    for c in 0..<3 {
                        let span = max(domainMax[c] - domainMin[c], 0.0001)
                        values[i + c] = (values[i + c] - domainMin[c]) / span
                    }
                }
            }
            return (size, values)
        }
    }

    private static let rec709 = CGColorSpace(name: CGColorSpace.itur_709)

    func apply(to image: CIImage) -> CIImage {
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(dimension, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        // Look LUTs expect normal Rec. 709 video values going in.
        f.setValue(Self.rec709, forKey: "inputColorSpace")
        return f.outputImage ?? image
    }

    // MARK: Loaded LUTs

    // Reading a .cube file takes a moment (a 65-point LUT is ~275,000 lines), and the same few LUTs
    // are asked for again and again: every time a look is applied or a clip in another group is
    // picked. So the last few are kept, and re-read only if the file on disk has changed.
    private static let cacheLock = NSLock()
    private static var cache: [String: (modified: Date, size: Int, lut: CubeLUT)] = [:]
    private static var cacheOrder: [String] = []        // least recently used first
    private static let cacheLimit = 8

    private static func stamp(of path: String) -> (modified: Date, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        return (modified, size)
    }

    private static func remember(_ lut: CubeLUT, path: String, stamp: (modified: Date, size: Int)) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[path] = (stamp.modified, stamp.size, lut)
        cacheOrder.removeAll { $0 == path }
        cacheOrder.append(path)
        while cacheOrder.count > cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// The LUT in this file: the copy already loaded if the file hasn't changed, else read now.
    static func cached(url: URL) throws -> CubeLUT {
        let path = url.standardizedFileURL.path
        let stamp = stamp(of: path)
        if let stamp {
            cacheLock.lock()
            let hit = cache[path]
            cacheLock.unlock()
            if let hit, hit.modified == stamp.modified, hit.size == stamp.size { return hit.lut }
        }
        let lut = try CubeLUT(url: url)
        if let stamp { remember(lut, path: path, stamp: stamp) }
        return lut
    }

    // MARK: Library

    /// ~/Library/Application Support/1Shot/LUTs: the same LUT library as 1Shot, so a LUT loaded in
    /// either app shows up in both.
    static let libraryFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("1Shot/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func libraryFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies a .cube into the library (replacing one with the same name) and returns the copy.
    static func importToLibrary(_ url: URL) throws -> URL {
        let lut = try CubeLUT(url: url)    // make sure it's valid before keeping it
        try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        let destination = libraryFolder.appendingPathComponent(url.lastPathComponent)
        if url.standardizedFileURL != destination.standardizedFileURL {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }
        // It was just read to check it: keep that, so using it right away doesn't read it again.
        let path = destination.standardizedFileURL.path
        if let stamp = stamp(of: path) { remember(lut, path: path, stamp: stamp) }
        return destination
    }
}
