import Foundation

// The Type tool's stored style: the text, its face, and the per-letter runs that override either.
// The manifest saves these as they are; measuring and drawing the text is the app's job.

nonisolated enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left = "Left", center = "Center", right = "Right"
}

nonisolated struct LayerTextStyle: Codable, Equatable, Sendable {
    var content = "Text"
    var fontName = "Helvetica"
    var fontSize: CGFloat = 72
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alignment: TextAlignment = .left
    var tracking: CGFloat = 0
    /// Baseline to baseline, in layer pixels, as Photoshop's Leading is. 0 is Auto: 120% of the font size.
    var leading: CGFloat = 0
    var autoLeading: CGFloat { fontSize * 1.2 }
    var lineHeight: CGFloat { leading > 0 ? leading : autoLeading }
    /// The gap between the text and its box, in layer pixels — the same for point text and a fixed box, so turning
    /// one into the other doesn't move the text, and wide enough to leave the box's edges easy to grab.
    static let padding: CGFloat = 12
    /// Fixed paragraph bounds in layer pixels. Nil supports older point-text layers.
    var boxSize: CGSize? = nil
    var boxIsValid: Bool {
        guard let boxSize else { return true }
        return boxSize.width.isFinite && boxSize.height.isFinite && (16...DocumentLimits.maxSideExtent).contains(boxSize.width)
            && (16...DocumentLimits.maxSideExtent).contains(boxSize.height) && boxSize.width * boxSize.height <= DocumentLimits.maxSurfaceExtent
    }
    /// Letters painted in a color other than `red`/`green`/`blue`, in UTF-16 offsets into `content`, sorted and not
    /// overlapping. Nil when the whole text is one color.
    var colorRuns: [LayerTextColorRun]? = nil
    /// Letters set in a face other than `fontName`, in the same offsets. Nil when the whole text is one face.
    var fontRuns: [LayerTextFontRun]? = nil
    var isValid: Bool {
        content.utf16.count <= 100_000 && boxIsValid
        && fontSize.isFinite && (1...2000).contains(fontSize)
        && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
        && tracking.isFinite && (-100...1000).contains(tracking)
        && leading.isFinite && (0...5000).contains(leading)
        && colorRunsAreValid && fontRunsAreValid
    }
    private var colorRunsAreValid: Bool {
        guard let colorRuns else { return true }
        var end = 0
        for run in colorRuns {
            guard run.location >= end, run.length > 0, run.location <= Int.max - run.length,
                  [run.red, run.green, run.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
            end = run.location + run.length
        }
        return !colorRuns.isEmpty && end <= content.utf16.count
    }
    private var fontRunsAreValid: Bool {
        guard let fontRuns else { return true }
        var end = 0
        for run in fontRuns {
            guard run.location >= end, run.length > 0, run.location <= Int.max - run.length,
                  !run.fontName.isEmpty, run.fontName.count <= 200, !run.fontName.contains(where: \.isNewline) else { return false }
            end = run.location + run.length
        }
        return !fontRuns.isEmpty && end <= content.utf16.count
    }

    /// The color of the UTF-16 unit at `index`.
    func color(at index: Int) -> PaletteColor {
        let run = colorRuns?.first { $0.location <= index && index < $0.location + $0.length }
        return run.map { PaletteColor(red: $0.red, green: $0.green, blue: $0.blue) } ?? PaletteColor(red: red, green: green, blue: blue)
    }

    /// Paints `range` in `color`. An empty range, or one covering the whole text, recolors all of it.
    mutating func setColor(_ color: PaletteColor, in range: NSRange) {
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if start == end || (start == 0 && end == count) {
            red = color.red; green = color.green; blue = color.blue
            colorRuns = nil
            return
        }
        var colors = unitColors
        for index in start..<end { colors[index] = color }
        setUnitColors(colors)
    }

    /// The face of the UTF-16 unit at `index`.
    func fontName(at index: Int) -> String {
        fontRuns?.first { $0.location <= index && index < $0.location + $0.length }?.fontName ?? fontName
    }

    /// The one face covering `range`, or nil when that range is empty or uses more than one.
    func uniformFontName(in range: NSRange) -> String? {
        let count = content.utf16.count
        let start = max(0, min(range.location, count))
        let end = max(start, min(range.location + range.length, count))
        guard end > start else { return nil }
        let face = fontName(at: start)
        var index = start
        for run in fontRuns ?? [] where run.location < end && run.location + run.length > index {
            if run.location > index, fontName != face { return nil }
            if run.fontName != face { return nil }
            index = min(end, max(index, run.location + run.length))
        }
        if index < end, fontName != face { return nil }
        return face
    }

    /// Sets the face of `range`. An empty range, or one covering the whole text, changes all of it.
    mutating func setFont(_ name: String, in range: NSRange) {
        guard !name.isEmpty, name.count <= 200, !name.contains(where: \.isNewline) else { return }
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if start == end || (start == 0 && end == count) {
            fontName = name
            fontRuns = nil
            return
        }
        var fonts = unitFonts
        for index in start..<end { fonts[index] = name }
        setUnitFonts(fonts)
    }

    /// Keeps each letter's color and face when `range` of `content` is replaced by `length` new UTF-16 units, which
    /// take them from the letter before, as typing does. Call before `content` changes.
    mutating func replaceCharacters(in range: NSRange, withLength length: Int) {
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if colorRuns != nil {
            var colors = unitColors
            let inherited = start > 0 ? colors[start - 1] : (end > start ? colors[start] : colors.first ?? PaletteColor(red: red, green: green, blue: blue))
            colors.replaceSubrange(start..<end, with: repeatElement(inherited, count: max(0, length)))
            setUnitColors(colors)
        }
        if fontRuns != nil {
            var fonts = unitFonts
            let inherited = start > 0 ? fonts[start - 1] : (end > start ? fonts[start] : fonts.first ?? fontName)
            fonts.replaceSubrange(start..<end, with: repeatElement(inherited, count: max(0, length)))
            setUnitFonts(fonts)
        }
    }

    private var unitColors: [PaletteColor] {
        let base = PaletteColor(red: red, green: green, blue: blue)
        var colors = Array(repeating: base, count: content.utf16.count)
        for run in colorRuns ?? [] {
            let color = PaletteColor(red: run.red, green: run.green, blue: run.blue)
            for index in max(0, run.location)..<min(colors.count, run.location + run.length) { colors[index] = color }
        }
        return colors
    }

    private mutating func setUnitColors(_ colors: [PaletteColor]) {
        let base = PaletteColor(red: red, green: green, blue: blue)
        var runs: [LayerTextColorRun] = []
        for (index, color) in colors.enumerated() where color != base {
            if let last = runs.last, last.location + last.length == index,
               PaletteColor(red: last.red, green: last.green, blue: last.blue) == color {
                runs[runs.count - 1].length += 1
            } else {
                runs.append(LayerTextColorRun(location: index, length: 1, red: color.red, green: color.green, blue: color.blue))
            }
        }
        colorRuns = runs.isEmpty ? nil : runs
    }

    private var unitFonts: [String] {
        var fonts = Array(repeating: fontName, count: content.utf16.count)
        for run in fontRuns ?? [] {
            for index in max(0, run.location)..<min(fonts.count, run.location + run.length) { fonts[index] = run.fontName }
        }
        return fonts
    }

    private mutating func setUnitFonts(_ fonts: [String]) {
        if let first = fonts.first, fonts.allSatisfy({ $0 == first }) {
            fontName = first
            fontRuns = nil
            return
        }
        var runs: [LayerTextFontRun] = []
        for (index, name) in fonts.enumerated() where name != fontName {
            if let last = runs.last, last.location + last.length == index, last.fontName == name {
                runs[runs.count - 1].length += 1
            } else {
                runs.append(LayerTextFontRun(location: index, length: 1, fontName: name))
            }
        }
        fontRuns = runs.isEmpty ? nil : runs
    }
}

nonisolated struct LayerTextColorRun: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

nonisolated struct LayerTextFontRun: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var fontName: String
}
