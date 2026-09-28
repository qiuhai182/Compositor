import AppKit
import Testing
import UniformTypeIdentifiers
import MCP
@testable import Compositor

/// The MCP tool handlers, driven headlessly exactly as an agent would: JSON arguments in,
/// results and saved packages checked out.
@MainActor
struct MCPToolHandlerTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorMCPTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func call(_ handlers: MCPToolHandlers, _ name: String, _ arguments: [String: MCP.Value] = [:]) async throws -> CallTool.Result {
        await handlers.handle(CallTool.Parameters(name: name, arguments: arguments))
    }

    /// Fails the test when the tool reported an error, and returns the structured JSON.
    private func value(_ result: CallTool.Result) throws -> [String: MCP.Value] {
        #expect(result.isError != true, texts(result).joined(separator: "\n"))
        return try #require(result.structuredContent?.objectValue)
    }

    /// Read back through JSON, so the test does not depend on the SDK's content enum shape.
    private func texts(_ result: CallTool.Result) -> [String] {
        guard let data = try? JSONEncoder().encode(result.content),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { $0["text"] as? String }
    }

    private func imageData(_ result: CallTool.Result) -> (base64: String, mimeType: String)? {
        guard let data = try? JSONEncoder().encode(result.content),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for item in items where (item["type"] as? String) == "image" {
            if let base64 = item["data"] as? String, let mime = item["mimeType"] as? String {
                return (base64, mime)
            }
        }
        return nil
    }

    private func project(_ handlers: MCPToolHandlers, width: Int = 64, height: Int = 48) async throws -> (String, ProjectController) {
        let result = try await call(handlers, "project_create", ["width": .int(width), "height": .int(height)])
        let id = try #require(try value(result)["id"]?.stringValue)
        let uuid = try #require(UUID(uuidString: id))
        return (id, try #require(handlers.registry.controller(for: uuid)))
    }

    /// An 8-bit grayscale PNG, usable as a layer mask.
    private func maskFixture(in root: URL) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        let image = try #require(context.makeImage())
        let url = root.appendingPathComponent("mask.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func createAddImageTransformSaveRoundTrip() async throws {
        let handlers = MCPToolHandlers()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, controller) = try await project(handlers)

        let image = try await call(handlers, "layer_add_image", [
            "project_id": .string(id), "file_path": .string(try ImageImportTests().fixture(.png).path), "x": .double(4), "y": .double(6),
        ])
        let layerID = try #require(try value(image)["id"]?.stringValue)

        let transformed = try await call(handlers, "layer_transform", [
            "project_id": .string(id), "layer_id": .string(layerID),
            "x": .double(8), "y": .double(9), "rotation": .double(15),
        ])
        let transform = try #require(try value(transformed)["transform"]?.objectValue)
        #expect(transform["x"]?.doubleValue == 8)
        #expect(transform["rotation"]?.doubleValue == 15)

        let saved = try await call(handlers, "project_save", ["project_id": .string(id), "path": .string(root.appendingPathComponent("Saved.comp").path)])
        #expect(saved.isError != true)
        // What the agent saved is a package the app can open, with the transform it set.
        let snapshot = try await ProjectStore.shared.load(from: root.appendingPathComponent("Saved.comp"))
        let record = try #require(snapshot.manifest.layers.first { $0.id.uuidString == layerID })
        #expect(record.transform.origin.x == 8 && record.transform.origin.y == 9)
        #expect(record.transform.rotation == 15)
        #expect(controller.session.history.canUndo)
    }

    @Test func filtersAdjustmentsAndUndo() async throws {
        let handlers = MCPToolHandlers()
        let (id, controller) = try await project(handlers)
        let image = try await call(handlers, "layer_add_image", [
            "project_id": .string(id), "file_path": .string(try ImageImportTests().fixture(.png).path),
        ])
        let layerID = try #require(try value(image)["id"]?.stringValue)
        let original = try #require(controller.session.document?.layers[0].asset?.image)

        let blurred = try await call(handlers, "filter_apply", [
            "project_id": .string(id), "layer_id": .string(layerID),
            "kind": .string("Gaussian Blur"), "settings": .object(["radius": .double(4)]),
        ])
        #expect(blurred.isError != true)
        let filtered = try #require(controller.session.document?.layers[0].asset?.image)
        #expect(filtered !== original)

        let adjusted = try await call(handlers, "adjustment_set", [
            "project_id": .string(id), "layer_id": .string(layerID), "hue": .double(30), "saturation": .double(-10),
        ])
        #expect(adjusted.isError != true)
        #expect(controller.session.document?.layers[0].adjustment?.kind == .hsv)
        #expect(controller.session.document?.layers[0].adjustment?.hue == 30)

        try await call(handlers, "project_undo", ["project_id": .string(id)])
        #expect(controller.session.document?.layers[0].adjustment == nil)
        try await call(handlers, "project_undo", ["project_id": .string(id)])
        #expect(controller.session.document?.layers[0].asset?.image === original)

        // Unknown filters and settings are rejected with a message, not a crash.
        let unknown = try await call(handlers, "filter_apply", [
            "project_id": .string(id), "layer_id": .string(layerID), "kind": .string("Unsharp Mask"),
        ])
        #expect(unknown.isError == true)
    }

    @Test func textAndMaskSurviveRoundTrip() async throws {
        let handlers = MCPToolHandlers()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, controller) = try await project(handlers)

        let text = try await call(handlers, "layer_add_text", [
            "project_id": .string(id), "content": .string("Hello MCP"), "x": .double(10), "y": .double(10),
            "font_size": .double(24), "color": .string("#3366CC"),
        ])
        let textLayerID = try #require(try value(text)["id"]?.stringValue)
        #expect(try value(text)["text"]?.stringValue == "Hello MCP")

        let masked = try await call(handlers, "layer_add_image", [
            "project_id": .string(id), "file_path": .string(try ImageImportTests().fixture(.jpeg).path),
        ])
        let maskedID = try #require(try value(masked)["id"]?.stringValue)
        let mask = try await call(handlers, "layer_set_mask", [
            "project_id": .string(id), "layer_id": .string(maskedID), "mask_image_path": .string(try maskFixture(in: root).path),
        ])
        #expect(mask.isError != true)

        let url = root.appendingPathComponent("TextAndMask.comp")
        try await call(handlers, "project_save", ["project_id": .string(id), "path": .string(url.path)])
        let snapshot = try await ProjectStore.shared.load(from: url)
        let textRecord = try #require(snapshot.manifest.layers.first { $0.id.uuidString == textLayerID })
        #expect(textRecord.text?.content == "Hello MCP")
        let maskRecord = try #require(snapshot.manifest.layers.first { $0.id.uuidString == maskedID })
        #expect(maskRecord.maskFile != nil)
        #expect(controller.session.document != nil)
    }

    @Test func previewExportAndClose() async throws {
        let handlers = MCPToolHandlers()
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (id, controller) = try await project(handlers)

        try await call(handlers, "layer_add_image", [
            "project_id": .string(id), "file_path": .string(try ImageImportTests().fixture(.png).path),
        ])
        let preview = try await call(handlers, "preview", ["project_id": .string(id), "max_width": .int(32)])
        let imageContent = try #require(imageData(preview))
        let data = try #require(Data(base64Encoded: imageContent.base64))
        #expect(imageContent.mimeType == "image/png")
        #expect(try #require(CGImageSourceCreateWithData(data as CFData, nil)) != nil)

        let url = root.appendingPathComponent("Flat.png")
        let exported = try await call(handlers, "export", ["project_id": .string(id), "path": .string(url.path)])
        #expect(exported.isError != true)
        #expect(try #require(CGImageSourceCreateWithURL(url as CFURL, nil)) != nil)

        try await call(handlers, "project_close", ["project_id": .string(id)])
        #expect(controller.session.document == nil)
        #expect(handlers.registry.ids.isEmpty)
    }

    @Test func unknownToolAndMissingProjectFailCleanly() async throws {
        let handlers = MCPToolHandlers()
        let unknown = try await call(handlers, "definitely_not_a_tool")
        #expect(unknown.isError == true)
        let missing = try await call(handlers, "project_info", ["project_id": .string(UUID().uuidString)])
        #expect(missing.isError == true)
    }
}
