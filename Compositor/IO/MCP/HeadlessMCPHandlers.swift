import Foundation
import MCP

/// The headless tool handlers: the same 22 tools as the app's `MCPToolHandlers`, editing through
/// Core's `HeadlessProject` instead of an `EditorSession`, so they run on every platform. See
/// docs/cross-platform.md for what stays macOS-only (JPEG export, non-PNG imports, adjustments
/// and effects applied at render time).
@MainActor
final class HeadlessMCPHandlers {
    /// The open projects, keyed by document id — the MCP `project_id` — in open order.
    private var projects: [UUID: HeadlessProject] = [:]
    private var order: [UUID] = []

    func handle(_ params: CallTool.Parameters) async -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        do {
            switch params.name {
            case "project_create": return try projectCreate(arguments)
            case "project_open": return try projectOpen(arguments)
            case "project_list": return try projectList(arguments)
            case "project_info": return try projectInfo(arguments)
            case "project_save": return try projectSave(arguments)
            case "project_close": return try projectClose(arguments)
            case "project_undo": return try projectUndo(arguments)
            case "layer_add_image": return try layerAddImage(arguments)
            case "layer_add_blank": return try layerAddBlank(arguments)
            case "layer_add_group": return try layerAddGroup(arguments)
            case "layer_update": return try layerUpdate(arguments)
            case "layer_move": return try layerMove(arguments)
            case "layer_delete": return try layerDelete(arguments)
            case "layer_transform": return try layerTransform(arguments)
            case "layer_set_mask": return try layerSetMask(arguments)
            case "layer_add_text": return try layerAddText(arguments)
            case "filter_apply": return try filterApply(arguments)
            case "adjustment_set": return try adjustmentSet(arguments)
            case "canvas_crop": return try canvasCrop(arguments)
            case "canvas_resize": return try canvasResize(arguments)
            case "preview": return try preview(arguments)
            case "export": return try export(arguments)
            default: throw MCPToolError.unknownTool(params.name)
            }
        } catch let error as MCPToolError {
            return errorResult(error.localizedDescription)
        } catch {
            return errorResult(error.localizedDescription)
        }
    }

    // MARK: - Shared lookups

    private func project(_ arguments: [String: MCP.Value]) throws -> HeadlessProject {
        let text = try requiredString(arguments, "project_id")
        guard let id = UUID(uuidString: text), let project = projects[id] else {
            throw MCPToolError.projectNotFound(text)
        }
        return project
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

    private func previewResult(_ pixels: PixelBuffer, note: String?, maxWidth: Int) -> CallTool.Result {
        do {
            let data = try PNGCodec.encode(pixels.downscaled(maxWidth: maxWidth))
            var contents: [Tool.Content] = []
            if let note { contents.append(.text(note, metadata: nil)) }
            contents.append(.image(data: data.base64EncodedString(), mimeType: "image/png", metadata: nil))
            return CallTool.Result(content: contents, isError: false)
        } catch {
            return errorResult("The preview could not be encoded.", error: error)
        }
    }

    // MARK: - Projects

    private func projectCreate(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let width = try requiredInt(arguments, "width")
        let height = try requiredInt(arguments, "height")
        let project = try HeadlessProject(width: width, height: height, resolution: arguments.double("resolution"))
        let id = project.manifest.documentID
        projects[id] = project
        order.append(id)
        return jsonResult(projectValue(id, project), note: "Created project \(id.uuidString).")
    }

    private func projectOpen(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let path = try requiredString(arguments, "path")
        let url = expanded(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPToolError.invalidArgument("No file at \(url.path).")
        }
        let project = try HeadlessProject.open(from: url)
        let id = project.manifest.documentID
        projects[id] = project
        order.append(id)
        return jsonResult(projectValue(id, project), note: "Opened \(url.lastPathComponent).")
    }

    private func projectList(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let list = order.compactMap { id -> MCP.Value? in
            guard let project = projects[id] else { return nil }
            var value: [String: MCP.Value] = [
                "id": .string(id.uuidString),
                "width": .int(project.manifest.width),
                "height": .int(project.manifest.height),
                "modified": .bool(project.modified),
            ]
            if let path = project.projectURL?.path { value["path"] = .string(path) }
            return .object(value)
        }
        return jsonResult(.object(["projects": .array(list)]))
    }

    private func projectInfo(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let id = try projectID(arguments)
        return try jsonResult(projectValue(id, project(arguments)))
    }

    private func projectSave(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let url: URL
        if let path = arguments.string("path") {
            var saved = expanded(path)
            if saved.pathExtension.isEmpty { saved.appendPathExtension("comp") }
            url = saved
        } else {
            guard let saved = project.projectURL else {
                throw MCPToolError.invalidArgument("This project has never been saved; pass a path.")
            }
            url = saved
        }
        do { try project.save(to: url) }
        catch { throw MCPToolError.invalidArgument("The project could not be saved: \(error.localizedDescription)") }
        let id = try projectID(arguments)
        return jsonResult(projectValue(id, project), note: "Saved.")
    }

    private func projectClose(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let id = try projectID(arguments)
        projects[id] = nil
        order.removeAll { $0 == id }
        return textResult("Project closed. Unsaved changes were discarded.")
    }

    private func projectUndo(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        if arguments.bool("redo") == true {
            guard project.undo(redo: true) else { return textResult("Nothing to redo.") }
            return textResult("Redone.")
        }
        guard project.undo() else { return textResult("Nothing to undo.") }
        return textResult("Undone.")
    }

    // MARK: - Layers

    private func layerAddImage(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let path = try requiredString(arguments, "file_path")
        let url = expanded(path)
        guard url.pathExtension.lowercased() == "png" else {
            throw MCPToolError.invalidArgument("Headless imports are PNG-only; JPEG, HEIC, TIFF, WebP, GIF, BMP, SVG and PSD need the Compositor app.")
        }
        guard let pngData = try? Data(contentsOf: url) else {
            throw MCPToolError.invalidArgument("The image at \(url.path) could not be read.")
        }
        let id = try project.addImage(pngData: pngData, name: arguments.string("name"),
            x: arguments.double("x"), y: arguments.double("y"),
            parentID: arguments.string("parent_id").flatMap(UUID.init(uuidString:)),
            index: arguments.int("index"))
        return layerReply(project, id: id, note: "Added image layer.")
    }

    private func layerAddBlank(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let id = try project.addBlank(name: arguments.string("name"), width: arguments.int("width"),
            height: arguments.int("height"), x: arguments.double("x"), y: arguments.double("y"),
            parentID: arguments.string("parent_id").flatMap(UUID.init(uuidString:)))
        return layerReply(project, id: id, note: "Added blank layer.")
    }

    private func layerAddGroup(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let id = try project.addGroup(name: arguments.string("name"),
            parentID: arguments.string("parent_id").flatMap(UUID.init(uuidString:)))
        return layerReply(project, id: id, note: "Added group.")
    }

    private func layerID(_ arguments: [String: MCP.Value]) throws -> UUID {
        let text = try requiredString(arguments, "layer_id")
        guard let id = UUID(uuidString: text) else { throw MCPToolError.layerNotFound(text) }
        return id
    }

    private func layerUpdate(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let id = try layerID(arguments)
        try project.update(id, name: arguments.string("name"), visible: arguments.bool("visible"),
            opacity: arguments.double("opacity"),
            blendMode: arguments.string("blend_mode").flatMap(LayerBlendMode.init(rawValue:)))
        return layerReply(project, id: id, note: "Layer updated.")
    }

    private func layerMove(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let id = try layerID(arguments)
        try project.move(id, parentID: arguments.string("parent_id").flatMap(UUID.init(uuidString:)),
            index: arguments.int("index"))
        return layerReply(project, id: id, note: "Layer moved.")
    }

    private func layerDelete(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let texts = arguments.strings("layer_ids") ?? []
        guard !texts.isEmpty else { throw MCPToolError.missingArgument("layer_ids") }
        let ids = texts.compactMap { UUID(uuidString: $0) }
        guard ids.count == texts.count, !ids.isEmpty else {
            throw MCPToolError.invalidArgument("layer_ids must be layer id strings.")
        }
        try project.delete(ids)
        return textResult("Deleted \(ids.count) layer\(ids.count == 1 ? "" : "s").")
    }

    private func layerTransform(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let id = try layerID(arguments)
        try project.transform(id, x: arguments.double("x"), y: arguments.double("y"),
            width: arguments.double("width"), height: arguments.double("height"),
            rotation: arguments.double("rotation"), flipX: arguments.bool("flip_x"), flipY: arguments.bool("flip_y"))
        return layerReply(project, id: id, note: "Layer transformed.")
    }

    private func layerSetMask(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let id = try layerID(arguments)
        var maskPngData: Data?
        if let path = arguments.string("mask_image_path") {
            guard let data = try? Data(contentsOf: expanded(path)) else {
                throw MCPToolError.invalidArgument("The mask image could not be read.")
            }
            maskPngData = data
        }
        try project.setMask(id, maskPngData: maskPngData,
            sourceLayerID: arguments.string("source_layer_id").flatMap(UUID.init(uuidString:)),
            enabled: arguments.bool("enabled"))
        return layerReply(project, id: id, note: "Layer mask set.")
    }

    private func layerAddText(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        var style = LayerTextStyle()
        style.content = try requiredString(arguments, "content")
        if let size = arguments.double("font_size") { style.fontSize = CGFloat(size) }
        if let font = arguments.string("font_name") { style.fontName = font }
        if let hex = arguments.string("color") {
            guard let color = MCPColor.parse(hex) else {
                throw MCPToolError.invalidArgument("color must be #RRGGBB.")
            }
            style.red = color.red
            style.green = color.green
            style.blue = color.blue
        }
        let id = try project.addText(style, x: arguments.double("x"), y: arguments.double("y"))
        return layerReply(project, id: id, note: "Added text layer.")
    }

    // MARK: - Filters and adjustments

    private func filterApply(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let filter = try filterKind(try requiredString(arguments, "kind"))
        var parameters = FilterParameters()
        if let dict = arguments.object("settings") {
            try applySettings(&parameters, dict)
        }
        let id = try layerID(arguments)
        try project.filterApply(id, filter: filter, parameters: parameters)
        let note = "Applied \(filter.rawValue)."
        if arguments.bool("preview") == true {
            return previewResult(try project.previewBuffer(maxWidth: 1024), note: note, maxWidth: 1024)
        }
        return layerReply(project, id: id, note: note)
    }

    private func applySettings(_ parameters: inout FilterParameters, _ dict: [String: MCP.Value]) throws {
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
            case "radius": parameters.radius = try number(key)
            case "angle": parameters.angle = try number(key)
            case "distance": parameters.distance = try number(key)
            case "amount": parameters.amount = try number(key)
            case "gaussian": parameters.gaussian = try flag(key)
            case "monochromatic": parameters.monochromatic = try flag(key)
            case "vignette_amount": parameters.vignetteAmount = try number(key)
            case "vignette_midpoint": parameters.vignetteMidpoint = try number(key)
            case "vignette_roundness": parameters.vignetteRoundness = try number(key)
            case "vignette_feather": parameters.vignetteFeather = try number(key)
            case "vignette_highlights": parameters.vignetteHighlights = try number(key)
            case "bloom_amount": parameters.bloomAmount = try number(key)
            case "bloom_radius": parameters.bloomRadius = try number(key)
            case "tonal_amount": parameters.tonalAmount = try number(key)
            case "tonal_radius": parameters.tonalRadius = try number(key)
            case "tonal_shadows": parameters.tonalShadows = try number(key)
            case "tonal_midtones": parameters.tonalMidtones = try number(key)
            case "tonal_highlights": parameters.tonalHighlights = try number(key)
            case "distortion": parameters.distortion = try number(key)
            default:
                throw MCPToolError.invalidArgument("Unknown filter setting '\(key)'.")
            }
        }
    }

    private func filterKind(_ text: String) throws -> PortableFilter {
        if let filter = PortableFilter(rawValue: text) { return filter }
        func squashed(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        }
        if let filter = PortableFilter.allCases.first(where: { squashed($0.rawValue) == squashed(text) }) { return filter }
        throw MCPToolError.invalidArgument("Unknown filter '\(text)'. Valid: \(PortableFilter.allCases.map(\.rawValue).joined(separator: ", ")).")
    }

    private func adjustmentSet(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let id = try layerID(arguments)
        if let kindText = arguments.string("kind"), AdjustmentKind(rawValue: kindText) == nil {
            throw MCPToolError.invalidArgument("Unknown adjustment '\(kindText)'. Valid: \(AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        try project.adjustmentSet(id, kind: arguments.string("kind").flatMap(AdjustmentKind.init(rawValue:)),
            hue: arguments.double("hue"), saturation: arguments.double("saturation"),
            lightness: arguments.double("lightness"), colorize: arguments.bool("colorize"))
        return layerReply(project, id: id, note: "Adjustment set.")
    }

    // MARK: - Canvas

    private func canvasCrop(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let x = try requiredInt(arguments, "x")
        let y = try requiredInt(arguments, "y")
        let width = try requiredInt(arguments, "width")
        let height = try requiredInt(arguments, "height")
        try project.canvasCrop(x: x, y: y, width: width, height: height)
        return textResult("Cropped to \(width)×\(height) at (\(x), \(y)).")
    }

    private func canvasResize(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let width = try requiredInt(arguments, "width")
        let height = try requiredInt(arguments, "height")
        var fill: (red: Double, green: Double, blue: Double)?
        if let hex = arguments.string("fill") {
            guard let color = MCPColor.parse(hex) else {
                throw MCPToolError.invalidArgument("fill must be #RRGGBB.")
            }
            fill = color
        }
        try project.canvasResize(width: width, height: height,
            anchor: arguments.int("anchor") ?? 4, fill: fill)
        return textResult("Canvas resized to \(width)×\(height).")
    }

    // MARK: - Output

    private func preview(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let maxWidth = min(4096, max(16, arguments.int("max_width") ?? 1024))
        if let text = arguments.string("layer_id"), let id = UUID(uuidString: text),
           project.images[id] != nil {
            return previewResult(try project.render(layerID: id), note: nil, maxWidth: maxWidth)
        }
        return previewResult(try project.render(), note: nil, maxWidth: maxWidth)
    }

    private func export(_ arguments: [String: MCP.Value]) throws -> CallTool.Result {
        let project = try project(arguments)
        let path = try requiredString(arguments, "path")
        var url = expanded(path)
        let format = (arguments.string("format") ?? url.pathExtension.lowercased()).lowercased()
        switch format {
        case "png": break
        case "jpeg", "jpg":
            throw MCPToolError.invalidArgument("JPEG export needs the macOS app; use png.")
        default: throw MCPToolError.invalidArgument("format must be png (jpeg needs the macOS app).")
        }
        if url.pathExtension.isEmpty { url.appendPathExtension("png") }
        try project.exportPNG(to: url)
        return previewResult(try project.previewBuffer(maxWidth: 1024), note: "Exported \(url.path).", maxWidth: 1024)
    }

    // MARK: - JSON

    private func projectID(_ arguments: [String: MCP.Value]) throws -> UUID {
        let text = try requiredString(arguments, "project_id")
        guard let id = UUID(uuidString: text), projects[id] != nil else {
            throw MCPToolError.projectNotFound(text)
        }
        return id
    }

    /// A one-line confirmation plus the layer's current record, so agents can read ids back.
    private func layerReply(_ project: HeadlessProject, id: UUID, note: String) -> CallTool.Result {
        guard let record = project.manifest.layers.first(where: { $0.id == id }) else {
            return textResult(note)
        }
        return jsonResult(layerValue(record, images: project.images), note: note)
    }

    private func projectValue(_ id: UUID, _ project: HeadlessProject) -> MCP.Value {
        var value: [String: MCP.Value] = [
            "id": .string(id.uuidString),
            "width": .int(project.manifest.width),
            "height": .int(project.manifest.height),
            "resolution": .double(project.manifest.resolution ?? 72),
            "modified": .bool(project.modified),
            "layers": .array(project.manifest.layers.map { layerValue($0, images: project.images) }),
        ]
        if let active = project.activeLayerID { value["active_layer_id"] = .string(active.uuidString) }
        if let path = project.projectURL?.path { value["path"] = .string(path) }
        return .object(value)
    }

    private func layerValue(_ record: ProjectLayerRecord, images: [UUID: PixelBuffer]) -> MCP.Value {
        var value: [String: MCP.Value] = [
            "id": .string(record.id.uuidString),
            "name": .string(record.name),
            "is_group": .bool(record.isGroup ?? false),
            "visible": .bool(record.isVisible),
            "opacity": .double(record.opacity ?? 1),
            "blend_mode": .string((record.blendMode ?? .normal).rawValue),
            "has_pixels": .bool(images[record.id] != nil),
        ]
        if let parent = record.parentID { value["parent_id"] = .string(parent.uuidString) }
        if let source = record.maskSourceID { value["clip_source_id"] = .string(source.uuidString) }
        if record.maskFile != nil {
            value["mask"] = .object([
                "enabled": .bool(record.maskEnabled ?? true),
                "linked": .bool(record.maskLinked ?? true),
            ])
        }
        if let adjustment = record.adjustment {
            value["adjustment"] = .string(adjustment.kind.rawValue)
        }
        if let text = record.text { value["text"] = .string(text.content) }
        value["transform"] = .object([
            "x": .double(Double(record.transform.origin.x)),
            "y": .double(Double(record.transform.origin.y)),
            "width": .double(Double(record.transform.size.width)),
            "height": .double(Double(record.transform.size.height)),
            "rotation": .double(Double(record.transform.rotation)),
            "flip_x": .bool(record.transform.flipX),
            "flip_y": .bool(record.transform.flipY),
        ])
        return .object(value)
    }
}
