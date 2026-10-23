import SwiftUI
import AVKit

@main
struct YouTubeMP4App: App {
    var body: some Scene { WindowGroup { HomeView() } }
}

struct VideoJob: Decodable, Identifiable {
    let id: String
    let title: String
    let status: String
    let progress: String
    let size: Int64?
}

struct LocalVideo: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct ServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Connection: Equatable {
    let base: URL
    let key: String

    init(_ text: String) throws {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http" || parts.scheme == "https",
              let host = parts.host, parts.user == nil, parts.password == nil,
              Self.isLocal(host),
              let key = parts.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty else {
            throw ServiceError(message: "Macの起動時に表示された、key付きの自宅LAN用URLを貼り付けてください。")
        }
        var base = URLComponents()
        base.scheme = parts.scheme
        base.host = host
        base.port = parts.port
        guard let url = base.url else { throw ServiceError(message: "接続URLが正しくありません。") }
        self.base = url
        self.key = key
    }

    static func isLocal(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let octets = pieces.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue(key, forHTTPHeaderField: "X-Access-Key")
        request.timeoutInterval = 30
        return request
    }
}

@MainActor
final class VideoStore: ObservableObject {
    @Published var jobs: [VideoJob] = []
    @Published var videos: [LocalVideo] = []
    @Published var connection: Connection?
    @Published var message = ""
    @Published var submitting = false
    @Published var downloading: Set<String> = []
    @Published var loading = false
    private var generation = UUID()
    private var lastRefreshError = ""
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() { scanVideos() }

    func scanVideos() {
        videos = ((try? FileManager.default.contentsOfDirectory(at: Self.documents,
                     includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { LocalVideo(url: $0) }
    }

    func connect(_ text: String) async {
        do {
            let next = try Connection(text)
            generation = UUID()
            connection = next
            lastRefreshError = ""
            jobs = []
            await refresh()
        } catch { message = error.localizedDescription }
    }

    func disconnect() {
        generation = UUID()
        connection = nil
        jobs = []
    }

    private func check(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(message: "Macからの応答を確認できません。")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 403 {
                throw ServiceError(message: "接続キーが無効です。Macの最新の接続URLを貼り直してください。")
            }
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["error"] as? String { throw ServiceError(message: text) }
            throw ServiceError(message: "Macからエラーが返りました（HTTP \(http.statusCode)）。")
        }
    }

    func refresh() async {
        guard let connection, !loading else { return }
        let current = generation
        loading = true
        defer { loading = false }
        do {
            let (data, response) = try await session.data(for: connection.request("api/jobs"))
            try check(response, data: data)
            let result = try JSONDecoder().decode([VideoJob].self, from: data)
            guard current == generation else { return }
            jobs = result
            lastRefreshError = ""
        } catch {
            if current == generation, lastRefreshError != error.localizedDescription {
                lastRefreshError = error.localizedDescription
                message = error.localizedDescription
            }
        }
    }

    func submit(url: String, height: Int) async -> Bool {
        guard let connection, !submitting else { return false }
        submitting = true
        defer { submitting = false }
        do {
            var request = connection.request("api/jobs")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["url": url, "height": height])
            let (data, response) = try await session.data(for: request)
            try check(response, data: data)
            await refresh()
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func download(_ job: VideoJob) async {
        guard let connection, !downloading.contains(job.id) else { return }
        downloading.insert(job.id)
        defer { downloading.remove(job.id) }
        do {
            var request = connection.request("download/" + job.id)
            request.timeoutInterval = 3600
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try check(response)
            let base = job.title.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: "_")
            let title = String(base.prefix(70))
            let file = Self.documents.appendingPathComponent("\(title.isEmpty ? "動画" : title)-\(UUID().uuidString).mp4")
            try FileManager.default.moveItem(at: temporary, to: file)
            scanVideos()
        } catch { message = error.localizedDescription }
    }

    func remove(_ video: LocalVideo) {
        do { try FileManager.default.removeItem(at: video.url); scanVideos() }
        catch { message = error.localizedDescription }
    }
}

struct HomeView: View {
    @StateObject private var store = VideoStore()
    @State private var connectionURL = ""
    @State private var youtubeURL = ""
    @State private var height = 720
    @State private var selected: LocalVideo?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section("Mac miniへの接続") {
                    TextField("http://192.168.…:8765/?key=…", text: $connectionURL)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                    Button(store.connection == nil ? "接続する" : "接続URLを更新する") {
                        Task { await store.connect(connectionURL) }
                    }.disabled(connectionURL.isEmpty || store.loading)
                    if let connection = store.connection {
                        Label(connection.base.absoluteString, systemImage: "desktopcomputer")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("接続を解除", role: .destructive) { store.disconnect() }
                    }
                }
                Section("動画を取得") {
                    TextField("YouTubeの動画URL", text: $youtubeURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("画質の上限", selection: $height) {
                        Text("360p").tag(360); Text("720p").tag(720); Text("1080p").tag(1080)
                    }.pickerStyle(.segmented)
                    Button(store.submitting ? "送信中…" : "Macで取得を開始") {
                        Task { if await store.submit(url: youtubeURL, height: height) { youtubeURL = "" } }
                    }.disabled(store.connection == nil || youtubeURL.isEmpty || store.submitting)
                }
                Section("Macの処理一覧") {
                    if store.jobs.isEmpty { Text("接続後に処理履歴を表示します").foregroundStyle(.secondary) }
                    ForEach(store.jobs) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.title).font(.headline).lineLimit(2)
                            Text(job.status).font(.caption).foregroundStyle(.teal)
                            Text(job.progress).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                            if job.status == "完了" {
                                Button(store.downloading.contains(job.id) ? "iPhoneに保存中…" : "iPhoneに保存") {
                                    Task { await store.download(job) }
                                }.disabled(store.downloading.contains(job.id))
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section("iPhoneに保存した動画") {
                    if store.videos.isEmpty { Text("保存後はMacに接続せず再生できます").foregroundStyle(.secondary) }
                    ForEach(store.videos) { video in
                        Button { selected = video } label: {
                            Label(video.title, systemImage: "play.rectangle").lineLimit(2)
                        }
                        .swipeActions {
                            Button("削除", role: .destructive) { store.remove(video) }
                        }
                    }
                }
                Section {
                    Text("同じ自宅Wi-FiでMacを起動して使用します。取得・保存する権限のある動画を扱ってください。転送中はアプリを開いたままにしてください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("おうち動画保存")
            .refreshable { await store.refresh(); store.scanVideos() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                    catch { break }
                }
            }
            .sheet(item: $selected, onDismiss: { store.scanVideos() }) { video in
                MovieView(video: video)
            }
            .alert("確認してください", isPresented: Binding(
                get: { !store.message.isEmpty }, set: { if !$0 { store.message = "" } })) {
                    Button("閉じる") { store.message = "" }
            } message: { Text(store.message) }
        }.tint(.teal)
    }
}

struct MovieView: View {
    let video: LocalVideo
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var exporting = false
    @State private var exportSession: AVAssetExportSession?
    @State private var result: URL?
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { VideoPlayer(player: player).frame(height: 230) }
                Section("元動画") { ShareLink(item: video.url) { Label("ファイルに保存・共有", systemImage: "square.and.arrow.up") } }
                Section("切り取り（元動画は残ります）") {
                    if duration > 0 {
                        Text("開始 \(start, specifier: "%.1f") 秒 / 終了 \(end, specifier: "%.1f") 秒")
                        Slider(value: $start, in: 0...duration, step: 0.1).accessibilityLabel("開始位置")
                        Button("現在の再生位置を開始に設定") {
                            start = min(duration, max(0, player?.currentTime().seconds ?? 0))
                        }
                        Slider(value: $end, in: 0...duration, step: 0.1).accessibilityLabel("終了位置")
                        Button("現在の再生位置を終了に設定") {
                            end = min(duration, max(0, player?.currentTime().seconds ?? duration))
                        }
                        TextField("開始（秒）", value: $start, format: .number).keyboardType(.decimalPad)
                        TextField("終了（秒）", value: $end, format: .number).keyboardType(.decimalPad)
                        Button(exporting ? "書き出し中…" : "選択区間を別のMP4に保存") { Task { await trim() } }
                            .disabled(exporting || !validRange)
                    } else { Text("動画の長さを確認中…") }
                    if exporting { ProgressView() }
                    if let result {
                        Label("切り取り動画を保存しました", systemImage: "checkmark.circle")
                        ShareLink(item: result) { Text("切り取り動画を共有・ファイルに保存") }
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                }.disabled(exporting)
            }
            .navigationTitle("再生・切り取り").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() }.disabled(exporting) } }
            .interactiveDismissDisabled(exporting)
            .task {
                player = AVPlayer(url: video.url)
                do {
                    let time = try await AVURLAsset(url: video.url).load(.duration)
                    guard time.seconds.isFinite, time.seconds > 0 else { throw ServiceError(message: "動画の長さを読み取れません。") }
                    duration = time.seconds; end = duration
                } catch { self.error = error.localizedDescription }
            }
            .onDisappear { player?.pause(); exportSession?.cancelExport() }
        }
    }

    private var validRange: Bool {
        start.isFinite && end.isFinite && start >= 0 && end <= duration && end > start
    }

    @MainActor private func trim() async {
        guard validRange, !exporting else { return }
        exporting = true; error = ""; result = nil; player?.pause()
        defer { exporting = false; exportSession = nil }
        let asset = AVURLAsset(url: video.url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else {
            error = "この動画はMP4の切り取りに対応していません。"; return
        }
        exportSession = session
        let output = VideoStore.documents.appendingPathComponent("切り取り-\(UUID().uuidString).mp4")
        session.outputURL = output; session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: end - start, preferredTimescale: 600))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status == .completed { result = output }
        else {
            try? FileManager.default.removeItem(at: output)
            error = session.error?.localizedDescription ?? "書き出しが中断されました。アプリを開いたままで再試行してください。"
        }
    }
}
