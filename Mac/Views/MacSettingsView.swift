import SwiftUI

struct MacSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var yt: YouTubeManager
    @State private var browser = ""
    @State private var cookieFile = ""

    private let browsers = ["chrome", "safari", "firefox", "brave", "edge", "chromium", "vivaldi", "opera", "none"]

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Music root", value: model.musicRoot?.path ?? "Not set")
                if model.musicRoot != nil {
                    LabeledContent("Status", value: model.isRootAvailable ? "Available" : "Unavailable (unmounted or missing)")
                }
                if model.usingServer {
                    LabeledContent("Songs from", value: model.web.url)
                }
                HStack {
                    Button("Change Music Root…") { model.chooseRoot() }
                    if model.musicRoot != nil && !model.isRootAvailable {
                        Button("Check Again") { model.checkRootAvailability() }
                    }
                }
                LabeledContent("Database", value: AppModel.supportDir.appendingPathComponent("library.sqlite").path)
                HStack(spacing: 12) {
                    Button("Backup Database Now") { model.backupDatabaseNow(reveal: true) }
                    Button("Restore Database Backup…") { model.promptRestoreDatabase() }
                }
            }
            Section("Server") {
                TextField("Bonjour name", text: $model.serverName)
                Button("Apply & Restart Server") { model.startServer() }
            }
            Section("YouTube (yt-dlp)") {
                TextField("Liked playlist URL", text: $yt.playlistURL)
                Picker("Cookies from browser", selection: $browser) {
                    ForEach(browsers, id: \.self) { Text($0) }
                    Text("cookies.txt file").tag("file")
                }
                .onChange(of: browser) { _, b in yt.cookiesBrowser = b == "file" ? "file:" + cookieFile : b }
                if browser == "file" {
                    TextField("cookies.txt path", text: $cookieFile).onSubmit { yt.cookiesBrowser = "file:" + cookieFile }
                }
                Text("Safari cookies need Full Disk Access for MyMusic. Chrome/Firefox work out of the box while you're signed in to YouTube.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("yt-dlp path (blank = auto)", text: $yt.ytdlpPath)
                LabeledContent("Resolved yt-dlp", value: yt.resolvedYtdlp ?? "not found – brew install yt-dlp ffmpeg deno")
                Stepper("Re-check liked playlist every \(yt.autoRefreshHours) h (0 = off)", value: $yt.autoRefreshHours, in: 0...48)
                Picker("Default priority for new likes", selection: $yt.defaultPriorityRaw) {
                    ForEach(YTPriority.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section {
                Stepper("Wait between downloads: \(yt.delaySeconds) s (randomized ±50 %)", value: $yt.delaySeconds, in: 0...600, step: 5)
                Stepper("Max downloads per hour: \(yt.maxPerHour == 0 ? "unlimited" : "\(yt.maxPerHour)")", value: $yt.maxPerHour, in: 0...500, step: 5)
                Stepper("Max downloads per day: \(yt.maxPerDay == 0 ? "unlimited" : "\(yt.maxPerDay)")", value: $yt.maxPerDay, in: 0...5000, step: 25)
                TextField("Bandwidth limit (e.g. 2M, 500K; blank = none)", text: $yt.rateLimit)
                Toggle("Wait 1 s between YouTube requests (yt-dlp --sleep-requests)", isOn: $yt.sleepRequests)
                Stepper("When YouTube rate-limits: pause \(yt.cooldownHours) h", value: $yt.cooldownHours, in: 1...48)
                if yt.isCoolingDown {
                    HStack {
                        Text("Paused by rate limit until \(Date(timeIntervalSince1970: yt.cooldownUntil).formatted(date: .omitted, time: .shortened))").foregroundStyle(.orange)
                        Spacer()
                        Button("Resume Now") { yt.endCooldown() }
                    }
                }
                Button("Use safe defaults") {
                    yt.delaySeconds = 20; yt.maxPerHour = 40; yt.maxPerDay = 300; yt.rateLimit = ""; yt.sleepRequests = true; yt.cooldownHours = 6
                }
            } header: { Text("Throttling") } footer: {
                Text("Fast, nonstop downloads with your logged-in cookies can get your account or IP rate-limited ('Sign in to confirm you're not a bot'). Songs you double-click skip these limits.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 720)
        .onAppear {
            if yt.cookiesBrowser.hasPrefix("file:") { browser = "file"; cookieFile = String(yt.cookiesBrowser.dropFirst(5)) }
            else { browser = yt.cookiesBrowser }
        }
    }
}
