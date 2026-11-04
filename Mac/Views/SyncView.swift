import SwiftUI

struct SyncView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        let root = store.folderRoot
        let synced = model.syncedTracks
        let favCount = store.tracks.filter(\.favorite).count
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Folders synced to iOS").font(.headline)
                Text("\(synced.count) of \(store.tracks.count) tracks · \(ByteCountFormatter.string(fromByteCount: synced.reduce(0) { $0 + $1.size }, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Select All") { model.selection = FolderSelection(paths: [""]) }
                    Button("Select None") { model.selection = FolderSelection() }
                }
                Toggle(isOn: $model.syncFavorites) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Also sync all favorites", systemImage: "heart.fill")
                        Text("\(favCount) favorites on this Mac, plus songs favorited on any iPhone, from any folder")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                List {
                    OutlineGroup(root.subfolders, children: \.children) { node in
                        FolderCheckRow(node: node, root: root)
                    }
                    let loose = root.tracks.count
                    if loose > 0 { Text("\(loose) loose files in root are synced only with Select All").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding()
            .frame(minWidth: 340)

            Form {
                Section("Server") {
                    LabeledContent("Status", value: model.serverStatus)
                    LabeledContent("Bonjour name", value: model.serverName)
                    LabeledContent("Addresses", value: Self.localAddresses().map { "\($0):\(model.server.port)" }.joined(separator: "\n"))
                    Button("Restart Server") { model.startServer() }
                }
                Section {
                    if model.online.isEmpty {
                        Text("No iPhone has MyMusic open right now.").foregroundStyle(.secondary)
                    }
                    ForEach(model.online, id: \.id) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text(d.name)
                                Spacer()
                                if model.syncRequested.contains(d.id) {
                                    ProgressView().controlSize(.small); Text("Waiting for iPhone…").foregroundStyle(.secondary)
                                } else if model.syncProgress[d.id]?.isActive != true {
                                    Button("Sync Now") { model.requestSync(d.id) }
                                }
                            }
                            if let p = model.syncProgress[d.id] { SyncProgressView(progress: p) }
                        }
                    }
                    if model.online.count > 1 {
                        Button("Sync All") { model.online.forEach { model.requestSync($0.id) } }
                    }
                } header: { Text("iPhones online") } footer: {
                    Text("An iPhone shows up here while the MyMusic app is open (or playing in the background).")
                }
                Section("Devices (stats backups)") {
                    if model.devices.isEmpty { Text("No device has synced yet.").foregroundStyle(.secondary) }
                    ForEach(model.devices) { d in
                        LabeledContent(d.deviceName, value: "\(d.entryCount) entries · \(Date(timeIntervalSince1970: d.lastSync).formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320)
        }
        .navigationTitle("Sync & Devices")
    }

    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

struct SyncProgressView: View {
    let progress: SyncProgress

    var body: some View {
        let p = progress
        VStack(alignment: .leading, spacing: 3) {
            if p.isActive {
                if p.phase == .starting || p.total == 0 {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: p.fraction)
                }
                Text(p.phase == .downloading && p.total > 0
                     ? "\(p.done)/\(p.total) songs · \(ByteCountFormatter.string(fromByteCount: p.bytesDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: p.bytesTotal, countStyle: .file)) · \(p.message)"
                     : p.message)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                let ok = p.phase == .done
                Label(p.phase == .downloading || p.phase == .starting ? "Sync stopped responding" : p.message,
                      systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(ok ? .green : .orange)
                Text(Date(timeIntervalSince1970: p.updatedAt).formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct FolderCheckRow: View {
    @EnvironmentObject var model: AppModel
    let node: FolderNode
    let root: FolderNode

    var body: some View {
        let selected = model.selection.isSelected(node.path)
        let partial = model.selection.isPartiallySelected(node)
        HStack {
            Button { model.selection.toggle(node, root: root) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : partial ? "minus.square.fill" : "square")
                    .foregroundStyle(selected || partial ? Color.accentColor : .secondary)
            }.buttonStyle(.plain)
            Image(systemName: node.path == "yt" ? "play.rectangle.fill" : "folder.fill").foregroundStyle(node.path == "yt" ? .red : .blue)
            Text(node.name)
            Spacer()
            Text("\(node.totalTracks)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
