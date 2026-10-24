import SwiftUI
import AVKit
import UniformTypeIdentifiers
import YouTubeKit

@main
struct YouTubeMP4App: App {
    var body: some Scene { WindowGroup { HomeView() } }
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

@MainActor
enum MP4Exporter {
    static func run(_ session: AVAssetExportSession, to output: URL) async throws {
        try Task.checkCancellation()
        if #available(iOS 18.0, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            try await legacyExport(session, to: output)
        }
        try Task.checkCancellation()
    }

    @available(iOS, introduced: 16.0, obsoleted: 18.0)
    private static func legacyExport(_ session: AVAssetExportSession, to output: URL) async throws {
        session.outputURL = output
        session.outputFileType = .mp4
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            try Task.checkCancellation()
            guard session.status == .completed else {
                throw session.error ?? ServiceError(message: "MP4の書き出しに失敗しました。")
            }
        }, onCancel: { session.cancelExport() })
    }
}

// Download progress is delivered by URLSession off the main thread.
final class TransferProgress: NSObject, URLSessionDownloadDelegate {
    let report: @Sendable (Double?) -> Void
    init(report: @escaping @Sendable (Double?) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 2 * 1024 * 1024 * 1024 || totalBytesExpectedToWrite > 2 * 1024 * 1024 * 1024 {
            downloadTask.cancel()
            return
        }
        report(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

@MainActor
final class VideoStore: ObservableObject {
    @Published var videos: [LocalVideo] = []
    @Published var busy = false
    @Published var status = "URLを貼り付けて開始してください"
    @Published var fraction: Double?
    @Published var message = ""
    private var operation: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    init() { scanVideos() }

    static func videoID(from value: String) throws -> String {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https" || parts.scheme == "http",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 || parts.port == 80,
              let host = parts.host?.lowercased() else {
            throw ServiceError(message: "YouTubeの動画URLを入力してください。")
        }
        let components = parts.path.split(separator: "/").map(String.init)
        let id: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            id = components.count == 1 ? components.first : nil
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            if parts.path == "/watch" { id = parts.queryItems?.first(where: { $0.name == "v" })?.value }
            else if components.count == 2, ["shorts", "live", "embed"].contains(components[0]) { id = components[1] }
            else { id = nil }
        default: id = nil
        }
        guard let id, id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            throw ServiceError(message: "単体のYouTube動画URLを入力してください。再生リストには対応していません。")
        }
        return id
    }

    func scanVideos() {
        videos = ((try? FileManager.default.contentsOfDirectory(at: Self.documents, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.map { LocalVideo(url: $0) }
    }
    func remove(_ video: LocalVideo) {
        guard !busy else { return }
        do { try FileManager.default.removeItem(at: video.url); scanVideos() }
        catch { message = error.localizedDescription }
    }
    func cancel() { operation?.cancel() }

    func start(url: String, height: Int) {
        guard !busy else { return }
        do {
            let id = try Self.videoID(from: url)
            busy = true
            operation = Task { await process(id: id, height: height) }
        } catch { message = error.localizedDescription }
    }

    private func checkCapacity() throws {
        let values = try Self.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < 1024 * 1024 * 1024 {
            throw ServiceError(message: "iPhoneの空き容量が1GiB未満です。動画と一時ファイルを置ける容量を確保してください。")
        }
    }

    private func download(_ url: URL, to destination: URL, label: String) async throws {
        guard url.scheme == "https" else { throw ServiceError(message: "取得元がHTTPSではありません。") }
        status = label; fraction = nil
        let delegate = TransferProgress { [weak self] progress in
            Task { @MainActor in self?.fraction = progress }
        }
        let (temp, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw ServiceError(message: "動画の取得が拒否されました。取得URLの期限切れやYouTube側の制限が考えられます。")
        }
        let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 2 * 1024 * 1024 * 1024 else {
            throw ServiceError(message: "取得したファイルが空か、1ファイル2GiBの上限を超えています。")
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    private func export(_ asset: AVAsset, to output: URL) async throws {
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else {
            throw ServiceError(message: "この映像・音声の組み合わせはMP4へ書き出せません。")
        }
        session.shouldOptimizeForNetworkUse = true
        status = "iPhone内でMP4を書き出しています"; fraction = nil
        try await MP4Exporter.run(session, to: output)
    }

    private func merge(video: URL, audio: URL, to output: URL) async throws {
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw ServiceError(message: "映像または音声トラックを読み込めませんでした。")
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let seconds = min(videoDuration.seconds, audioDuration.seconds)
        guard seconds.isFinite, seconds > 0 else { throw ServiceError(message: "動画の長さが不正です。") }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ServiceError(message: "動画の結合準備に失敗しました。")
        }
        try v.insertTimeRange(range, of: videoTrack, at: .zero)
        v.preferredTransform = try await videoTrack.load(.preferredTransform)
        try a.insertTimeRange(range, of: audioTrack, at: .zero)
        try await export(composition, to: output)
    }

    private func process(id: String, height: Int) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = Self.documents.appendingPathComponent("YouTube-\(id)-\(UUID().uuidString).mp4")
        let previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            try? FileManager.default.removeItem(at: folder)
            busy = false; fraction = nil; operation = nil
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
        }
        do {
            try checkCapacity()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            status = "iPhoneで動画情報を確認しています"; fraction = nil
            // Explicitly disable YouTubeKit's remote extraction fallback.
            let youtube = YouTube(videoID: id, methods: [.local])
            let streams = try await youtube.streams
            try Task.checkCancellation()
            let videoStreams = streams.filter {
                $0.fileExtension == .mp4 && $0.isNativelyPlayable && $0.includesVideoTrack
                    && ($0.videoResolution ?? Int.max) <= height
            }.sorted { ($0.videoResolution ?? 0) > ($1.videoResolution ?? 0) }
            guard let chosen = videoStreams.first else {
                throw ServiceError(message: "指定画質以下の対応MP4が見つかりません。別の画質または動画を試してください。")
            }
            let v = folder.appendingPathComponent("video.mp4")
            try await download(chosen.url, to: v, label: "映像を取得中（\(chosen.videoResolution ?? 0)p）")
            if chosen.includesVideoAndAudioTrack {
                let asset = AVURLAsset(url: v)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty, !audio.isEmpty else {
                    throw ServiceError(message: "取得ファイルに映像または音声がありません。")
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: v, to: output)
            } else {
                guard let audio = streams.filter({
                    $0.includesAudioTrack && !$0.includesVideoTrack && $0.isNativelyPlayable
                        && ($0.fileExtension == .m4a || $0.fileExtension == .mp4)
                }).max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) else {
                    throw ServiceError(message: "対応する音声が見つかりません。無音の動画は保存しません。")
                }
                let a = folder.appendingPathComponent("audio.m4a")
                try await download(audio.url, to: a, label: "音声を取得中")
                try await merge(video: v, audio: a, to: output)
            }
            scanVideos(); status = "MP4をiPhoneに保存しました"
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { status = "中止しました" }
            else {
                status = "取得・変換に失敗しました"
                message = error.localizedDescription + "\n公開動画でも取得できない場合があります。通信・空き容量・ライブラリの対応状況をご確認ください。"
            }
        }
    }
}

struct HomeView: View {
    @StateObject private var store = VideoStore()
    @State private var youtubeURL = ""
    @State private var height = 720
    @State private var selected: LocalVideo?
    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "YouTubeKit-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "YouTubeKit — MIT License / Copyright (c) 2022 Alexander Eichhorn" }
        return text
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("iPhoneだけで取得・保存", systemImage: "iphone")
                    Text("URLの取得からMP4保存まで、この端末で処理します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("YouTubeから取得") {
                    TextField("YouTubeの動画URL", text: $youtubeURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(store.busy)
                    Picker("画質の上限", selection: $height) {
                        Text("360p").tag(360); Text("720p").tag(720); Text("1080p").tag(1080)
                    }.pickerStyle(.segmented).disabled(store.busy)
                    Button("iPhoneで取得・MP4保存") { store.start(url: youtubeURL, height: height) }
                        .disabled(store.busy || youtubeURL.isEmpty)
                }
                Section("処理状況") {
                    Text(store.status)
                    if store.busy {
                        if let fraction = store.fraction { ProgressView(value: fraction) }
                        else { ProgressView() }
                        Button("中止する", role: .destructive) { store.cancel() }
                    }
                }
                Section("保存した動画") {
                    if store.videos.isEmpty { Text("保存後はオフラインでも再生できます").foregroundStyle(.secondary) }
                    ForEach(store.videos) { video in
                        Button { selected = video } label: {
                            Label(video.title, systemImage: "play.rectangle").lineLimit(2)
                        }.disabled(store.busy)
                        .swipeActions {
                            Button("削除", role: .destructive) { store.remove(video) }.disabled(store.busy)
                        }
                    }
                }
                Section {
                    NavigationLink("使用ライブラリとライセンス") {
                        ScrollView {
                            Text(licenseText).font(.caption).padding().textSelection(.enabled)
                        }.navigationTitle("YouTubeKit")
                    }
                    Text("取得・保存する権限のある動画を使用してください。処理中はアプリを開いたままにしてください。長い動画は通信量・空き容量・電池を多く使います。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("おうち動画保存")
            .refreshable { store.scanVideos() }
            .sheet(item: $selected, onDismiss: { store.scanVideos() }) { video in MovieView(video: video) }
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
    @State private var exportTask: Task<Void, Never>?
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
                        Button(exporting ? "書き出し中…" : "選択区間を別のMP4に保存") { exportTask = Task { await trim() } }
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
            .onDisappear { player?.pause(); exportTask?.cancel() }
        }
    }

    private var validRange: Bool {
        start.isFinite && end.isFinite && start >= 0 && end <= duration && end > start
    }

    @MainActor private func trim() async {
        guard validRange, !exporting else { return }
        exporting = true; error = ""; result = nil; player?.pause()
        defer { exporting = false; exportTask = nil }
        let asset = AVURLAsset(url: video.url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else {
            error = "この動画はMP4の切り取りに対応していません。"; return
        }
        let output = VideoStore.documents.appendingPathComponent("切り取り-\(UUID().uuidString).mp4")
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: end - start, preferredTimescale: 600))
        do {
            try await MP4Exporter.run(session, to: output)
            result = output
        } catch {
            try? FileManager.default.removeItem(at: output)
            self.error = error.localizedDescription
        }
    }
}
