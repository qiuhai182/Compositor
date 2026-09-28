import AppKit
import CoreGraphics
import Foundation
import MCP

/// The MCP tool implementations. Every handler runs on the main actor and edits through the same
/// `EditorSession` the app uses, so undo, digests and validation all behave as in the interface.
@MainActor
final class MCPToolHandlers {
    let registry = MCPProjectRegistry()

    func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        do {
            switch params.name {
            case "project_create": return try await projectCreate(arguments)
            case "project_open": return try await projectOpen(arguments)
            case "project_list": return try projectList(arguments)
            case "project_info": return try projectInfo(arguments)
            case "project_save": return try await projectSave(arguments)
            case "project_close": return try await projectClose(arguments)
            case "project_undo": return try projectUndo(arguments)
            case "layer_add_image": return try await layerAddImage(arguments)
            case "layer_add_blank": return try layerAddBlank(arguments)
            case "layer_add_group": return try layerAddGroup(arguments)
            case "layer_update": return try layerUpdate(arguments)
            case "layer_move": return try layerMove(arguments)
            case "layer_delete": return try layerDelete(arguments)
            case "layer_transform": return try layerTransform(arguments)
            case "layer_set_mask": return try layerSetMask(arguments)
            case "layer_add_text": return try layerAddText(arguments)
            case "filter_apply": return try await filterApply(arguments)
            case "adjustment_set": return try adjustmentSet(arguments)
            case "canvas_crop": return try await canvasCrop(arguments)
            case "canvas_resize": return try await canvasResize(arguments)
            case "preview": return try await preview(arguments)
            case "export": return try await export(arguments)
            default: throw MCPToolError.unknownTool(params.name)
            }
        } catch let error as MCPToolError {
            return errorResult(error.localizedDescription)
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    // MARK: - Shared lookups

    private func controller(_ arguments: [String: MCP.Value]) throws -> ProjectController {
        let text = try requiredString(arguments, "project_id")
        guard let id = UUID(uuidString: text), let controller = registry.controller(for: id) else {
            throw MCPToolError.projectNotFound(text)
        }
        return controller
    }

    /// The layer named by `layer_id`, as (array index, layer) right now.
    private func layerAt(_ session: EditorSession, _ arguments: [String: MCP.Value]) throws -> (Int, ImageLayer) {
        let text = try requiredString(arguments, "layer_id")
        guard let id = UUID(uuidString: text),
              let index = session.document?.layers.firstIndex(where: { $0.id == id }) else {
            throw MCPToolError.layerNotFound(text)
        }
        return (index, session.document!.layers[index])
    }

    private func requiredString(_ arguments: [String: MCP.Value], _ key: String) throws -> String {
        guard let value = arguments.string(key), !value.isEmpty else { throw MCPToolError.missingArgument(key) }
        return value
    }

    private func requiredInt(_ arguments: [String: MCP.Value], _ key: String) throws -> Int {
        guard let value = arguments.int(key) else { throw MCPToolError.missingArgument(key) }
        return value
    }

    private func expanded(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private func jsonResult(_ value: MCP.Value, note: String? = nil) -> CallTool.Result {
        var text = note ?? ""
        if let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) {
            if !text.isEmpty { text += "\n" }
            text += string
        }
        return CallTool.Result(content: [.text(text, metadata: nil)], structuredContent: value, isError: false)
    }

    // MARK: - Projects

    private func projectCreate(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let width = try requiredInt(arguments, "width")
        let height = try requiredInt(arguments, "height")
        let id = try registry.create(width: width, height: height, resolution: arguments.double("resolution"))
        guard let controller = registry.controller(for: id) else { throw MCPToolError.projectNotFound(id.uuidString) }
        return jsonResult(projectValue(controller), note: "Created project \(id.uuidString).")
    }

    private func projectOpen(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let path = try requiredString(arguments, "path")
        let url = expanded(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPToolError.invalidArgument("No file at \(url.path).")
        }
        let id = try await registry.open(url: url)
        guard let controller = registry.controller(for: id) else { throw MCPToolError.projectNotFound(id.uuidString) }
        return jsonResult(projectValue(controller), note: "Opened \(url.lastPathComponent).")
    }

    private func projectList(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let projects = registry.ids.compactMap { id -> MCP.Value? in
            guard let controller = registry.controller(for: id), let document = controller.session.document else { return nil }
            var value: [String: MCP.Value] = [
                "id": .string(id.uuidString),
                "width": .int(document.width),
                "height": .int(document.height),
                "modified": .bool(controller.session.isModified),
            ]
            if let path = controller.session.projectURL?.path { value["path"] = .string(path) }
            return .object(value)
        }
        return jsonResult(.object(["projects": .array(projects)]))
    }

    private func projectInfo(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        try jsonResult(projectValue(controller(arguments)))
    }

    private func projectSave(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let controller = try controller(arguments)
        if let path = arguments.string("path") {
            var url = expanded(path)
            if url.pathExtension.isEmpty { url.appendPathExtension("comp") }
            guard await controller.save(to: url) else { throw MCPToolError.saveFailed }
        } else {
            guard controller.session.projectURL != nil else {
                throw MCPToolError.invalidArgument("This project has never been saved; pass a path.")
            }
            guard await controller.save() else { throw MCPToolError.saveFailed }
        }
        return jsonResult(projectValue(controller), note: "Saved.")
    }

    private func projectClose(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let controller = try controller(arguments)
        await registry.close(controller.session.document!.id)
        return textResult("Project closed. Unsaved changes were discarded.")
    }

    private func projectUndo(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard session.document != nil else { throw MCPToolError.noProject }
        if arguments.bool("redo") == true {
            guard session.canRedo else { return textResult("Nothing to redo.") }
            session.redo()
            return textResult("Redone.")
        }
        guard session.canUndo else { return textResult("Nothing to undo.") }
        session.undo()
        return textResult("Undone.")
    }

    // MARK: - Layers

    private func layerAddImage(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard session.document != nil else { throw MCPToolError.noProject }
        let path = try requiredString(arguments, "file_path")
        let url = expanded(path)
        let supported = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp", "gif", "bmp", "svg"]
        guard supported.contains(url.pathExtension.lowercased()) else {
            throw MCPToolError.invalidArgument("Supported: PNG, JPEG, HEIC, TIFF, WebP, GIF, BMP, SVG. PSD and RAW imports need the Compositor app.")
        }
        session.importError = nil
        await session.importImages([url], at: nil)
        guard let id = session.activeLayerID,
              session.document?.layers.contains(where: { $0.id == id }) == true else {
            return errorResult(session.importError ?? "The image could not be imported.")
        }
        if arguments.double("x") != nil || arguments.double("y") != nil {
            let index = session.document!.layers.firstIndex { $0.id == id }!
            let current = session.document!.layers[index].origin
            let origin = CGPoint(x: arguments.double("x") ?? Double(current.x), y: arguments.double("y") ?? Double(current.y))
            session.beginEdit("Move Layer")
            session.document?.layers[index].transform.origin = origin
            session.endEdit()
        }
        if let name = arguments.string("name") { session.renameLayer(id, to: name) }
        if let index = arguments.int("index") { try moveLayer(session, id: id, to: index) }
        return layerReply(session, id: id, note: "Added image layer.")
    }

    private func layerAddBlank(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard let document = session.document else { throw MCPToolError.noProject }
        let width = arguments.int("width") ?? document.width
        let height = arguments.int("height") ?? document.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw MCPToolError.invalidArgument("Layer size must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        var layer = ImageLayer(name: arguments.string("name") ?? uniqueName(document, base: "Layer"),
                               blankSize: CGSize(width: width, height: height))
        layer.transform.origin = CGPoint(x: arguments.double("x") ?? 0, y: arguments.double("y") ?? 0)
        if let parent = parentID(session, arguments) { layer.parentID = parent }
        session.beginEdit("New Blank Layer")
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        session.endEdit()
        return layerReply(session, id: layer.id, note: "Added blank layer.")
    }

    private func layerAddGroup(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard let document = session.document else { throw MCPToolError.noProject }
        var group = ImageLayer(name: arguments.string("name") ?? uniqueName(document, base: "Group"),
                               blankSize: document.size)
        group.isGroup = true
        if let parent = parentID(session, arguments) { group.parentID = parent }
        session.beginEdit("New Group")
        session.document?.layers.append(group)
        session.activeLayerID = group.id
        session.endEdit()
        return layerReply(session, id: group.id, note: "Added group.")
    }

    private func layerUpdate(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard session.document != nil else { throw MCPToolError.noProject }
        let (index, layer) = try layerAt(session, arguments)

        if let name = arguments.string("name") { session.renameLayer(layer.id, to: name) }

        if let visible = arguments.bool("visible") {
            guard let current = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else {
                throw MCPToolError.layerNotFound(layer.id.uuidString)
            }
            session.beginEdit(visible ? "Show Layer" : "Hide Layer")
            session.document?.layers[current].isVisible = visible
            session.endEdit()
        }

        if arguments.double("opacity") != nil || arguments.string("blend_mode") != nil {
            guard let current = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else {
                throw MCPToolError.layerNotFound(layer.id.uuidString)
            }
            session.beginEdit("Layer Appearance")
            defer { session.endEdit() }
            if let opacity = arguments.double("opacity") {
                guard (0...1).contains(opacity) else {
                    throw MCPToolError.invalidArgument("Opacity is 0–1.")
                }
                session.document?.layers[current].opacity = opacity
            }
            if let modeText = arguments.string("blend_mode") {
                guard let mode = LayerBlendMode(rawValue: modeText) else {
                    throw MCPToolError.invalidArgument("Unknown blend mode '\(modeText)'. Valid: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                session.document?.layers[current].blendMode = mode
            }
        }
        return layerReply(session, id: layer.id, note: "Layer updated.")
    }

    private func layerMove(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        let (index, layer) = try layerAt(session, arguments)
        if let parent = parentID(session, arguments) {
            session.beginEdit("Reorder Layers")
            session.document?.layers[index].parentID = parent
            session.endEdit()
        }
        if let index = arguments.int("index") {
            try moveLayer(session, id: layer.id, to: index)
        }
        return layerReply(session, id: layer.id, note: "Layer moved.")
    }

    private func layerDelete(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        let texts = arguments.strings("layer_ids") ?? []
        guard !texts.isEmpty else { throw MCPToolError.missingArgument("layer_ids") }
        let ids = texts.compactMap { UUID(uuidString: $0) }
        guard ids.count == texts.count, !ids.isEmpty else {
            throw MCPToolError.invalidArgument("layer_ids must be layer id strings.")
        }
        // finishDeletingLayers wraps its own undo step and unlinks live masks that pointed at them.
        session.finishDeletingLayers(ids, baked: [:])
        return textResult("Deleted \(ids.count) layer\(ids.count == 1 ? "" : "s").")
    }

    private func layerTransform(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        let (index, layer) = try layerAt(session, arguments)
        var transform = layer.transform
        if let x = arguments.double("x") { transform.origin.x = CGFloat(x) }
        if let y = arguments.double("y") { transform.origin.y = CGFloat(y) }
        if let width = arguments.double("width") { transform.size.width = CGFloat(width) }
        if let height = arguments.double("height") { transform.size.height = CGFloat(height) }
        if let rotation = arguments.double("rotation") { transform.rotation = CGFloat(rotation) }
        if let flipX = arguments.bool("flip_x") { transform.flipX = flipX }
        if let flipY = arguments.bool("flip_y") { transform.flipY = flipY }
        guard transform.isValid else {
            throw MCPToolError.invalidArgument("The transform is out of range (size 1–300000, finite values).")
        }
        session.beginEdit("Transform Layer")
        session.document?.layers[index].transform = transform
        session.endEdit()
        return layerReply(session, id: layer.id, note: "Layer transformed.")
    }

    private func layerSetMask(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard session.document != nil else { throw MCPToolError.noProject }
        let (index, layer) = try layerAt(session, arguments)

        if let sourceText = arguments.string("source_layer_id") {
            guard let source = UUID(uuidString: sourceText),
                  source != layer.id,
                  session.document?.layers.contains(where: { $0.id == source }) == true else {
                throw MCPToolError.layerNotFound(sourceText)
            }
            session.beginEdit("Clipping Mask")
            session.document?.layers[index].maskSourceID = source
            session.endEdit()
        }

        if let path = arguments.string("mask_image_path") {
            let loaded = try MCPImages.load(expanded(path))
            // Masks must be 8-bit grayscale; convert anything else on the way in.
            let asset = try LayerMask.asset(from: MCPImages.grayscale(loaded))
            let current = session.document!.layers[index]
            session.beginEdit("Add Layer Mask")
            session.document?.layers[index].mask = current.mask?.replacing(asset) ?? LayerMask(asset: asset)
            session.endEdit()
        }

        if let enabled = arguments.bool("enabled") {
            guard session.document!.layers[index].mask != nil else {
                throw MCPToolError.invalidArgument("This layer has no mask; add one first.")
            }
            session.beginEdit("Layer Mask")
            session.document?.layers[index].mask?.isEnabled = enabled
            session.endEdit()
        }
        return layerReply(session, id: layer.id, note: "Layer mask set.")
    }

    private func layerAddText(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard session.document != nil else { throw MCPToolError.noProject }
        var style = LayerTextStyle()
        style.content = try requiredString(arguments, "content")
        if let size = arguments.double("font_size") { style.fontSize = CGFloat(size) }
        if let font = arguments.string("font_name") { style.fontName = font }
        if let hex = arguments.string("color") {
            guard let color = MCPImages.color(hex) else {
                throw MCPToolError.invalidArgument("color must be #RRGGBB.")
            }
            style.red = color.red
            style.green = color.green
            style.blue = color.blue
        }
        guard style.isValid else {
            throw MCPToolError.invalidArgument("The text style is invalid (font size 1–2000).")
        }
        let image = try EditorSession.textImage(style)
        let thumbnail = try PixelAdjust.thumbnail(of: image)
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: thumbnail, name: style.content),
                               origin: CGPoint(x: arguments.double("x") ?? 0, y: arguments.double("y") ?? 0))
        layer.text = LayerText(style: style, image: image)
        session.beginEdit("Add Text")
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        session.endEdit()
        return layerReply(session, id: layer.id, note: "Added text layer.")
    }

    // MARK: - Filters and adjustments

    private func filterApply(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let session = try controller(arguments).session
        let kind = try filterKind(try requiredString(arguments, "kind"))
        var settings = FilterSettings()
        if let dict = arguments.object("settings") {
            try applySettings(&settings, dict)
        }
        let (index, layer) = try layerAt(session, arguments)
        guard let asset = layer.asset, !layer.isGroup else {
            throw MCPToolError.invalidArgument("Filters need a layer with pixels.")
        }
        let job = FilterJob(kind: kind, image: asset.image, settings: settings, scale: 1, selection: nil, mapping: .identity)
        let output = try PixelFilter.run(job)
        let thumbnail = try PixelAdjust.thumbnail(of: output)

        var transform = layer.transform
        if output.width != asset.image.width || output.height != asset.image.height {
            // Some filters (blur, vignette) grow the pixel buffer; keep the layer centered.
            let center = transform.center
            transform.size = CGSize(width: transform.size.width * CGFloat(output.width) / CGFloat(asset.image.width),
                                    height: transform.size.height * CGFloat(output.height) / CGFloat(asset.image.height))
            transform.origin = CGPoint(x: center.x - transform.size.width / 2, y: center.y - transform.size.height / 2)
        }
        session.beginEdit(kind.rawValue)
        session.document?.layers[index].transform = transform
        session.document?.layers[index].asset = ImportedImage(image: output, thumbnail: thumbnail, name: asset.name)
        // A text layer's cached raster is replaced, so it stops being live text.
        session.document?.layers[index].text = nil
        session.endEdit()

        let note = "Applied \(kind.rawValue)."
        if arguments.bool("preview") == true {
            guard let snapshot = session.projectSnapshot() else { throw MCPToolError.noProject }
            let raster = try await ImageExporter.shared.render(snapshot)
            return previewResult(raster.image, note: note, maxWidth: 1024)
        }
        return layerReply(session, id: layer.id, note: note)
    }

    private func adjustmentSet(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let session = try controller(arguments).session
        let (index, layer) = try layerAt(session, arguments)
        var adjustment = layer.adjustment ?? LayerAdjustment(kind: .hsv)
        if let kindText = arguments.string("kind") {
            guard let kind = AdjustmentKind(rawValue: kindText) else {
                throw MCPToolError.invalidArgument("Unknown adjustment '\(kindText)'. Valid: \(AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            adjustment.kind = kind
        }
        if let hue = arguments.double("hue") { adjustment.hue = min(180, max(-180, hue)) }
        if let saturation = arguments.double("saturation") { adjustment.saturation = min(100, max(-100, saturation)) }
        if let lightness = arguments.double("lightness") { adjustment.lightness = min(100, max(-100, lightness)) }
        if let colorize = arguments.bool("colorize") { adjustment.colorize = colorize }
        session.beginEdit("Adjustment")
        session.document?.layers[index].adjustment = adjustment
        session.endEdit()
        return layerReply(session, id: layer.id, note: "Adjustment set to \(adjustment.kind.rawValue).")
    }

    private func applySettings(_ settings: inout FilterSettings, _ dict: [String: MCP.Value]) throws {
        func number(_ key: String) throws -> Double {
            guard let value = dict.double(key) else { throw MCPToolError.invalidArgument("Setting '\(key)' must be a number.") }
            return value
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = dict.bool(key) else { throw MCPToolError.invalidArgument("Setting '\(key)' must be a boolean.") }
            return value
        }
        for key in dict.keys {
            switch key {
            case "radius": settings.radius = try number(key)
            case "angle": settings.angle = try number(key)
            case "distance": settings.distance = try number(key)
            case "amount": settings.amount = try number(key)
            case "gaussian": settings.gaussian = try flag(key)
            case "monochromatic": settings.monochromatic = try flag(key)
            case "vignette_amount": settings.vignetteAmount = try number(key)
            case "vignette_midpoint": settings.vignetteMidpoint = try number(key)
            case "vignette_roundness": settings.vignetteRoundness = try number(key)
            case "vignette_feather": settings.vignetteFeather = try number(key)
            case "vignette_highlights": settings.vignetteHighlights = try number(key)
            case "bloom_amount": settings.bloomAmount = try number(key)
            case "bloom_radius": settings.bloomRadius = try number(key)
            case "tonal_amount": settings.tonalAmount = try number(key)
            case "tonal_radius": settings.tonalRadius = try number(key)
            case "tonal_shadows": settings.tonalShadows = try number(key)
            case "tonal_midtones": settings.tonalMidtones = try number(key)
            case "tonal_highlights": settings.tonalHighlights = try number(key)
            case "distortion": settings.distortion = try number(key)
            case "refine_edges": settings.refineEdges = try number(key)
            case "matte_contrast": settings.matteContrast = try number(key)
            case "shift_edge": settings.shiftEdge = try number(key)
            default:
                throw MCPToolError.invalidArgument("Unknown filter setting '\(key)'.")
            }
        }
    }

    private func filterKind(_ text: String) throws -> FilterKind {
        if let kind = FilterKind(rawValue: text) { return kind }
        func squashed(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        }
        if let kind = FilterKind.allCases.first(where: { squashed($0.rawValue) == squashed(text) }) { return kind }
        throw MCPToolError.invalidArgument("Unknown filter '\(text)'. Valid: \(FilterKind.allCases.map(\.rawValue).joined(separator: ", ")).")
    }

    // MARK: - Canvas

    private func canvasCrop(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard let snapshot = session.projectSnapshot() else { throw MCPToolError.noProject }
        let x = try requiredInt(arguments, "x")
        let y = try requiredInt(arguments, "y")
        let width = try requiredInt(arguments, "width")
        let height = try requiredInt(arguments, "height")
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw MCPToolError.invalidArgument("Canvas dimensions must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        // Keeping the rect means the old content moves by (-x, -y) inside the new canvas.
        let options = CanvasSizeOptions(width: width, height: height, anchor: 0, fill: nil,
                                        contentOffset: CGPoint(x: -x, y: -y))
        let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
        session.applyDocumentSize(resized, actionName: "Crop")
        return textResult("Cropped to \(width)×\(height) at (\(x), \(y)).")
    }

    private func canvasResize(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let session = try controller(arguments).session
        guard let snapshot = session.projectSnapshot() else { throw MCPToolError.noProject }
        let width = try requiredInt(arguments, "width")
        let height = try requiredInt(arguments, "height")
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw MCPToolError.invalidArgument("Canvas dimensions must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        let anchor = arguments.int("anchor") ?? 4
        guard (0...8).contains(anchor) else {
            throw MCPToolError.invalidArgument("anchor must be 0–8 (row-major, top-left through bottom-right).")
        }
        var fill: CanvasExtensionColor? = nil
        if let hex = arguments.string("fill") {
            guard let color = MCPImages.color(hex) else {
                throw MCPToolError.invalidArgument("fill must be #RRGGBB.")
            }
            fill = CanvasExtensionColor(red: color.red, green: color.green, blue: color.blue)
        }
        let options = CanvasSizeOptions(width: width, height: height, anchor: anchor, fill: fill, contentOffset: nil)
        let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
        session.applyDocumentSize(resized, actionName: "Canvas Size")
        return textResult("Canvas resized to \(width)×\(height).")
    }

    // MARK: - Output

    private func preview(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let controller = try controller(arguments)
        guard let snapshot = controller.session.projectSnapshot() else { throw MCPToolError.noProject }
        let maxWidth = min(4096, max(16, arguments.int("max_width") ?? 1024))
        var image = try await ImageExporter.shared.render(snapshot).image
        if let text = arguments.string("layer_id"), let id = UUID(uuidString: text) {
            image = try layerImage(snapshot: snapshot, layerID: id, fallback: image)
        }
        return previewResult(image, note: nil, maxWidth: maxWidth)
    }

    private func export(_ arguments: [String: MCP.Value]) async throws -> CallTool.Result {
        let controller = try controller(arguments)
        guard let snapshot = controller.session.projectSnapshot() else { throw MCPToolError.noProject }
        let path = try requiredString(arguments, "path")
        var url = expanded(path)
        let format = (arguments.string("format") ?? url.pathExtension.lowercased()).lowercased()
        switch format {
        case "png", "jpeg", "jpg": break
        default: throw MCPToolError.invalidArgument("format must be png or jpeg.")
        }
        if url.pathExtension.isEmpty { url.appendPathExtension(format == "png" ? "png" : "jpg") }

        let raster = try await ImageExporter.shared.render(snapshot)
        let data: Data
        if format == "png" {
            data = try await ImageExporter.shared.pngData(snapshot)
        } else {
            let quality = min(1, max(0.1, arguments.double("quality") ?? 0.85))
            data = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(quality: quality)).data
        }
        try await ImageExporter.shared.write(data, to: url)
        return previewResult(raster.image, note: "Exported \(url.path).", maxWidth: 1024)
    }

    /// A single layer over a transparent canvas, for previews of one layer at a time.
    private func layerImage(snapshot: ProjectSnapshot, layerID: UUID, fallback: CGImage) throws -> CGImage {
        guard let layer = snapshot.manifest.layers.first(where: { $0.id == layerID }),
              let image = snapshot.images[layerID]?.image else {
            return fallback
        }
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.render
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let mask = snapshot.mask(for: layer).flatMap {
            $0.clipImage(placement: $0.placement, over: layer.transform, width: image.width, height: image.height)
        }
        LayerRenderer.draw(image, transform: layer.transform, center: layer.transform.center,
                           opacity: layer.effectiveOpacity(in: snapshot.manifest.layers), blendMode: layer.blendMode ?? .normal,
                           mask: mask, in: context)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    private func previewResult(_ image: CGImage, note: String?, maxWidth: Int) -> CallTool.Result {
        do {
            let content = try MCPImages.content(image, maxWidth: maxWidth)
            var contents: [Tool.Content] = []
            if let note { contents.append(.text(note, metadata: nil)) }
            contents.append(content)
            return CallTool.Result(content: contents, isError: false)
        } catch {
            return errorResult("The preview could not be encoded.", error: error)
        }
    }

    // MARK: - Small helpers

    private func parentID(_ session: EditorSession, _ arguments: [String: MCP.Value]) -> UUID? {
        guard let text = arguments.string("parent_id") else { return nil }
        guard let id = UUID(uuidString: text), session.document?.layers.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    private func uniqueName(_ document: CanvasDocument, base: String) -> String {
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func moveLayer(_ session: EditorSession, id: UUID, to index: Int) throws {
        guard let document = session.document,
              let current = document.layers.firstIndex(where: { $0.id == id }) else {
            throw MCPToolError.layerNotFound(id.uuidString)
        }
        let clamped = min(max(index, 0), document.layers.count - 1)
        guard clamped != current else { return }
        session.beginEdit("Reorder Layers")
        var layers = document.layers
        let layer = layers.remove(at: current)
        layers.insert(layer, at: clamped)
        session.document?.layers = layers
        session.endEdit()
    }

    /// A one-line confirmation plus the layer's current record, so agents can read ids back.
    private func layerReply(_ session: EditorSession, id: UUID, note: String) -> CallTool.Result {
        guard let document = session.document,
              let layer = document.layers.first(where: { $0.id == id }) else {
            return textResult(note)
        }
        return jsonResult(layerValue(layer), note: note)
    }

    // MARK: - JSON

    private func projectValue(_ controller: ProjectController) -> MCP.Value {
        guard let document = controller.session.document else {
            return .object(["id": .string(controller.session.document?.id.uuidString ?? "")])
        }
        let session = controller.session
        var value: [String: MCP.Value] = [
            "id": .string(document.id.uuidString),
            "width": .int(document.width),
            "height": .int(document.height),
            "resolution": .double(document.resolution),
            "modified": .bool(session.isModified),
            "layers": .array(document.layers.map(layerValue)),
        ]
        if let active = session.activeLayerID { value["active_layer_id"] = .string(active.uuidString) }
        if let path = session.projectURL?.path { value["path"] = .string(path) }
        return .object(value)
    }

    private func layerValue(_ layer: ImageLayer) -> MCP.Value {
        var value: [String: MCP.Value] = [
            "id": .string(layer.id.uuidString),
            "name": .string(layer.name),
            "is_group": .bool(layer.isGroup),
            "visible": .bool(layer.isVisible),
            "opacity": .double(layer.opacity),
            "blend_mode": .string(layer.blendMode.rawValue),
            "has_pixels": .bool(layer.asset != nil),
        ]
        if let parent = layer.parentID { value["parent_id"] = .string(parent.uuidString) }
        if let source = layer.maskSourceID { value["clip_source_id"] = .string(source.uuidString) }
        if layer.mask != nil {
            value["mask"] = .object([
                "enabled": .bool(layer.mask?.isEnabled ?? true),
                "linked": .bool(layer.mask?.isLinked ?? true),
            ])
        }
        if let adjustment = layer.adjustment {
            value["adjustment"] = .string(adjustment.kind.rawValue)
        }
        if let text = layer.text { value["text"] = .string(text.style.content) }
        value["transform"] = .object([
            "x": .double(Double(layer.transform.origin.x)),
            "y": .double(Double(layer.transform.origin.y)),
            "width": .double(Double(layer.transform.size.width)),
            "height": .double(Double(layer.transform.size.height)),
            "rotation": .double(Double(layer.transform.rotation)),
            "flip_x": .bool(layer.transform.flipX),
            "flip_y": .bool(layer.transform.flipY),
        ])
        return .object(value)
    }
}
