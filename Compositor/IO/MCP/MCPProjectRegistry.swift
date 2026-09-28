import Foundation

/// The headless workspace: the open projects, each an `EditorSession` + `ProjectController` pair
/// exactly as the tests drive them. Keyed by document id, which becomes the MCP `project_id`.
@MainActor
final class MCPProjectRegistry {
    private var controllers: [UUID: ProjectController] = [:]
    private var order: [UUID] = []

    var ids: [UUID] { order }

    func controller(for id: UUID) -> ProjectController? { controllers[id] }

    /// Creates a new project and returns its id.
    func create(width: Int, height: Int, resolution: Double?) throws -> UUID {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw MCPToolError.invalidArgument("Canvas dimensions must be 1–\(DocumentLimits.maxSide) pixels.")
        }
        let session = EditorSession()
        session.createNewProject(width: width, height: height)
        guard let document = session.document else { throw MCPToolError.invalidArgument("The canvas dimensions were rejected.") }
        if let resolution { session.document?.resolution = max(1, resolution) }
        return register(session: session)
    }

    /// Opens a .comp package from disk and returns its id.
    func open(url: URL) async throws -> UUID {
        let session = EditorSession()
        let controller = ProjectController(session: session)
        controller.suppressDialogs = true
        guard await controller.open(url) else {
            throw MCPToolError.openFailed(url.path)
        }
        guard let document = session.document else { throw MCPToolError.openFailed(url.path) }
        return register(session: session, controller: controller, documentID: document.id)
    }

    func close(_ id: UUID) async {
        guard let controller = controllers[id] else { return }
        await controller.closeDiscardingChanges()
        controllers[id] = nil
        order.removeAll { $0 == id }
    }

    private func register(session: EditorSession, controller: ProjectController? = nil, documentID: UUID? = nil) -> UUID {
        let controller = controller ?? ProjectController(session: session)
        controller.suppressDialogs = true
        let id = documentID ?? session.document!.id
        controllers[id] = controller
        order.append(id)
        return id
    }
}
