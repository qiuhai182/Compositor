import Foundation

/// The system fonts stb_truetype rasterizes from: a one-time scan of each platform's font
/// directories with a fuzzy name match, so a project asking for "Helvetica" gets something
/// readable on every OS (Arial on Windows, DejaVu Sans on Linux). This is filename matching, not
/// font metadata — enough for the portable renderer's documented downgrade, not a font manager.
nonisolated final class FontBook {
    /// A face loaded into stb_truetype, owning its font bytes.
    nonisolated final class LoadedFont {
        let name: String
        private let handle: OpaquePointer

        init?(data: [UInt8], name: String) {
            guard let handle = data.withUnsafeBufferPointer({ bytes in
                text_font_init(bytes.baseAddress, numericCast(from: bytes.count))
            }) else { return nil }
            self.handle = handle
            self.name = name
        }
        deinit { text_font_release(handle) }

        /// The scale from font units to pixels at `pixelHeight` em size.
        func scale(forPixelHeight pixelHeight: Double) -> Float {
            text_scale_for_pixel_height(handle, Float(pixelHeight))
        }

        /// Ascent above the baseline and descent below it, in pixels, both positive.
        func metrics(scale: Float) -> (ascent: Double, descent: Double, lineGap: Double) {
            var ascent: Float = 0, descent: Float = 0, lineGap: Float = 0
            text_font_vmetrics(handle, scale, &ascent, &descent, &lineGap)
            return (Double(ascent), Double(descent), Double(lineGap))
        }

        func glyphIndex(of codepoint: Unicode.Scalar) -> Int {
            Int(text_glyph_index(handle, codepoint.value))
        }

        func advance(of glyphIndex: Int, scale: Float) -> Double {
            Double(text_glyph_advance(handle, scale, Int32(glyphIndex)))
        }

        func kernAdvance(left: Int, right: Int, scale: Float) -> Double {
            Double(text_glyph_kern_advance(handle, Int32(left), Int32(right), scale))
        }

        /// A glyph's coverage bitmap: `width * height` bytes of 0...255, rows packed top-down,
        /// drawn with its top-left corner at (pen x + xOffset, baseline + yOffset), y down. Nil
        /// when the glyph draws nothing, which is not an error — the pen just moves on.
        func coverage(of glyphIndex: Int, scale: Float)
                -> (data: [UInt8], width: Int, height: Int, xOffset: Int, yOffset: Int)? {
            var width: Int32 = 0, height: Int32 = 0, xOffset: Int32 = 0, yOffset: Int32 = 0
            guard let bitmap = text_rasterize_glyph(handle, scale, Int32(glyphIndex),
                                                    &width, &height, &xOffset, &yOffset),
                  width > 0, height > 0 else { return nil }
            let data = Array(UnsafeBufferPointer(start: bitmap, count: Int(width) * Int(height)))
            text_bitmap_release(bitmap)
            return (data, Int(width), Int(height), Int(xOffset), Int(yOffset))
        }
    }

    /// What the usual cross-platform stand-ins are called on disk, keyed by the normalized name.
    private static let aliases: [String: [String]] = [
        "helvetica": ["arial", "liberationsans", "dejavusans", "segoeui", "freesans", "nimbussans"],
        "arial": ["liberationsans", "helvetica", "dejavusans"],
        "timesnewroman": ["times", "liberationserif", "dejavuserif", "freeserif"],
        "couriernew": ["courier", "liberationmono", "dejavusansmono", "cousine"],
        "georgia": ["liberationserif", "dejavuserif"],
        "verdana": ["dejavusans", "liberationsans"],
    ]

    private let directories: [String]
    private var scanned = false
    /// Normalized filename stems to the font files that carry them, sorted for determinism.
    private var index: [String: [String]] = [:]
    private var loaded: [String: LoadedFont] = [:]
    private var failed: Set<String> = []
    /// Asked-for names to what answered, so repeat lookups are free.
    private var cache: [String: LoadedFont] = [:]

    init(directories: [String]? = nil) {
        self.directories = directories ?? FontBook.defaultDirectories
    }

    private static var defaultDirectories: [String] {
        #if os(macOS)
        return ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts",
                NSHomeDirectory() + "/Library/Fonts"]
        #elseif os(Windows)
        return ["C:\\Windows\\Fonts"]
        #else
        return ["/usr/share/fonts", "/usr/local/share/fonts", "/usr/share/fonts/truetype"]
        #endif
    }

    /// Lowercase without spaces, hyphens or underscores: what filenames and requests are compared by.
    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    /// The font for a style name like "Helvetica": an exact filename stem first, then a prefix or
    /// substring match, then the usual cross-platform aliases, and finally the first font on disk
    /// that loads at all, so text renders legibly even when the requested face is missing everywhere.
    func font(named name: String) -> LoadedFont? {
        let key = FontBook.normalized(name)
        if let cached = cache[key] { return cached }
        for candidate in [key] + (FontBook.aliases[key] ?? []) {
            if let loaded = load(matching: candidate) {
                cache[key] = loaded
                return loaded
            }
        }
        scanIfNeeded()
        for stem in index.keys.sorted() {
            if let loaded = loadAny(index[stem] ?? []) {
                cache[key] = loaded
                return loaded
            }
        }
        return nil
    }

    /// Faces the requested stem, then any stem it prefixes (and, for four letters or more, contains).
    private func load(matching key: String) -> LoadedFont? {
        scanIfNeeded()
        if let loaded = loadAny(index[key] ?? []) { return loaded }
        let near = index.keys.filter { $0 != key && ($0.hasPrefix(key) || (key.count >= 4 && $0.contains(key))) }.sorted()
        for stem in near {
            if let loaded = loadAny(index[stem] ?? []) { return loaded }
        }
        return nil
    }

    private func loadAny(_ paths: [String]) -> LoadedFont? {
        paths.lazy.compactMap { loadFont(at: $0) }.first
    }

    private func loadFont(at path: String) -> LoadedFont? {
        if let loaded = loaded[path] { return loaded }
        guard !failed.contains(path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let font = LoadedFont(data: [UInt8](data),
                                    name: URL(fileURLWithPath: path).lastPathComponent) else {
            failed.insert(path)
            return nil
        }
        loaded[path] = font
        return font
    }

    private func scanIfNeeded() {
        if scanned { return }
        scanned = true
        let manager = FileManager.default
        for directory in directories {
            guard let enumerator = manager.enumerator(atPath: directory) else { continue }
            for relative in enumerator {
                guard let relative = relative as? String else { continue }
                let file = URL(fileURLWithPath: relative)
                guard ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) else { continue }
                let stem = FontBook.normalized(file.deletingPathExtension().lastPathComponent)
                index[stem, default: []].append(
                    URL(fileURLWithPath: directory).appendingPathComponent(relative).path)
            }
        }
        for (stem, paths) in index { index[stem] = paths.sorted() }
    }
}
