import Foundation

// LayerHierarchy, LayerOpacity and ProjectError live in Core (Core/Project/LayerHierarchy.swift);
// the extensions below adapt them to the app's ImageLayer and EditorSession.

extension ImageLayer {
    /// The opacity this layer is drawn at, folders included (see LayerOpacity).
    func effectiveOpacity(in byID: [UUID: ImageLayer]) -> Double {
        LayerOpacity.effective(opacity, parent: parentID) { byID[$0].map { ($0.opacity, $0.parentID) } }
    }
    var hierarchyRecord: ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: isVisible, transform: transform,
            imageFile: asset == nil ? nil : "\(id.uuidString).png", parentID: parentID, isGroup: isGroup, opacity: opacity, blendMode: blendMode, maskFile: mask == nil ? nil : "\(id.uuidString).mask.png", maskEnabled: mask?.isEnabled, maskSourceID: maskSourceID, adjustment: adjustment, maskPlacement: mask?.placement, maskLinked: mask?.isLinked)
    }
}
nonisolated extension ProjectLayerRecord {
    /// The opacity this layer is drawn at, folders included (see LayerOpacity).
    func effectiveOpacity(in byID: [UUID: ProjectLayerRecord]) -> Double {
        LayerOpacity.effective(opacity ?? 1, parent: parentID) { byID[$0].map { ($0.opacity ?? 1, $0.parentID) } }
    }
}
extension CanvasDocument {
    var effectiveOpacities: [UUID: Double] {
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0.effectiveOpacity(in: byID)) })
    }
    var hierarchyEntries: [LayerHierarchy.Entry] { LayerHierarchy.entries(layers.map(\.hierarchyRecord)) }
    var effectiveVisibleIDs: Set<UUID> { Set(hierarchyEntries.filter(\.visible).map { $0.layer.id }) }
    var renderLayers: [ImageLayer] {
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        return hierarchyEntries.filter { $0.visible && $0.layer.isGroup != true }.compactMap { byID[$0.layer.id] }
    }
}

extension EditorSession {
    func selectLayers(_ ids: Set<UUID>, primary: UUID?) {
        effectSelection = nil
        if ids != selectedLayerIDs, !finishText() { return }
        guard brushStroke == nil else { return }
        let valid = ids.intersection(Set(document?.layers.map(\.id) ?? []))
        if valid != selectedLayerIDs { commitTransform(); resolveGradient() }
        activeLayerID = primary.flatMap { valid.contains($0) ? $0 : nil } ?? valid.first
        selectedLayerIDs = valid
    }

    /// Cmd-Shift-click on the canvas: adds a layer to the selection, or takes it out again when it is already in it.
    func extendSelection(with id: UUID) {
        guard canEditLayers || transformEdit != nil, document?.layers.contains(where: { $0.id == id }) == true else { return }
        var ids = selectedLayerIDs
        if ids.contains(id), ids.count > 1 {
            ids.remove(id)
            selectLayers(ids, primary: activeLayerID == id ? ids.first : activeLayerID)
        } else {
            ids.insert(id)
            selectLayers(ids, primary: id)
        }
    }

    func groupSelectedLayers() {
        guard canEditLayers, let document, document.layers.count < 10_000 else { return }
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        let selected = selectedLayerIDs.intersection(Set(byID.keys))
        func ancestors(_ id: UUID) -> [UUID?] {
            var result: [UUID?] = []
            var parent = byID[id]?.parentID
            while let id = parent { result.append(id); parent = byID[id]?.parentID }
            result.append(nil)
            return result
        }
        // A selected folder carries its subtree; selected descendants must not be pulled out of it.
        let rootIDs = selected.filter { id in !ancestors(id).contains { $0.map(selected.contains) ?? false } }
        let ordered = document.hierarchyEntries.map { $0.layer.id }.filter(rootIDs.contains)
        let parent: UUID? = ordered.first.flatMap { first in
            ancestors(first).first { candidate in ordered.allSatisfy { ancestors($0).contains(candidate) } } ?? nil
        }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Folder \(number)") { number += 1 }
        var group = ImageLayer(name: "Folder \(number)", blankSize: document.size)
        group.isGroup = true
        group.parentID = parent
        // Put the wrapper at the topmost selected branch in the common parent.
        let branches = ordered.map { id -> UUID in
            var branch = id
            while let next = byID[branch]?.parentID, next != parent { branch = next }
            return branch
        }
        let highest = document.layers.lastIndex { branches.contains($0.id) }
        let insertion = highest.map { document.layers.prefix($0 + 1).filter { !rootIDs.contains($0.id) }.count }
            ?? document.layers.count
        var layers = document.layers.filter { !rootIDs.contains($0.id) }
        layers.insert(group, at: min(insertion, layers.count))
        for id in ordered {
            guard var child = byID[id] else { continue }
            child.parentID = group.id
            layers.append(child)
        }
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
        beginEdit("Group Layers")
        self.document?.layers = layers
        activeLayerID = group.id
        if let parent { collapsedGroupIDs.remove(parent) }
        endEdit()
    }

    var layerRows: [LayerHierarchy.Entry] {
        LayerHierarchy.entries(document?.layers.map(\.hierarchyRecord) ?? [], topFirst: true, collapsed: collapsedGroupIDs)
    }
    func descendantIDs(of id: UUID) -> Set<UUID> {
        let children = Dictionary(grouping: document?.layers ?? [], by: \.parentID)
        var result = Set<UUID>(), pending = [id]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }
    func addGroup() {
        guard canEditLayers, let document, document.layers.count < 10_000 else { return }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Folder \(number)") { number += 1 }
        var group = ImageLayer(name: "Folder \(number)", blankSize: document.size)
        group.isGroup = true
        group.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        var layers = document.layers
        let insertion = layers.firstIndex(where: { $0.id == activeLayerID }).map { $0 + 1 } ?? layers.count
        layers.insert(group, at: insertion)
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
        beginEdit("New Folder")
        self.document?.layers = layers
        activeLayerID = group.id
        if let parent = group.parentID { collapsedGroupIDs.remove(parent) }
        endEdit()
    }
    func toggleGroupExpansion(_ id: UUID) {
        guard !isProjectBusy, document?.layers.first(where: { $0.id == id })?.isGroup == true else { return }
        if collapsedGroupIDs.contains(id) { collapsedGroupIDs.remove(id) }
        else {
            if activeLayerID.map({ descendantIDs(of: id).contains($0) }) == true { selectLayer(id) }
            collapsedGroupIDs.insert(id)
        }
    }
    func canPlaceLayer(_ id: UUID, in parent: UUID?) -> Bool {
        guard canEditLayers, document?.layers.contains(where: { $0.id == id }) == true else { return false }
        guard let parent else { return true }
        return parent != id && !descendantIDs(of: id).contains(parent)
            && document?.layers.first(where: { $0.id == parent })?.isGroup == true
    }
    @discardableResult
    func placeLayer(_ id: UUID, in parent: UUID?, above target: UUID? = nil, atBottom: Bool = false) -> Bool {
        guard canPlaceLayer(id, in: parent), var layers = document?.layers,
              let index = layers.firstIndex(where: { $0.id == id }), target != id else { return false }
        var layer = layers.remove(at: index)
        layer.parentID = parent
        var insertion = atBottom ? 0 : layers.count
        if let target {
            guard let targetIndex = layers.firstIndex(where: { $0.id == target && $0.parentID == parent }) else { return false }
            insertion = targetIndex + 1
        }
        layers.insert(layer, at: insertion)
        Self.adoptClipping(id, in: &layers)
        Self.releaseDetachedClipping(in: &layers)
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return false }
        beginEdit("Move Layer")
        document?.layers = layers
        activeLayerID = id
        if let parent { collapsedGroupIDs.remove(parent) }
        endEdit()
        return true
    }
    func moveActiveLayerOutOfGroup() {
        guard let layer = activeLayer, let parent = layer.parentID,
              let group = document?.layers.first(where: { $0.id == parent }) else { return }
        placeLayer(layer.id, in: group.parentID, above: group.id)
    }
}
