import SwiftUI
import AVKit
import Photos
import Combine
import UniformTypeIdentifiers
import YouTubeKit

@main
struct YouTubeMP4App: App {
    var body: some Scene { WindowGroup { HomeView() } }
}

struct ServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Candidates that can produce a movie with both picture and sound.
struct MediaSource {
    let url: URL
    let hasVideo: Bool
    let hasAudio: Bool
    let resolution: Int
    let bitrate: Int
}

struct DownloadPlan {
    let video: MediaSource
    let audio: MediaSource?
}

enum DownloadPlanner {
    static func plans(_ sources: [MediaSource], maxHeight: Int) -> [DownloadPlan] {
        let audio = sources.filter { $0.hasAudio && !$0.hasVideo }
            .max { $0.bitrate < $1.bitrate }
        return sources.filter {
            $0.hasVideo && $0.resolution > 0 && $0.resolution <= maxHeight
                && ($0.hasAudio || audio != nil)
        }.sorted {
            if $0.resolution != $1.resolution { return $0.resolution > $1.resolution }
            if $0.hasAudio != $1.hasAudio { return $0.hasAudio }
            return $0.bitrate > $1.bitrate
        }.prefix(6).map { DownloadPlan(video: $0, audio: $0.hasAudio ? nil : audio) }
    }
}

@MainActor
enum MP4Exporter {
    static func run(_ session: AVAssetExportSession, to output: URL, reportProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let poller = Task {
            while !Task.isCancelled {
                reportProgress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poller.cancel() }
        if #available(iOS 18.0, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            try await legacyExport(session, to: output)
        }
        reportProgress?(1)
        try Task.checkCancellation()
    }

    // Kept without an `obsoleted` availability marker: with a deployment target
    // at or above iOS 18 the marker makes this symbol unavailable to the compiler
    // even inside the `#available` fallback branch above (iOS 26 SDK).
    private static func legacyExport(_ session: AVAssetExportSession, to output: URL) async throws {
        session.outputURL = output
        session.outputFileType = .mp4
        let cancellation = LegacyCancellation(session)
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { continuation.resume() }
            }
            try Task.checkCancellation()
            guard session.status == .completed else {
                throw session.error ?? ServiceError(message: "MP4の書き出しに失敗しました。")
            }
        }, onCancel: { Task { await cancellation.cancel() } })
    }

    @MainActor private final class LegacyCancellation {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
        func cancel() { session.cancelExport() }
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
enum PhotosVideoSaver {
    static func save(_ url: URL) async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let access = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : current
        guard access == .authorized || access == .limited else {
            throw ServiceError(message: "写真への追加が許可されていません。設定で「おうち動画保存」の写真へのアクセスを許可してください。")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}

@MainActor
final class VideoStore: ObservableObject {
    @Published var busy = false
    @Published var diagnostics = ""
    @Published var status = "URLを貼り付けて開始してください" {
        didSet { record(status) }
    }
    @Published var fraction: Double?
    @Published var startedAt: Date?
    @Published var etaSeconds: Double?
    private var progressSamples: [(date: Date, value: Double)] = []
    private var phaseCeiling: Double = 0
    private var creepTask: Task<Void, Never>?
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

    private func record(_ text: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(text)"
        diagnostics = (diagnostics.split(separator: "\n").map(String.init) + [line]).suffix(80).joined(separator: "\n")
    }

    private func diagnosticError(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) (\(e.code)): \(String(e.localizedDescription.prefix(500)))"
    }

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

    func cancel() { operation?.cancel(); stopCreep() }

    /// Overall 0...1 progress across every phase (fraction is reused as the
    /// overall value); derives a smoothed ETA from the progress rate over
    /// the last ~20 seconds.
    func setOverall(_ value: Double) {
        let v = min(max(value, 0), 1)
        fraction = v
        let now = Date()
        progressSamples.append((now, v))
        progressSamples.removeAll { now.timeIntervalSince($0.date) > 20 }
        if let first = progressSamples.first, progressSamples.count > 1 {
            let dt = now.timeIntervalSince(first.date)
            let dv = v - first.value
            if dt >= 3, dv > 0.005, v > 0.03, v < 0.999 {
                etaSeconds = (1 - v) / (dv / dt)
            }
        }
    }

    /// While a phase runs, keeps the gauge moving toward the phase
    /// ceiling even when no real progress is reported (unknown download
    /// size, extraction wait, ...). Real progress always overrides this
    /// estimate because setOverall() is called with the true value.
    private func startCreep() {
        creepTask?.cancel()
        creepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.busy else { return }
                if let f = self.fraction, f < self.phaseCeiling {
                    self.setOverall(f + (self.phaseCeiling - f) * 0.04)
                }
            }
        }
    }

    private func stopCreep() {
        creepTask?.cancel()
        creepTask = nil
    }

    func elapsedText(at now: Date = Date()) -> String {
        guard let startedAt else { return "0:00" }
        let s = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var etaText: String? {
        guard let etaSeconds, etaSeconds.isFinite, etaSeconds > 0 else { return nil }
        if etaSeconds < 55 { return "残り約\(Int(etaSeconds.rounded()))秒" }
        let minutes = Int((etaSeconds / 60).rounded())
        if minutes < 60 { return "残り約\(minutes)分" }
        return "残り約\(minutes / 60)時間\(minutes % 60)分"
    }

    func start(url: String, height: Int) {
        guard !busy else { return }
        do {
            let id = try Self.videoID(from: url)
            diagnostics = ""
            record("アプリ v1.4.2 / iPhone単体処理・写真保存 / 画質上限 \(height)p")
            busy = true
            startedAt = Date()
            etaSeconds = nil; progressSamples = []
            phaseCeiling = 0.05
            setOverall(0)
            startCreep()
            operation = Task { await process(id: id, height: height) }
        } catch { message = error.localizedDescription }
    }

    private func checkCapacity() throws {
        let values = try Self.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < 1024 * 1024 * 1024 {
            throw ServiceError(message: "iPhoneの空き容量が1GiB未満です。動画と一時ファイルを置ける容量を確保してください。")
        }
    }

    func download(_ url: URL, to destination: URL, label: String, slotStart: Double = 0, slotEnd: Double = 1) async throws {
        guard url.scheme == "https" else { throw ServiceError(message: "取得元がHTTPSではありません。") }
        status = label; phaseCeiling = slotEnd; setOverall(slotStart)
        let delegate = TransferProgress { [weak self] progress in
            Task { @MainActor in
                if let progress { self?.setOverall(slotStart + (slotEnd - slotStart) * progress) }
            }
        }
        let (temp, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw ServiceError(message: "動画の取得でHTTP応答を確認できませんでした。")
        }
        guard (200...299).contains(response.statusCode) else {
            throw ServiceError(message: "動画の取得に失敗しました（HTTP \(response.statusCode)）。")
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
        status = "iPhone内でMP4を書き出しています"
        phaseCeiling = 0.95
        try await MP4Exporter.run(session, to: output) { [weak self] value in
            Task { @MainActor in self?.setOverall(0.65 + 0.30 * value) }
        }
    }

    func merge(video: URL, audio: URL, to output: URL) async throws {
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

    func validateMovie(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let playable = try await asset.load(.isPlayable)
        guard !video.isEmpty, !audio.isEmpty, playable,
              duration.seconds.isFinite, duration.seconds > 0 else {
            throw ServiceError(message: "保存したMP4の映像・音声・再生可能性を検証できませんでした。")
        }
    }

    private func process(id: String, height: Int) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = Self.documents.appendingPathComponent("YouTube-\(id)-\(UUID().uuidString).mp4")
        let previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            try? FileManager.default.removeItem(at: folder)
            stopCreep()
            busy = false; fraction = nil; etaSeconds = nil; progressSamples = []; operation = nil
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
        }
        do {
            try checkCapacity()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            status = "iPhoneで動画情報を確認しています"
            phaseCeiling = 0.05
            // Explicitly disable YouTubeKit's remote extraction fallback.
            let youtube = YouTube(videoID: id, methods: [.local])
            let streams = try await youtube.streams
            try Task.checkCancellation()
            let sources = streams.filter {
                $0.isNativelyPlayable && ($0.fileExtension == .mp4 || $0.fileExtension == .m4a)
            }.map {
                MediaSource(url: $0.url, hasVideo: $0.includesVideoTrack,
                            hasAudio: $0.includesAudioTrack, resolution: $0.videoResolution ?? 0,
                            bitrate: $0.bitrate ?? 0)
            }
            let plans = DownloadPlanner.plans(sources, maxHeight: height)
            record("抽出 \(streams.count)件 / 音声付きで保存可能な候補 \(plans.count)件")
            setOverall(0.05)
            guard !plans.isEmpty else {
                throw ServiceError(message: "指定画質以下で映像と音声を保存できる形式がありません。別の画質または動画を試してください。")
            }
            var lastError: Error = ServiceError(message: "対応する取得元がありません。")
            var completed = false
            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                let attempt = folder.appendingPathComponent("attempt-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: attempt) }
                do {
                    status = "候補 \(index + 1)/\(plans.count) を確認中"
                    progressSamples = []; etaSeconds = nil; setOverall(0.05); phaseCeiling = 0.05
                    let v = attempt.appendingPathComponent("video.mp4")
                    if plan.audio == nil {
                        try await download(plan.video.url, to: v, label: "映像を取得中（\(plan.video.resolution)p）", slotStart: 0.05, slotEnd: 0.90)
                    } else {
                        try await download(plan.video.url, to: v, label: "映像を取得中（\(plan.video.resolution)p）", slotStart: 0.05, slotEnd: 0.50)
                    }
                    if let audio = plan.audio {
                        let a = attempt.appendingPathComponent("audio.m4a")
                        try await download(audio.url, to: a, label: "音声を取得中", slotStart: 0.50, slotEnd: 0.65)
                        try await merge(video: v, audio: a, to: output)
                    } else {
                        try await validateMovie(v)
                        try Task.checkCancellation()
                        try FileManager.default.moveItem(at: v, to: output)
                    }
                    status = "保存したMP4を検証しています"
                    phaseCeiling = 0.97
                    try await validateMovie(output)
                    setOverall(0.97)
                    completed = true
                    break
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    if Task.isCancelled { throw CancellationError() }
                    record("候補 \(index + 1) 失敗: \(diagnosticError(error))")
                    lastError = error
                }
            }
            guard completed else { throw lastError }
            status = "写真アプリに保存しています"
            phaseCeiling = 1.0
            do {
                try await PhotosVideoSaver.save(output)
                try? FileManager.default.removeItem(at: output)
                setOverall(1)
                status = "写真アプリに保存しました（所要時間 \(elapsedText())）"
            } catch {
                record("写真アプリへの保存に失敗: \(diagnosticError(error))")
                status = "写真アプリへ保存できませんでした"
                message = error.localizedDescription
                    + "\n動画は「ファイル」アプリの「このiPhone内 → おうち動画保存」に残してあります。"
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { status = "中止しました" }
            else {
                let failedStage = status
                record(diagnosticError(error))
                status = "取得・変換に失敗しました"
                message = "失敗した段階: \(failedStage)\n" + error.localizedDescription
                    + "\n「診断ログを共有」から詳細を確認できます。"
            }
        }
    }
}

struct HomeView: View {
    @StateObject private var store = VideoStore()
    @State private var youtubeURL = ""
    @State private var height = 720
    @FocusState private var urlFieldFocused: Bool
    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "YouTubeKit-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "YouTubeKit — MIT License / Copyright (c) 2022 Alexander Eichhorn" }
        return text
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("iPhoneだけで取得し、写真に保存", systemImage: "iphone")
                    Text("URLの取得からMP4化、写真アプリへの保存まで、この端末だけで処理します。保存先は写真アプリに絞っています。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("動画を取得") {
                    TextField("YouTubeのURLを貼り付け", text: $youtubeURL)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($urlFieldFocused).submitLabel(.done)
                        .onSubmit { urlFieldFocused = false }
                        .accessibilityLabel("YouTubeのURL")
                        .accessibilityIdentifier("youtubeURLField")
                        .disabled(store.busy)
                    Picker("画質の上限", selection: $height) {
                        Text("360p").tag(360); Text("720p").tag(720); Text("1080p").tag(1080)
                    }.pickerStyle(.segmented).disabled(store.busy)
                    Button {
                        urlFieldFocused = false
                        store.start(url: youtubeURL, height: height)
                    } label: {
                        Label(store.busy ? "iPhoneで取得中…" : "取得して写真アプリに保存",
                              systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("downloadOnIPhoneButton")
                    .disabled(store.busy || youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("処理状況") {
                    Text(store.status)
                    if !store.diagnostics.isEmpty {
                        ShareLink(item: store.diagnostics) { Label("診断ログを共有", systemImage: "square.and.arrow.up") }
                        DisclosureGroup("診断の詳細") {
                            Text(store.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if store.busy {
                        ProgressView(value: store.fraction ?? 0)
                        TimelineView(.periodic(from: store.startedAt ?? .now, by: 0.5)) { context in
                            HStack(spacing: 12) {
                                Text("全体 \(Int((store.fraction ?? 0) * 100))%")
                                Text("経過 \(store.elapsedText(at: context.date))")
                                Spacer()
                                if let eta = store.etaText { Text(eta) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Button("中止する", role: .destructive) { store.cancel() }
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
            .alert("確認してください", isPresented: Binding(
                get: { !store.message.isEmpty }, set: { if !$0 { store.message = "" } })) {
                    Button("閉じる") { store.message = "" }
            } message: { Text(store.message) }
        }.tint(.teal)
    }
}

