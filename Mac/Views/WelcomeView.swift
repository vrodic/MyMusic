import SwiftUI

/// Shown until a music root is chosen. Offers to set up from a web player found on the network
/// (mount its SMB share, restore the main Mac's library), or to pick a folder by hand.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var setup = WebSetup()
    @State private var tokens: [String: String] = [:]
    @State private var chosen: [String: String] = [:]   // candidate → backup replica ("" newest, "none")

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Welcome to MyMusic").font(.largeTitle.bold())

                if !setup.candidates.isEmpty && model.store.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Found on your network").font(.headline)
                        ForEach(setup.candidates) { c in card(c) }
                    }
                    .frame(maxWidth: 520)
                } else if model.store.tracks.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for a MyMusic web player on your network…").foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 6) {
                    Button("Choose Music Folder…") { model.chooseRoot() }.disabled(setup.isRunning)
                    Text("Pick the root of your music collection yourself. YouTube downloads go into <root>/yt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .onAppear { setup.start() }
        .onDisappear { setup.stop() }
    }

    private func card(_ c: WebSetup.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MyMusic web player on \(c.info.name)").font(.headline)
                    Text("\(c.info.trackCount) songs" + (c.info.macBackupAt.flatMap(relative).map { " · library from \(c.info.macName ?? "a Mac"), saved \($0)" } ?? " · no Mac library backup yet"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let smb = c.info.smbURL { Text(smb).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            if c.info.tokenRequired == true {
                SecureField("Token (MYMUSIC_TOKEN on \(c.info.name))", text: Binding(get: { tokens[c.id] ?? "" }, set: { tokens[c.id] = $0 }))
                    .onSubmit { Task { await setup.loadBackups(c, token: tokens[c.id] ?? "") } }
            }
            if let list = setup.backups[c.id] {
                Picker("Start from", selection: Binding(get: { chosen[c.id] ?? "" }, set: { chosen[c.id] = $0 })) {
                    Text("Newest backup").tag("")
                    ForEach(list) { b in
                        Text("\(b.name.isEmpty ? "A Mac" : b.name) · \(relative(b.at) ?? b.at) · \(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file))").tag(b.replica)
                    }
                    Text("No backup – just sync with the other devices").tag("none")
                }
                .help("Several Macs back up here, each in its own slot. Favorites, plays and playlists also arrive from the other devices either way.")
            } else if c.info.tokenRequired != true || !(tokens[c.id] ?? "").isEmpty {
                Button("Show Backups") { Task { await setup.loadBackups(c, token: tokens[c.id] ?? "") } }.buttonStyle(.link)
            }
            Text(c.info.macBackupAt == nil
                 ? "Connects to the music share and scans it. Plays and favorites from the web player carry over; a full library (play counts, iPhone backups, YouTube queue) needs the main Mac to sync with the web player once."
                 : "Connects to the music share (macOS asks for its username and password if needed) and restores the library: play counts, favorites, iPhone backups, the YouTube queue and sync settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if setup.isRunning {
                    ProgressView().controlSize(.small)
                    Text(setup.step ?? "").font(.caption).lineLimit(2)
                } else if let e = setup.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Set Up from \(c.info.name)") {
                    let pick = chosen[c.id] ?? ""
                    Task { await setup.setUp(c, token: tokens[c.id] ?? "", backup: pick == "none" ? nil : pick, model: model) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(setup.isRunning || (c.info.tokenRequired == true && (tokens[c.id] ?? "").isEmpty))
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func relative(_ iso: String) -> String? {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return nil }
        return d.formatted(.relative(presentation: .named))
    }
}
