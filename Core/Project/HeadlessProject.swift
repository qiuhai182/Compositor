import Foundation

// The headless engine: a .comp project held entirely in Core types — the manifest, its pixels
// as PixelBuffers, undo/redo — with the same editing operations the MCP tool set exposes. It
// renders through SoftwareRenderer, filters through PortableFilter, and saves and opens the
// same package layout as the app's ProjectStore (manifest.json + images/<uuid>.png).
//
// Documented downgrades against the macOS app: adjustment layers and layer effects are stored
// but not applied when rendering; live masks use a simplified flattened-alpha implementation;
// only PNG images can be imported.

/// The headless engine's errors. The message strings are what MCP clients see.
nonisolated enum HeadlessError: LocalizedError {
    case invalid(String)
    case layerNotFound(UUID)
    case missingImage(UUID)
    case openFailed(String)
    case tooLarge(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): detail
        case .layerNotFound(let id): "No layer with id \(id.uuidString)."
        case .missingImage(let id): "The layer \(id.uuidString) has no pixels."
        case .openFailed(let path): "The project at \(path) could not be opened."
        case .tooLarge(let detail): detail
        case .unsupported(let detail): detail
        }
    }
}

nonisolated final class HeadlessProject {
    /// Everything an undo step restores. PixelBuffers are value types, so this is cheap to hold.
    private struct State {
        var manifest: ProjectManifest
        var images: [UUID: PixelBuffer]
        var masks: [UUID: PixelBuffer]
        var activeLayerID: UUID?
        var modified: Bool
    }

    private(set) var manifest: ProjectManifest
    private(set) var images: [UUID: PixelBuffer]
    private(set) var masks: [UUID: PixelBuffer]
    private(set) var activeLayerID: UUID?
    private(set) var modified = false
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    /// Where the project was opened from or last saved to, for save-in-place.
    private(set) var projectURL: URL?

    init(width: Int, height: Int, resolution: Double? = nil) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw HeadlessError.tooLarge("Canvas dimensions must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        let layer = ProjectLayerRecord(id: UUID(), name: "Layer 1", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)), imageFile: nil)
        manifest = ProjectManifest(resolution: resolution.map { max(1, $0) }, documentID: UUID(),
            width: width, height: height, activeLayerID: layer.id, layers: [layer])
        images = [:]
        masks = [:]
        activeLayerID = layer.id
    }

    /// For `open(from:)`: the manifest is already complete, no blank layer wanted.
    private init(untouchedManifest: ProjectManifest) {
        manifest = untouchedManifest
        images = [:]
        masks = [:]
        activeLayerID = manifest.activeLayerID
    }

    // MARK: - Undo

    /// Captures the current state as the undo entry for the edit that follows.
    private func beginUndo() {
        undoStack.append(State(manifest: manifest, images: images, masks: masks,
                               activeLayerID: activeLayerID, modified: modified))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        modified = true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Undoes, or redoes with `redo`; reports whether anything happened.
    @discardableResult
    func undo(redo: Bool = false) -> Bool {
        let source = redo ? redoStack : undoStack
        guard let state = source.last else { return false }
        if redo { redoStack.removeLast() } else { undoStack.removeLast() }
        (redo ? undoStack : redoStack).append(
            State(manifest: manifest, images: images, masks: masks,
                  activeLayerID: activeLayerID, modified: modified))
        manifest = state.manifest
        images = state.images
        masks = state.masks
        activeLayerID = state.activeLayerID
        modified = state.modified
        return true
    }

    // MARK: - Layers

    /// A name that doesn't collide with an existing layer's.
    func uniqueName(_ base: String) -> String {
        let names = Set(manifest.layers.map(\.name))
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Adds a layer record at the top of the stack (or at `index`, bottom-to-top), nested in
    /// `parentID` when it names a group. Returns the new layer's id and sets it active.
    private func append(_ newRecord: ProjectLayerRecord, parentID: UUID?, index: Int?) -> UUID {
        var layers = manifest.layers
        var record = newRecord
        record.parentID = parentID
        layers.insert(record, at: index.map { min(max(0, $0), layers.count) } ?? layers.count)
        manifest.layers = layers
        activeLayerID = record.id
        return record.id
    }

    private func resolvedParent(_ requested: UUID?) throws -> UUID? {
        guard let requested else { return nil }
        guard let parent = manifest.layers.first(where: { $0.id == requested }) else {
            throw HeadlessError.layerNotFound(requested)
        }
        guard parent.isGroup == true else {
            throw HeadlessError.invalid("parent_id must name a group layer.")
        }
        return requested
    }

    private func layerIndex(_ id: UUID) throws -> Int {
        guard let index = manifest.layers.firstIndex(where: { $0.id == id }) else {
            throw HeadlessError.layerNotFound(id)
        }
        return index
    }

    func addImage(pngData: Data, name: String?, x: Double?, y: Double?,
                  parentID: UUID?, index: Int?) throws -> UUID {
        let pixels = try PNGCodec.decode(pngData)
        let used = images.values.reduce(0) { $0 + $1.width * $1.height }
        guard used + pixels.width * pixels.height <= DocumentLimits.documentPixelBudget else {
            throw HeadlessError.tooLarge("The document exceeds its \(DocumentLimits.documentBudgetMegapixels)-megapixel budget.")
        }
        beginUndo()
        let id = UUID()
        // Default placement centers the image; a provided axis overrides that one axis.
        let origin = CGPoint(
            x: x ?? (Double(manifest.width - pixels.width) / 2),
            y: y ?? (Double(manifest.height - pixels.height) / 2))
        var transform = LayerTransform(origin: origin, size: CGSize(width: pixels.width, height: pixels.height))
        transform.sampling = .smooth
        let newRecord = ProjectLayerRecord(id: id, name: name.map(uniqueName) ?? uniqueName("Layer"),
            isVisible: true, transform: transform, imageFile: "\(id.uuidString).png")
        images[id] = pixels
        return append(newRecord, parentID: try resolvedParent(parentID), index: index)
    }

    func addBlank(name: String?, width: Int?, height: Int?, x: Double?, y: Double?,
                  parentID: UUID?) throws -> UUID {
        let width = width ?? manifest.width, height = height ?? manifest.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw HeadlessError.tooLarge("Layer size must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        beginUndo()
        let newRecord = ProjectLayerRecord(id: UUID(), name: name.map(uniqueName) ?? uniqueName("Layer"),
            isVisible: true,
            transform: LayerTransform(origin: CGPoint(x: x ?? 0, y: y ?? 0),
                                      size: CGSize(width: width, height: height)), imageFile: nil)
        return append(newRecord, parentID: try resolvedParent(parentID), index: nil)
    }

    func addGroup(name: String?, parentID: UUID?) throws -> UUID {
        beginUndo()
        let newRecord = ProjectLayerRecord(id: UUID(), name: name.map(uniqueName) ?? uniqueName("Group"),
            isVisible: true,
            transform: LayerTransform(origin: .zero,
                                      size: CGSize(width: manifest.width, height: manifest.height)),
            imageFile: nil)
        return append(newRecord, parentID: try resolvedParent(parentID), index: nil)
    }

    /// Renames a layer or changes its visibility, opacity or blend mode.
    func update(_ id: UUID, name: String?, visible: Bool?, opacity: Double?, blendMode: LayerBlendMode?) throws {
        let index = try layerIndex(id)
        if let opacity {
            guard (0...1).contains(opacity) else { throw HeadlessError.invalid("Opacity is 0–1.") }
        }
        beginUndo()
        manifest.layers[index] = manifest.layers[index].editing {
            if let name { $0.name = name }
            if let visible { $0.isVisible = visible }
            if let opacity { $0.opacity = opacity }
            if let blendMode { $0.blendMode = blendMode }
        }
    }

    /// Moves a layer in the stack (bottom-to-top index) and/or into a group.
    func move(_ id: UUID, parentID: UUID?, index: Int?) throws {
        _ = try layerIndex(id)
        if let parent = try resolvedParent(parentID) {
            // Nesting a group inside its own descendant would break the tree; validate catches it.
            var proposed = manifest.layers
            let current = try layerIndex(id)
            proposed[current] = proposed[current].editing { $0.parentID = parent }
            try validated(proposed)
            beginUndo()
            manifest.layers = proposed
        }
        if let index {
            let current = try layerIndex(id)
            let clamped = min(max(index, 0), manifest.layers.count - 1)
            guard clamped != current else { return }
            beginUndo()
            var layers = manifest.layers
            layers.insert(layers.remove(at: current), at: clamped)
            manifest.layers = layers
        }
    }

    private func validated(_ layers: [ProjectLayerRecord]) throws {
        do { try LayerHierarchy.validate(layers) }
        catch { throw HeadlessError.invalid("That layer nesting is not allowed.") }
    }

    /// Deletes layers; a group takes its contents with it. Live masks pointing at the deleted
    /// layers are unlinked, exactly as the app does.
    func delete(_ ids: [UUID]) throws {
        for id in ids { _ = try layerIndex(id) }
        beginUndo()
        var doomed = Set(ids)
        let children = Dictionary(grouping: manifest.layers, by: \.parentID)
        var pending = ids
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where doomed.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        manifest.layers.removeAll { doomed.contains($0.id) }
        images = images.filter { !doomed.contains($0.key) }
        masks = masks.filter { !doomed.contains($0.key) }
        for index in manifest.layers.indices {
            if let source = manifest.layers[index].maskSourceID, doomed.contains(source) {
                manifest.layers[index] = manifest.layers[index].editing { $0.maskSourceID = nil }
            }
        }
        if let active = activeLayerID, doomed.contains(active) {
            activeLayerID = manifest.layers.last?.id
        }
    }

    /// Sets a layer's position, size, rotation (degrees clockwise) or flips.
    func transform(_ id: UUID, x: Double?, y: Double?, width: Double?, height: Double?,
                   rotation: Double?, flipX: Bool?, flipY: Bool?) throws {
        let index = try layerIndex(id)
        var transform = manifest.layers[index].transform
        if let x { transform.origin.x = CGFloat(x) }
        if let y { transform.origin.y = CGFloat(y) }
        if let width { transform.size.width = CGFloat(width) }
        if let height { transform.size.height = CGFloat(height) }
        if let rotation { transform.rotation = CGFloat(rotation) }
        if let flipX { transform.flipX = flipX }
        if let flipY { transform.flipY = flipY }
        guard transform.isValid else {
            throw HeadlessError.invalid("The transform is out of range (size 1–300000, finite values).")
        }
        beginUndo()
        manifest.layers[index] = manifest.layers[index].editing { $0.transform = transform }
    }

    /// Adds a raster mask (any PNG; its luminance is the coverage, white reveals), sets a
    /// clipping-mask source layer, or toggles an existing mask.
    func setMask(_ id: UUID, maskPngData: Data?, sourceLayerID: UUID?, enabled: Bool?) throws {
        if let source = sourceLayerID {
            guard source != id, let record = try? layerIndex(source).map({ manifest.layers[$0] }),
                  record.isGroup != true, record.adjustment == nil else {
                throw HeadlessError.layerNotFound(source)
            }
            beginUndo()
            let index = try layerIndex(id)
            manifest.layers[index] = manifest.layers[index].editing { $0.maskSourceID = source }
        }
        if let pngData = maskPngData {
            let pixels = try PNGCodec.decodeMask(pngData)
            beginUndo()
            let index = try layerIndex(id)
            masks[id] = pixels
            manifest.layers[index] = manifest.layers[index]
                .editing { $0.maskFile = "\(id.uuidString).mask.png"; $0.maskEnabled = true }
        }
        if let enabled {
            guard masks[id] != nil else {
                throw HeadlessError.invalid("This layer has no mask; add one first.")
            }
            beginUndo()
            let index = try layerIndex(id)
            manifest.layers[index] = manifest.layers[index].editing { $0.maskEnabled = enabled }
        }
    }

    /// Renders text into a new text layer. Fails when no system font can be loaded.
    func addText(_ style: LayerTextStyle, x: Double?, y: Double?) throws -> UUID {
        guard style.isValid else {
            throw HeadlessError.invalid("The text style is invalid (font size 1–2000).")
        }
        guard let pixels = TextRasterizer.render(style, fonts: FontBook()) else {
            throw HeadlessError.invalid("No usable font was found for the text.")
        }
        beginUndo()
        let id = UUID()
        var transform = LayerTransform(
            origin: CGPoint(x: x ?? 0, y: y ?? 0),
            size: CGSize(width: pixels.width, height: pixels.height))
        transform.sampling = .smooth
        let newRecord = ProjectLayerRecord(id: id, name: uniqueName(style.content),
            isVisible: true, transform: transform, imageFile: "\(id.uuidString).png")
        images[id] = pixels
        manifest.layers.append(newRecord)
        activeLayerID = id
        return id
    }

    // MARK: - Filters and adjustments

    /// Runs one of the portable filters on a layer's pixels. Blur-style filters can grow the
    /// buffer; the layer stays centered, exactly as the app's pipeline does.
    func filterApply(_ id: UUID, filter: PortableFilter, parameters: FilterParameters) throws {
        let index = try layerIndex(id)
        let existing = manifest.layers[index]
        guard existing.isGroup != true, let source = images[id] else {
            throw HeadlessError.missingImage(id)
        }
        let output = filter.render(parameters, scale: 1, to: source)
        beginUndo()
        var transform = existing.transform
        if output.width != source.width || output.height != source.height {
            let center = transform.center
            transform.size = CGSize(width: transform.size.width * CGFloat(output.width) / CGFloat(source.width),
                                    height: transform.size.height * CGFloat(output.height) / CGFloat(source.height))
            transform.origin = CGPoint(x: center.x - transform.size.width / 2,
                                       y: center.y - transform.size.height / 2)
        }
        manifest.layers[index] = existing.editing {
            $0.transform = transform
            // The text raster is replaced, so the layer stops being live text.
            $0.text = nil
        }
        images[id] = output
    }

    /// Stores a color adjustment on a layer. The headless renderer does not apply adjustments
    /// (see the downgrades note at the top of this file) — the manifest carries them so the
    /// macOS app renders them.
    func adjustmentSet(_ id: UUID, kind: AdjustmentKind?, hue: Double?, saturation: Double?,
                       lightness: Double?, colorize: Bool?) throws {
        let index = try layerIndex(id)
        var adjustment = manifest.layers[index].adjustment ?? LayerAdjustment(kind: .hsv)
        if let kind { adjustment.kind = kind }
        if let hue { adjustment.hue = min(180, max(-180, hue)) }
        if let saturation { adjustment.saturation = min(100, max(-100, saturation)) }
        if let lightness { adjustment.lightness = min(100, max(-100, lightness)) }
        if let colorize { adjustment.colorize = colorize }
        beginUndo()
        manifest.layers[index] = manifest.layers[index].editing { $0.adjustment = adjustment }
    }

    // MARK: - Canvas

    /// Crops the canvas to a rectangle, moving the content with it.
    func canvasCrop(x: Int, y: Int, width: Int, height: Int) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw HeadlessError.tooLarge("Canvas dimensions must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        beginUndo()
        // Keeping the rect means the old content moves by (-x, -y) inside the new canvas.
        manifest.layers = shifted(deltaX: -CGFloat(x), deltaY: -CGFloat(y))
        manifest.guides = manifest.guides?.map { $0.offset(x: -CGFloat(x), y: -CGFloat(y)) }
        setCanvas(width: width, height: height)
    }

    /// Grows or shrinks the canvas without scaling the layers, anchored by `anchor` (0–8,
    /// row-major from top-left: where the old canvas sits in the new one). `fill` extends the
    /// canvas with a solid bottom layer behind the content.
    func canvasResize(width: Int, height: Int, anchor: Int,
                      fill: (red: Double, green: Double, blue: Double)?) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              (0...8).contains(anchor) else {
            throw HeadlessError.tooLarge("Canvas dimensions must be 1–\(DocumentLimits.maxSide) pixels, anchor 0–8.")
        }
        let oldWidth = manifest.width, oldHeight = manifest.height
        if let fill {
            let used = images.values.reduce(0) { $0 + $1.width * $1.height }
            guard width * height <= DocumentLimits.documentPixelBudget - used, manifest.layers.count < 10_000 else {
                throw HeadlessError.tooLarge("The document exceeds its \(DocumentLimits.documentBudgetMegapixels)-megapixel budget.")
            }
        }
        beginUndo()
        // Floor division puts the extra pixel on the right/bottom when expanding, and removes
        // it from the left/top when shrinking around the center — the app's CanvasResizer rule.
        let deltaX = CGFloat((width - oldWidth) * (anchor % 3) / 2)
        let deltaY = CGFloat((height - oldHeight) * (anchor / 3) / 2)
        manifest.layers = shifted(deltaX: deltaX, deltaY: deltaY)
        manifest.guides = manifest.guides?.map { $0.offset(x: deltaX, y: deltaY) }
        setCanvas(width: width, height: height)
        if let fill, width > oldWidth || height > oldHeight {
            let id = UUID()
            var pixels = PixelBuffer(width: width, height: height)
            pixels.fill(PixelBuffer.Color(
                red: UInt8((fill.red * 255).rounded()), green: UInt8((fill.green * 255).rounded()),
                blue: UInt8((fill.blue * 255).rounded()), alpha: 255))
            // The old canvas's area stays transparent, holes in the artwork included.
            let left = max(0, Int(deltaX)), top = max(0, Int(deltaY))
            let right = min(width, Int(deltaX) + oldWidth), bottom = min(height, Int(deltaY) + oldHeight)
            if left < right, top < bottom {
                for row in top..<bottom {
                    let base = pixels.index(x: left, y: row)
                    for column in base..<(base + (right - left) * 4) { pixels.data[column] = 0 }
                }
            }
            images[id] = pixels
            let extensionLayer = ProjectLayerRecord(id: id, name: "Canvas Extension", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)),
                imageFile: "\(id.uuidString).png")
            manifest.layers.insert(extensionLayer, at: 0)
        }
    }

    /// Every layer (and mask placement) translated by the canvas change.
    private func shifted(deltaX: CGFloat, deltaY: CGFloat) -> [ProjectLayerRecord] {
        manifest.layers.map { record in
            record.editing { draft in
                var transform = draft.transform
                transform.origin.x += deltaX
                transform.origin.y += deltaY
                draft.transform = transform
                if var placement = draft.maskPlacement {
                    placement.origin.x += deltaX
                    placement.origin.y += deltaY
                    draft.maskPlacement = placement
                }
            }
        }
    }

    private func setCanvas(width: Int, height: Int) {
        // ProjectManifest stores the canvas as let fields; rebuild it around the same layers.
        manifest = ProjectManifest(resolution: manifest.resolution, documentID: manifest.documentID,
            width: width, height: height, activeLayerID: manifest.activeLayerID,
            layers: manifest.layers, guides: manifest.guides)
    }

    // MARK: - Rendering

    /// The composite, bottom-up through the visible non-group layers. Masks: a raster mask
    /// provides the coverage directly; a live mask (clipping mask) flattens its source layer
    /// and samples the alpha into the target layer's space — a simplification of the app's
    /// Core Image mask graph. Adjustments, effects and group masks are not applied (see the
    /// downgrades note at the top of this file).
    func render(layerID: UUID? = nil) throws -> PixelBuffer {
        let byID = Dictionary(uniqueKeysWithValues: manifest.layers.map { ($0.id, $0) })
        var renderer = SoftwareRenderer()
        renderer.begin(width: manifest.width, height: manifest.height, background: .clear)
        if let layerID {
            guard let record = byID[layerID], let pixels = images[layerID] else {
                throw HeadlessError.missingImage(layerID)
            }
            renderer.draw(pixels, transform: record.transform, blendMode: record.blendMode ?? .normal,
                          opacity: 1, mask: coverage(for: record, layerPixels: pixels, byID: byID))
        } else {
            for record in LayerHierarchy.visibleLayers(manifest.layers) {
                guard let pixels = images[record.id] else { continue }
                renderer.draw(pixels, transform: record.transform, blendMode: record.blendMode ?? .normal,
                              opacity: record.effectiveOpacity(in: byID),
                              mask: coverage(for: record, layerPixels: pixels, byID: byID))
            }
        }
        return renderer.finish()
    }

    /// A layer's mask coverage: the raster mask first, else a simplified live mask that reads
    /// its source layer's flattened alpha.
    private func coverage(for record: ProjectLayerRecord, layerPixels: PixelBuffer,
                          byID: [UUID: ProjectLayerRecord]) -> PixelBuffer? {
        if record.maskFile != nil, record.maskEnabled != false, let mask = masks[record.id] {
            return mask
        }
        guard let sourceID = record.maskSourceID, let source = byID[sourceID],
              let sourcePixels = images[sourceID] else { return nil }
        var renderer = SoftwareRenderer()
        renderer.begin(width: manifest.width, height: manifest.height, background: .clear)
        renderer.draw(sourcePixels, transform: source.transform, blendMode: .normal,
                      opacity: source.effectiveOpacity(in: byID), mask: nil)
        let flat = renderer.finish()
        // Map each of the target layer's pixels onto the canvas and read the flattened source's
        // alpha there; nearest sampling is plenty for a coverage map.
        var coverage = PixelBuffer(width: layerPixels.width, height: layerPixels.height)
        for row in 0..<coverage.height {
            for column in 0..<coverage.width {
                let unit = CGPoint(x: (Double(column) + 0.5) / Double(coverage.width),
                                   y: (Double(row) + 0.5) / Double(coverage.height))
                let point = record.transform.point(unit)
                let x = Int(point.x), y = Int(point.y)
                guard x >= 0, x < flat.width, y >= 0, y < flat.height else { continue }
                let alpha = flat.data[flat.index(x: x, y: y) + 3]
                coverage[x: column, y: row] = (alpha, alpha, alpha, alpha)
            }
        }
        return coverage
    }

    /// The composite, downscaled to at most `maxWidth` wide, for previews.
    func previewBuffer(maxWidth: Int) throws -> PixelBuffer {
        try render().downscaled(maxWidth: max(1, maxWidth))
    }

    /// Writes the composite as a PNG file.
    func exportPNG(to url: URL) throws {
        try PNGCodec.encode(render()).write(to: url)
    }

    // MARK: - Package

    /// Saves the .comp package: manifest.json plus one PNG per layer image and mask, matching
    /// the app's ProjectStore layout. Writes into a sibling directory and swaps it into place.
    func save(to url: URL) throws {
        try LayerHierarchy.validate(manifest.layers)
        for layer in manifest.layers {
            if let imageFile = layer.imageFile, imageFile != "\(layer.id.uuidString).png" {
                throw HeadlessError.invalid("Layer \(layer.id.uuidString) has an unexpected image file name.")
            }
            if let maskFile = layer.maskFile, maskFile != "\(layer.id.uuidString).mask.png" {
                throw HeadlessError.invalid("Layer \(layer.id.uuidString) has an unexpected mask file name.")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(manifest)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".compositor-\(UUID().uuidString)", isDirectory: true)
        let imagesDirectory = temporary.appendingPathComponent("images", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try metadata.write(to: temporary.appendingPathComponent("manifest.json"))
            for layer in manifest.layers {
                if layer.imageFile != nil, let pixels = images[layer.id] {
                    try PNGCodec.encode(pixels)
                        .write(to: imagesDirectory.appendingPathComponent("\(layer.id.uuidString).png"))
                }
                if layer.maskFile != nil, let mask = masks[layer.id] {
                    try PNGCodec.encodeMask(mask)
                        .write(to: imagesDirectory.appendingPathComponent("\(layer.id.uuidString).mask.png"))
                }
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        projectURL = url
        modified = false
    }

    /// Opens a .comp package written by the app or by this engine.
    static func open(from url: URL) throws -> HeadlessProject {
        struct Header: Decodable { let format: String; let version: Int }
        let metadata: Data
        do { metadata = try Data(contentsOf: url.appendingPathComponent("manifest.json")) }
        catch { throw HeadlessError.openFailed(url.path) }
        guard let header = try? JSONDecoder().decode(Header.self, from: metadata),
              header.format == "com.compositor.project",
              ProjectManifest.supported.contains(header.version),
              let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: metadata) else {
            throw HeadlessError.openFailed(url.path)
        }
        try LayerHierarchy.validate(manifest.layers)
        let project = HeadlessProject(untouchedManifest: manifest)
        let imagesDirectory = url.appendingPathComponent("images")
        for layer in manifest.layers {
            if let imageFile = layer.imageFile {
                guard imageFile == "\(layer.id.uuidString).png" else { throw HeadlessError.openFailed(url.path) }
                project.images[layer.id] = try PNGCodec.decode(
                    try Data(contentsOf: imagesDirectory.appendingPathComponent(imageFile)))
            }
            if let maskFile = layer.maskFile, layer.maskEnabled != false {
                guard maskFile == "\(layer.id.uuidString).mask.png" else { throw HeadlessError.openFailed(url.path) }
                project.masks[layer.id] = try PNGCodec.decodeMask(
                    try Data(contentsOf: imagesDirectory.appendingPathComponent(maskFile)))
            }
        }
        project.projectURL = url
        return project
    }
}

/// A record's mutable face: `ProjectLayerRecord`'s identity fields are let, so edits build a
/// fresh record. `Draft` keeps the call sites readable.
private struct Draft {
    let id: UUID
    var name: String
    var isVisible: Bool
    var transform: LayerTransform
    var imageFile: String?
    var parentID: UUID?
    var isGroup: Bool?
    var opacity: Double?
    var blendMode: LayerBlendMode?
    var maskFile: String?
    var maskEnabled: Bool?
    var maskSourceID: UUID?
    var adjustment: LayerAdjustment?
    var maskPlacement: LayerTransform?
    var maskLinked: Bool?
    var shape: LayerShapeStyle?
    var effects: LayerEffects?
    var text: LayerTextStyle?

    init(_ record: ProjectLayerRecord) {
        id = record.id
        name = record.name
        isVisible = record.isVisible
        transform = record.transform
        imageFile = record.imageFile
        parentID = record.parentID
        isGroup = record.isGroup
        opacity = record.opacity
        blendMode = record.blendMode
        maskFile = record.maskFile
        maskEnabled = record.maskEnabled
        maskSourceID = record.maskSourceID
        adjustment = record.adjustment
        maskPlacement = record.maskPlacement
        maskLinked = record.maskLinked
        shape = record.shape
        effects = record.effects
        text = record.text
    }

    var record: ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: isVisible, transform: transform,
            imageFile: imageFile, parentID: parentID, isGroup: isGroup, opacity: opacity,
            blendMode: blendMode, maskFile: maskFile, maskEnabled: maskEnabled,
            maskSourceID: maskSourceID, adjustment: adjustment, maskPlacement: maskPlacement,
            maskLinked: maskLinked, shape: shape, effects: effects, text: text)
    }
}

private extension ProjectLayerRecord {
    func editing(_ change: (inout Draft) -> Void) -> ProjectLayerRecord {
        var draft = Draft(self)
        change(&draft)
        return draft.record
    }
}
