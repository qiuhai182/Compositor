import Foundation

// The layer stack's shape, as the manifest records it: flattening the tree (with each layer's
// effective visibility), folder opacity, and the validity rules both saving and loading enforce.
// The app's ImageLayer extensions in LayerGroups.swift build on these.

nonisolated enum LayerHierarchy {
    struct Entry {
        let layer: ProjectLayerRecord
        let depth: Int
        let visible: Bool
    }
    static func entries(_ layers: [ProjectLayerRecord], topFirst: Bool = false,
                        collapsed: Set<UUID> = []) -> [Entry] {
        let children = Dictionary(grouping: layers, by: \.parentID)
        var result: [Entry] = []
        func visit(_ parent: UUID?, depth: Int, visible: Bool) {
            guard depth <= 64 else { return }
            let siblings = children[parent] ?? []
            for layer in topFirst ? Array(siblings.reversed()) : siblings {
                let effective = visible && layer.isVisible
                result.append(Entry(layer: layer, depth: depth, visible: effective))
                if layer.isGroup == true, !collapsed.contains(layer.id) {
                    visit(layer.id, depth: depth + 1, visible: effective)
                }
            }
        }
        visit(nil, depth: 0, visible: true)
        return result
    }
    static func visibleLayers(_ layers: [ProjectLayerRecord]) -> [ProjectLayerRecord] {
        entries(layers).filter { $0.visible && $0.layer.isGroup != true }.map(\.layer)
    }
    static func validate(_ layers: [ProjectLayerRecord]) throws {
        var byID: [UUID: ProjectLayerRecord] = [:]
        for layer in layers {
            guard byID.updateValue(layer, forKey: layer.id) == nil,
                  layer.isGroup != true || layer.imageFile == nil else { throw ProjectError.invalid }
        }
        for layer in layers {
            var seen: Set<UUID> = [layer.id]
            var parent = layer.parentID
            while let id = parent {
                guard seen.count <= 64, seen.insert(id).inserted,
                      let node = byID[id], node.isGroup == true else { throw ProjectError.invalid }
                parent = node.parentID
            }
            if layer.isGroup == true, seen.count > 64 { throw ProjectError.invalid }
        }
    }
}

/// A folder's opacity multiplies into everything inside it: a layer at 50% in a folder at 50%
/// shows at 25%, while the layer itself still reads 50% in the panel. Folders are pass-through —
/// what's inside is drawn straight onto what is below, never composited as a unit — so the
/// folder's opacity is applied to each of those layers rather than to the folder as a whole.
nonisolated enum LayerOpacity {
    static func effective(_ own: Double, parent: UUID?,
                          folder: (UUID) -> (opacity: Double, parentID: UUID?)?) -> Double {
        var opacity = own, id = parent, depth = 0
        while let current = id, depth < 64, let node = folder(current) {
            opacity *= node.opacity
            id = node.parentID
            depth += 1
        }
        return opacity
    }
}

// The package's load and save errors, shared by the app's ProjectStore and the headless engine.
nonisolated enum ProjectError: LocalizedError {
    case invalid, version(Int), missingImage, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Compositor project, or its metadata is damaged."
        case .version(let version): "This project uses format version \(version). This app supports versions \(ProjectManifest.supported.lowerBound)–\(ProjectManifest.supported.upperBound)."
        case .missingImage: "An image inside the project is missing or damaged. The current document has not been replaced."
        case .tooLarge: "This project exceeds the supported canvas, layer, file-size, or \(DocumentLimits.documentBudgetMegapixels)-megapixel document limit."
        case .encode: "An image could not be saved. The previous project has not been replaced."
        }
    }
}
