import Foundation

/// Folder hierarchy derived from track relPaths.
final class FolderNode: Identifiable, Hashable {
    let path: String          // "" for root, else "A/B"
    let name: String
    private(set) var subfolders: [FolderNode] = []
    private(set) var tracks: [Track] = []
    private(set) var totalTracks = 0
    private var index: [String: FolderNode] = [:]

    var id: String { path }
    /// For SwiftUI OutlineGroup (nil = leaf).
    var children: [FolderNode]? { subfolders.isEmpty ? nil : subfolders }

    init(path: String, name: String) { self.path = path; self.name = name }

    static func == (a: FolderNode, b: FolderNode) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }

    static func build(_ tracks: [Track]) -> FolderNode {
        let root = FolderNode(path: "", name: "Music")
        for t in tracks {
            var node = root
            node.totalTracks += 1
            let comps = t.relPath.split(separator: "/").dropLast()
            for c in comps {
                let name = String(c)
                if let n = node.index[name] { node = n } else {
                    let n = FolderNode(path: node.path.isEmpty ? name : node.path + "/" + name, name: name)
                    node.index[name] = n
                    node.subfolders.append(n)
                    node = n
                }
                node.totalTracks += 1
            }
            node.tracks.append(t)
        }
        root.sortRecursively()
        return root
    }

    private func sortRecursively() {
        subfolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        tracks.sort {
            if ($0.discNumber ?? 0, $0.trackNumber ?? 0) != ($1.discNumber ?? 0, $1.trackNumber ?? 0) {
                return ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0)
            }
            return $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending
        }
        subfolders.forEach { $0.sortRecursively() }
    }

    func node(at path: String) -> FolderNode? {
        if path.isEmpty { return self }
        var node = self
        for c in path.split(separator: "/") {
            guard let n = node.index[String(c)] else { return nil }
            node = n
        }
        return node
    }

    /// Folders below this one whose path matches the query. Only the shallowest match per branch is
    /// returned ("jazz" gives "jazz" and "xiaomi/jazz", not every folder inside them).
    func searchFolders(_ query: SearchQuery, limit: Int = 300) -> [FolderNode] {
        guard !query.isEmpty else { return [] }
        var out: [FolderNode] = []
        func walk(_ n: FolderNode) {
            for c in n.subfolders where out.count < limit {
                if query.matches(c.path.searchFolded) { out.append(c) } else { walk(c) }
            }
        }
        walk(self)
        return out
    }

    /// All tracks in this folder and below, in folder order.
    var allTracks: [Track] { tracks + subfolders.flatMap(\.allTracks) }
}

/// A set of selected folder prefixes with tree-aware toggling (selecting a folder selects its subtree).
struct FolderSelection: Codable, Equatable {
    var paths: Set<String> = []

    func contains(relPath: String) -> Bool {
        paths.contains { $0.isEmpty || relPath == $0 || relPath.hasPrefix($0 + "/") }
    }

    func isSelected(_ folder: String) -> Bool { contains(relPath: folder) }

    func isPartiallySelected(_ node: FolderNode) -> Bool {
        !isSelected(node.path) && paths.contains { $0.hasPrefix(node.path.isEmpty ? "" : node.path + "/") }
    }

    mutating func toggle(_ node: FolderNode, root: FolderNode) { toggle(path: node.path, root: root) }

    /// Toggle a folder or a single song (`path` is a folder path or a track relPath).
    mutating func toggle(path: String, root: FolderNode) {
        guard isSelected(path) else {
            paths = paths.filter { !$0.hasPrefix(path + "/") }
            paths.insert(path)
            return
        }
        if paths.contains(path) { paths.remove(path); return }
        // An ancestor is selected: replace it with everything under it except `path`.
        guard let ancestor = paths.filter({ $0.isEmpty || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }),
              var cur = root.node(at: ancestor) else { return }
        paths.remove(ancestor)
        let comps = path.split(separator: "/").map(String.init)
        let skip = ancestor.isEmpty ? 0 : ancestor.split(separator: "/").count
        for (i, c) in comps.enumerated() where i >= skip {
            // siblings of the branch we're carving out, folders and loose files alike
            for s in cur.subfolders where s.name != c { paths.insert(s.path) }
            for t in cur.tracks where t.relPath != path { paths.insert(t.relPath) }
            guard i < comps.count - 1, let next = cur.subfolders.first(where: { $0.name == c }) else { break }
            cur = next
        }
    }
}
