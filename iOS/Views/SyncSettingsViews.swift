import SwiftUI

struct SyncView: View {
    @EnvironmentObject var browser: ServerBrowser
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var model: IOSModel
    @State private var selected: DiscoveredServer?

    var body: some View {
        List {
            Section {
                if browser.servers.isEmpty {
                    HStack { ProgressView(); Text(browser.state).foregroundStyle(.secondary) }
                }
                ForEach(browser.servers) { s in
                    Button { selected = s } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(s.name)
                            Spacer()
                            if current?.id == s.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                }
                if !model.manualServer.isEmpty {
                    Label("Manual: \(model.manualServer)", systemImage: "network").foregroundStyle(current == nil ? .primary : .secondary)
                }
            } header: { Text("Macs on this network") } footer: {
                Text("Start MyMusic Server on your Mac. The folders checked in its Sync view are copied here, keeping their folder structure.")
            }

            Section {
                if sync.isSyncing {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sync.status).lineLimit(1)
                        if sync.total > 0 {
                            ProgressView(value: Double(sync.bytesDone), total: Double(max(sync.bytesTotal, 1)))
                            Text("\(sync.done)/\(sync.total) files · \(ByteCountFormatter.string(fromByteCount: sync.bytesDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: sync.bytesTotal, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Cancel", role: .destructive) { sync.cancel() }
                } else {
                    Button { sync.sync(server: current) } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(current == nil && model.manualServer.isEmpty)
                    if !sync.status.isEmpty { Text(sync.status).font(.footnote).foregroundStyle(.secondary) }
                }
            } footer: {
                if let mac = sync.listeningTo { Text("Connected to \(mac): you can also start a sync from the Mac. ") }
                if sync.lastSync > 0 { Text("Last sync \(Date(timeIntervalSince1970: sync.lastSync).formatted(.relative(presentation: .named))). Keep the app open during large syncs.") }
            }

            if !sync.errors.isEmpty {
                Section("Errors") { ForEach(sync.errors, id: \.self) { Text($0).font(.caption) } }
            }
        }
        .navigationTitle("Sync")
        .refreshable { browser.start() }
    }

    /// Explicit pick → last used Mac → only Mac found.
    private var current: DiscoveredServer? {
        selected ?? browser.servers.first { $0.name == sync.lastServerName } ?? (browser.servers.count == 1 ? browser.servers.first : nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: IOSModel
    @EnvironmentObject var sync: SyncManager
    @EnvironmentObject var browser: ServerBrowser
    @EnvironmentObject var store: LibraryStore
    @State private var backups: (URL, [DeviceBackup])?
    @State private var message: String?
    @State private var loadingBackups = false
    @State private var confirmWipe = false

    var body: some View {
        Form {
            Section("This device") {
                TextField("Device name (shown on the Mac)", text: $model.deviceName)
                LabeledContent("Device ID", value: String(model.deviceID.prefix(8)))
            }
            Section {
                TextField("Manual Mac address (e.g. 192.168.1.10:47823)", text: $model.manualServer)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Remove songs deleted on the Mac", isOn: $model.removeDeleted)
            } header: { Text("Sync") } footer: { Text("Only songs that came from the Mac are ever removed. Files you import stay.") }

            Section {
                Button {
                    loadingBackups = true
                    Task {
                        backups = await sync.fetchBackups(server: browser.servers.first { $0.name == sync.lastServerName } ?? browser.servers.first)
                        loadingBackups = false
                        if backups == nil { message = "Couldn't reach the Mac" }
                    }
                } label: { HStack { Text("Restore stats from Mac…"); if loadingBackups { Spacer(); ProgressView() } } }
                if let (base, list) = backups {
                    ForEach(list) { b in
                        Button {
                            Task { message = await sync.restore(base: base, backup: b, adoptIdentity: true); backups = nil }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(b.deviceName + (b.deviceID == model.deviceID ? " (this device)" : ""))
                                Text("\(b.entryCount) tracks · \(Date(timeIntervalSince1970: b.lastSync).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("Export stats to Files (Backups folder)") {
                    message = model.exportDatabase().map { "Saved \($0.lastPathComponent)" } ?? "Export failed"
                }
            } header: { Text("Backup & restore") } footer: {
                Text("Every sync backs up play counts and favorites to the Mac. After reinstalling the app, restore them here, then sync — music comes back from the Mac.")
            }

            Section("Library") {
                LabeledContent("Songs", value: "\(store.tracks.count)")
                LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: model.storageUsed(), countStyle: .file))
                LabeledContent("Local imports", value: "\(store.tracks.filter { $0.origin == .imported }.count)")
                Button("Rescan files") { Task { await model.scanLocal() } }
                Button("Remove all synced songs", role: .destructive) { confirmWipe = true }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                Text("Files are in Files → On My iPhone → MyMusic → Music, so other apps can open them.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
        .confirmationDialog("Remove all songs synced from the Mac? Stats are kept on the Mac.", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.deleteFromDevice(store.tracks.filter { $0.origin == .server }) }
        }
    }
}
