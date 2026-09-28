import Foundation
import MCP

/// Builds the headless MCP server: the same tool catalog as the app's `CompositorMCPServer`, with
/// the portable filter list and the headless downgrades called out, routing into
/// `HeadlessMCPHandlers`.
@MainActor
enum HeadlessMCPServer {
    static func make(handlers: HeadlessMCPHandlers) async -> Server {
        let server = Server(
            name: "compositor",
            version: "1.0.0",
            instructions: """
            Edits Compositor (.comp) image projects headlessly. Call project_create or project_open \
            first; every other tool takes the project_id it returns. project_info lists layers \
            bottom-to-top with their ids. Pass preview:true on filter_apply, or call preview/export, \
            to see the result. This server renders and exports PNG without the macOS app; color \
            adjustments and layer effects are saved but not applied to headless renders.
            """,
            capabilities: .init(tools: .init()))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: catalog)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await handlers.handle(params)
        }
        return server
    }

    // MARK: - Catalog

    nonisolated private static let projectID = param("string", "The project_id from project_create, project_open or project_list.")
    nonisolated private static let layerID = param("string", "The layer id from project_info.")

    nonisolated private static let catalog: [Tool] = [
        Tool(name: "project_create", description: "Creates a new empty project with one blank layer.",
             inputSchema: objectSchema([
                 "name": param("string", "A label for the project in the reply."),
                 "width": param("integer", "Canvas width in pixels (1–30000)."),
                 "height": param("integer", "Canvas height in pixels (1–30000)."),
                 "resolution": param("number", "DPI, default 72."),
             ], required: ["width", "height"])),
        Tool(name: "project_open", description: "Opens a .comp project from disk.",
             inputSchema: objectSchema([
                 "path": param("string", "Path to the .comp package."),
             ], required: ["path"])),
        Tool(name: "project_list", description: "Lists the open projects with their ids.",
             inputSchema: objectSchema([:])),
        Tool(name: "project_info", description: "Full state of one project: canvas, layers bottom-to-top, ids, transforms, masks, text.",
             inputSchema: objectSchema([
                 "project_id": projectID,
             ], required: ["project_id"])),
        Tool(name: "project_save", description: "Saves the project. Pass a path the first time; afterwards it saves in place.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "path": param("string", "Where to save a project that has no file yet, as .comp."),
             ], required: ["project_id"])),
        Tool(name: "project_close", description: "Closes the project, discarding unsaved changes.",
             inputSchema: objectSchema([
                 "project_id": projectID,
             ], required: ["project_id"])),
        Tool(name: "project_undo", description: "Undoes (or with redo:true, redoes) the last edit.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "redo": param("boolean", "Redo instead of undo."),
             ], required: ["project_id"])),
        Tool(name: "layer_add_image", description: "Imports a PNG file as a new layer (headless is PNG-only; other formats need the app).",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "file_path": param("string", "Path to a PNG file."),
                 "x": param("number", "Top-left x in document pixels; default centered."),
                 "y": param("number", "Top-left y in document pixels; default centered."),
                 "index": param("integer", "Position in the bottom-to-top stack."),
                 "name": param("string", "A name for the layer."),
             ], required: ["project_id", "file_path"])),
        Tool(name: "layer_add_blank", description: "Adds a transparent blank layer.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "name": param("string", "A name; default 'Layer N'."),
                 "width": param("integer", "Layer size; default the canvas."),
                 "height": param("integer", "Layer size; default the canvas."),
                 "x": param("number", "Top-left x; default 0."),
                 "y": param("number", "Top-left y; default 0."),
                 "parent_id": param("string", "A group layer to nest inside."),
             ], required: ["project_id"])),
        Tool(name: "layer_add_group", description: "Adds an empty group (folder) layer.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "name": param("string", "A name; default 'Group N'."),
                 "parent_id": param("string", "A group layer to nest inside."),
             ], required: ["project_id"])),
        Tool(name: "layer_update", description: "Renames a layer or changes visibility, opacity or blend mode.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_id": layerID,
                 "name": param("string", "New name."),
                 "visible": param("boolean", "Show or hide the layer."),
                 "opacity": param("number", "0–1."),
                 "blend_mode": paramEnum(LayerBlendMode.allCases.map(\.rawValue), "Photoshop-style blend modes."),
             ], required: ["project_id", "layer_id"])),
        Tool(name: "layer_move", description: "Moves a layer in the stack (bottom-to-top index) or into/out of a group.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_id": layerID,
                 "index": param("integer", "Final position in the bottom-to-top stack."),
                 "parent_id": param("string", "New group parent."),
             ], required: ["project_id", "layer_id"])),
        Tool(name: "layer_delete", description: "Deletes layers; a group takes its contents with it.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_ids": param("array", "Layer ids to delete."),
             ], required: ["project_id", "layer_ids"])),
        Tool(name: "layer_transform", description: "Sets a layer's position, size, rotation (degrees clockwise) or flips.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_id": layerID,
                 "x": param("number", "Top-left x in document pixels."),
                 "y": param("number", "Top-left y in document pixels."),
                 "width": param("number", "Placed width in document pixels."),
                 "height": param("number", "Placed height in document pixels."),
                 "rotation": param("number", "Degrees, clockwise."),
                 "flip_x": param("boolean", "Mirror horizontally."),
                 "flip_y": param("boolean", "Mirror vertically."),
             ], required: ["project_id", "layer_id"])),
        Tool(name: "layer_set_mask", description: "Adds a raster mask from a PNG file (any color setup; converted to grayscale coverage, white reveals), sets a clipping-mask source layer, or toggles the mask.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_id": layerID,
                 "mask_image_path": param("string", "Path to a mask image (PNG)."),
                 "source_layer_id": param("string", "Layer whose alpha clips this layer (clipping mask)."),
                 "enabled": param("boolean", "Enable or disable an existing mask."),
             ], required: ["project_id", "layer_id"])),
        Tool(name: "layer_add_text", description: "Renders text into a new text layer.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "content": param("string", "The text."),
                 "x": param("number", "Top-left x; default 0."),
                 "y": param("number", "Top-left y; default 0."),
                 "font_name": param("string", "A font name, matched against the system's fonts; default Helvetica."),
                 "font_size": param("number", "Default 72."),
                 "color": param("string", "#RRGGBB; default black."),
             ], required: ["project_id", "content"])),
        Tool(name: "filter_apply", description: "Runs a filter on a layer's pixels as one undo step.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_id": layerID,
                 "kind": paramEnum(PortableFilter.allCases.map(\.rawValue), "The filter to run."),
                 "settings": param("object", "Per-filter settings: radius, angle, distance, amount, gaussian, monochromatic, vignette_amount, vignette_midpoint, vignette_roundness, vignette_feather, vignette_highlights, bloom_amount, bloom_radius, tonal_amount, tonal_radius, tonal_shadows, tonal_midtones, tonal_highlights, distortion. Omitted values keep their defaults."),
                 "preview": param("boolean", "Also return the composite as an image."),
             ], required: ["project_id", "layer_id", "kind"])),
        Tool(name: "adjustment_set", description: "Sets a layer's color adjustment (saved with the project; applied when the macOS app renders).",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_id": layerID,
                 "kind": paramEnum(AdjustmentKind.allCases.map(\.rawValue), "Default Hue/Saturation."),
                 "hue": param("number", "−180–180 degrees."),
                 "saturation": param("number", "−100–100."),
                 "lightness": param("number", "−100–100."),
                 "colorize": param("boolean", "Hue/Saturation colorize mode."),
             ], required: ["project_id", "layer_id"])),
        Tool(name: "canvas_crop", description: "Crops the canvas to a rectangle, moving the content with it.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "x": param("integer", "Left edge of the kept rectangle."),
                 "y": param("integer", "Top edge of the kept rectangle."),
                 "width": param("integer", "New canvas width."),
                 "height": param("integer", "New canvas height."),
             ], required: ["project_id", "x", "y", "width", "height"])),
        Tool(name: "canvas_resize", description: "Grows or shrinks the canvas without scaling the layers.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "width": param("integer", "New canvas width."),
                 "height": param("integer", "New canvas height."),
                 "anchor": param("integer", "0–8, row-major from top-left where the old canvas sits; default 4 (center)."),
                 "fill": param("string", "#RRGGBB for an extension layer behind the content."),
             ], required: ["project_id", "width", "height"])),
        Tool(name: "preview", description: "Renders the composite (or one layer) and returns it as an image.",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "layer_id": param("string", "Render just this layer."),
                 "max_width": param("integer", "Downscale limit; default 1024."),
             ], required: ["project_id"])),
        Tool(name: "export", description: "Exports the flattened composite to a PNG file and returns a preview image (JPEG export needs the macOS app).",
             inputSchema: objectSchema([
                 "project_id": projectID,
                 "path": param("string", "Where to write the file."),
                 "format": paramEnum(["png"], "Default from the path extension, else png."),
             ], required: ["project_id", "path"])),
    ]
}
