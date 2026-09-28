import Foundation
import MCP

// The tool layer's shared vocabulary: argument access, schema building, result constructors and
// the error enum. This file is compiled both by the app's MCP server and by the cross-platform
// MCPBridge target, so it stays free of Apple frameworks — see docs/cross-platform.md.

// MARK: - Argument access

/// Tool arguments arrive as `[String: Value]`; these keep the handlers readable.
nonisolated extension Dictionary where Key == String, Value == MCP.Value {
    func arg(_ key: String) -> MCP.Value? { self[key] }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? {
        guard let value = self[key] else { return nil }
        return value.intValue ?? value.doubleValue.map { Int($0) }
    }
    func double(_ key: String) -> Double? {
        guard let value = self[key] else { return nil }
        return value.doubleValue ?? value.intValue.map(Double.init)
    }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func object(_ key: String) -> [String: MCP.Value]? { self[key]?.objectValue }
    func strings(_ key: String) -> [String]? { self[key]?.arrayValue?.map { $0.stringValue ?? "" } }
}

// MARK: - Tool schema building

nonisolated func param(_ type: String, _ description: String) -> MCP.Value {
    .object(["type": .string(type), "description": .string(description)])
}

nonisolated func paramEnum(_ values: [String], _ description: String) -> MCP.Value {
    .object(["type": .string("string"), "description": .string(description), "enum": .array(values.map { .string($0) })])
}

nonisolated func objectSchema(_ properties: [String: MCP.Value], required: [String] = []) -> MCP.Value {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
    ])
}

// MARK: - Results

nonisolated func textResult(_ text: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text, metadata: nil)], isError: false)
}

nonisolated func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(message, metadata: nil)], isError: true)
}

nonisolated func errorResult(_ message: String, error: Error) -> CallTool.Result {
    errorResult("\(message): \(error.localizedDescription)")
}

// MARK: - Colors

/// "#RRGGBB" or "RRGGBB" into 0–1 components.
nonisolated enum MCPColor {
    static func parse(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

// MARK: - Errors

nonisolated enum MCPToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String)
    case noProject
    case projectNotFound(String)
    case openFailed(String)
    case saveFailed
    case layerNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .missingArgument(let name): "Missing required argument: \(name)"
        case .invalidArgument(let detail): detail
        case .noProject: "The project has no open document."
        case .projectNotFound(let id): "No open project with id \(id). Call project_list for the open projects."
        case .openFailed(let path): "The project at \(path) could not be opened."
        case .saveFailed: "The project could not be saved."
        case .layerNotFound(let id): "No layer with id \(id). Call project_info for the layer ids."
        }
    }
}
